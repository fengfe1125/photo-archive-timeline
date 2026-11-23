import Foundation
import SwiftData

@Model final class SearchIndexRecord {
  @Attribute(.unique) var key: String
  var payload: Data
  init(key: String, payload: Data) { self.key = key; self.payload = payload }
}

@Model final class SearchPreferenceRecord {
  @Attribute(.unique) var key: String
  var payload: Data
  init(key: String, payload: Data) { self.key = key; self.payload = payload }
}

@globalActor actor SearchStorageActor {
  static let shared = SearchStorageActor()
}

/// One serial background executor also protects an owner opened during all-owner migration.
/// Legacy files remain an untouched recovery copy; no main-actor context performs disk access.
@SearchStorageActor final class SearchRepository {

  nonisolated let directory: URL
  private var container: ModelContainer?
  private var context: ModelContext?
  nonisolated init(base: URL, owner: String) {
    directory = base.appendingPathComponent(SearchDigest.of(Data(owner.utf8)), isDirectory: true)
  }
  nonisolated private init(directory: URL) { self.directory = directory }
  private func key(_ id: String) -> String { SearchDigest.of(Data(id.utf8)) }
  private func isPreference(_ id: String) -> Bool { id == "preferences" || id == "geo" }

  /// Migrates every existing owner, including signed-out accounts whose files must not be discarded.
  static func migrateExistingOwners(base: URL) async throws {
    guard FileManager.default.fileExists(atPath: base.path) else { return }
    let directories = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])
    for directory in directories where directory.lastPathComponent.count == 64 {
      try Task.checkCancellation()
      guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
      try SearchRepository(directory: directory).prepare()
    }
  }

  func prepare() throws {
    guard context == nil else { return }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    var path = directory; try path.setResourceValues(values)
    let schema = Schema([SearchIndexRecord.self, SearchPreferenceRecord.self])
    let configuration = ModelConfiguration("SearchV2", schema: schema, url: directory.appendingPathComponent("search-v2.store"), cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let importing = ModelContext(container); importing.autosaveEnabled = false
    let marker = "legacy-import-v1"
    let complete = try importing.fetch(FetchDescriptor<SearchPreferenceRecord>(predicate: #Predicate { $0.key == marker })).first
    if complete == nil {
      let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
      var expected: [String: Data] = [:]
      do {
        for source in sources {
          try Task.checkCancellation()
          let id = source.deletingPathExtension().lastPathComponent
          let data = try Data(contentsOf: source)
          // Validate before committing; malformed old data must never be replaced by empty defaults.
          if id == key("preferences") { _ = try JSONDecoder().decode(SearchPreferences.self, from: data) }
          else if id == key("geo") { _ = try JSONDecoder().decode([String: String].self, from: data) }
          else { _ = try JSONDecoder().decode(SearchAnalysis.self, from: data) }
          expected[id] = data
          if id == key("preferences") || id == key("geo") { importing.insert(SearchPreferenceRecord(key: id, payload: data)) }
          else { importing.insert(SearchIndexRecord(key: id, payload: data)) }
        }
        importing.insert(SearchPreferenceRecord(key: marker, payload: Data("1".utf8)))
        try Task.checkCancellation()
        try importing.save()
        // Reopen the context and verify the exact bytes, including pending paid-request IDs.
        let verification = ModelContext(container)
        let index = try verification.fetch(FetchDescriptor<SearchIndexRecord>())
        let preferences = try verification.fetch(FetchDescriptor<SearchPreferenceRecord>())
        let actual = Dictionary(uniqueKeysWithValues: index.map { ($0.key, $0.payload) } + preferences.map { ($0.key, $0.payload) })
        guard expected.allSatisfy({ actual[$0.key] == $0.value }) else { throw ArchiveError.invalidData }
      } catch { importing.rollback(); throw error }
    }
    let context = ModelContext(container); context.autosaveEnabled = false
    self.container = container; self.context = context
  }
  func read<T: Decodable & Sendable>(_ type: T.Type, id: String) throws -> T? {
    try prepare(); let lookup = key(id)
    let data: Data?
    if isPreference(id) { data = try context!.fetch(FetchDescriptor<SearchPreferenceRecord>(predicate: #Predicate { $0.key == lookup })).first?.payload }
    else { data = try context!.fetch(FetchDescriptor<SearchIndexRecord>(predicate: #Predicate { $0.key == lookup })).first?.payload }
    guard let data else { return nil }
    if type == SearchAnalysis.self {
      var analysis = try JSONDecoder().decode(SearchAnalysis.self, from: data)
      if analysis.cloudModelVersion == nil { analysis.cloudModelVersion = try storedPreferences()?.modelVersion }
      return analysis as? T
    }
    return try JSONDecoder().decode(type, from: data)
  }
  func readAnalyses(ids: [String]) throws -> [String: SearchAnalysis] {
    try prepare()
    let records = try context!.fetch(FetchDescriptor<SearchIndexRecord>())
    let lookup = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.payload) })
    var result: [String: SearchAnalysis] = [:]
    let version = try storedPreferences()?.modelVersion
    for id in ids {
      try Task.checkCancellation()
      if let data = lookup[key(id)] {
        var analysis = try JSONDecoder().decode(SearchAnalysis.self, from: data)
        if analysis.cloudModelVersion == nil { analysis.cloudModelVersion = version }
        result[id] = analysis
      }
    }
    return result
  }
  func write<T: Encodable & Sendable>(_ value: T, id: String) throws {
    try prepare(); try Task.checkCancellation()
    let lookup = key(id)
    let payload: Data
    if let analysis = value as? SearchAnalysis {
      payload = try JSONEncoder.sorted.encode(normalize(analysis, version: storedPreferences()?.modelVersion))
    } else if var preferences = value as? SearchPreferences {
      // The model epoch belongs to the atomic transition, not delayed UI preference snapshots.
      if let stored = try storedPreferences() { preferences.modelVersion = stored.modelVersion }
      payload = try JSONEncoder.sorted.encode(preferences)
    } else { payload = try JSONEncoder.sorted.encode(value) }
    do {
      if isPreference(id) {
        if let existing = try context!.fetch(FetchDescriptor<SearchPreferenceRecord>(predicate: #Predicate { $0.key == lookup })).first { existing.payload = payload }
        else { context!.insert(SearchPreferenceRecord(key: lookup, payload: payload)) }
      } else {
        if let existing = try context!.fetch(FetchDescriptor<SearchIndexRecord>(predicate: #Predicate { $0.key == lookup })).first { existing.payload = payload }
        else { context!.insert(SearchIndexRecord(key: lookup, payload: payload)) }
      }
      try context!.save()
    } catch { context!.rollback(); throw error }
  }
  private func storedPreferences() throws -> SearchPreferences? {
    let lookup = key("preferences")
    return try context!.fetch(FetchDescriptor<SearchPreferenceRecord>(predicate: #Predicate { $0.key == lookup })).first
      .map { try JSONDecoder().decode(SearchPreferences.self, from: $0.payload) }
  }
  private func normalize(_ input: SearchAnalysis, version: String?) -> SearchAnalysis {
    var result = input
    if result.cloudModelVersion != version {
      result.description = ""; result.decisions = [:]; result.visualModel = ""; result.cloudModelVersion = version
    }
    return result
  }
  func saveAnalysis(_ analysis: SearchAnalysis, id: String) throws -> SearchAnalysis {
    try prepare()
    let saved = normalize(analysis, version: try storedPreferences()?.modelVersion)
    try write(saved, id: id)
    return saved
  }
  /// Evidence invalidation and its epoch commit together. Cancellation/failure leaves both old.
  /// beforeCommit is a fault-injection seam for the same transaction used in production.
  func transitionCloudModel(to version: String, beforeCommit: @Sendable () throws -> Void = {}) throws {
    try prepare(); try Task.checkCancellation()
    var preferences = try storedPreferences() ?? SearchPreferences()
    guard preferences.modelVersion != version else { return }
    do {
      for row in try context!.fetch(FetchDescriptor<SearchIndexRecord>()) {
        try Task.checkCancellation()
        let analysis = try JSONDecoder().decode(SearchAnalysis.self, from: row.payload)
        row.payload = try JSONEncoder.sorted.encode(normalize(analysis, version: version))
      }
      preferences.modelVersion = version
      let lookup = key("preferences"), payload = try JSONEncoder.sorted.encode(preferences)
      if let row = try context!.fetch(FetchDescriptor<SearchPreferenceRecord>(predicate: #Predicate { $0.key == lookup })).first { row.payload = payload }
      else { context!.insert(SearchPreferenceRecord(key: lookup, payload: payload)) }
      try beforeCommit(); try Task.checkCancellation(); try context!.save()
    } catch { context!.rollback(); throw error }
  }

}
