import Foundation
import SwiftData

/// All commands run to completion on one private SwiftData executor. A command reads the
/// latest owner document here, so an await in a caller cannot overwrite a concurrent edit.
@ModelActor actor ArchiveDatabase {
  private var cached: [String: ArchiveReadModel] = [:]

  nonisolated static func container(at url: URL?, inMemory: Bool = false) throws -> ModelContainer {
    let schema = Schema([ArchiveOwnerRow.self, ArchiveMediaRow.self, ArchiveEntityRow.self])
    let config: ModelConfiguration
    if inMemory { config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none) }
    else { config = ModelConfiguration(schema: schema, url: url!, cloudKitDatabase: .none) }
    return try ModelContainer(for: schema, configurations: [config])
  }

  private func ownerRow(_ owner: String) throws -> ArchiveOwnerRow? {
    var descriptor = FetchDescriptor<ArchiveOwnerRow>(predicate: #Predicate { $0.owner == owner })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
  func exists(owner: String) throws -> Bool { try ownerRow(owner) != nil }

  /// Opening the gallery needs only its first page and organization metadata. The
  /// complete media/version/outbox decode remains a separate background operation.
  func bootstrap(owner: String) throws -> ArchiveBootstrap {
    modelContext.autosaveEnabled = false
    var document = LiveDocument()
    if let row = try ownerRow(owner) {
      document.schema = row.schema; document.snapshot.version = row.snapshotVersion
      document.cursor = row.cursor; document.syncEnabled = row.syncEnabled; document.lastSync = row.lastSync
    }
    let firstPage = try page(owner: owner, query: LibraryQuery(), cursor: nil, limit: 120)
    document.media = Dictionary(uniqueKeysWithValues: firstPage.items.map { ($0.id, $0) })
    let ids = firstPage.items.map(\.id)
    let corrections = try modelContext.fetch(FetchDescriptor<ArchiveEntityRow>(
      predicate: #Predicate { $0.owner == owner && $0.namespace == "correction" && ids.contains($0.entityID) }))
    for row in corrections {
      document.snapshot.corrections[row.entityID] = try JSONDecoder().decode(MetadataCorrection.self, from: row.payload)
    }
    return ArchiveBootstrap(document: document, firstPage: firstPage)
  }

  func read(owner: String) throws -> ArchiveReadModel {
    if let value = cached[owner] { return value }
    modelContext.autosaveEnabled = false
    guard let row = try ownerRow(owner) else { return makeReadModel(LiveDocument(), owner: owner, revision: 0, libraryRevision: 0, searchRevision: 0) }
    var document = LiveDocument()
    document.schema = row.schema; document.snapshot.version = row.snapshotVersion
    document.cursor = row.cursor; document.syncEnabled = row.syncEnabled; document.lastSync = row.lastSync
    let media = try modelContext.fetch(FetchDescriptor<ArchiveMediaRow>(predicate: #Predicate { $0.owner == owner }))
    for row in media { document.media[row.mediaID] = try JSONDecoder().decode(MediaItem.self, from: row.payload) }
    let entities = try modelContext.fetch(FetchDescriptor<ArchiveEntityRow>(predicate: #Predicate { $0.owner == owner }, sortBy: [SortDescriptor(\.position)]))
    var storyMedia: [String: [String]] = [:]
    for row in entities {
      let decoder = JSONDecoder()
      switch row.namespace {
      case "story": document.snapshot.stories.append(try decoder.decode(Story.self, from: row.payload))
      case "correction": document.snapshot.corrections[row.entityID] = try decoder.decode(MetadataCorrection.self, from: row.payload)
      case "cloud": document.cloudIDs[row.entityID] = try decoder.decode(String.self, from: row.payload)
      case "version": document.versions[row.entityID] = try decoder.decode(Int64.self, from: row.payload)
      case "operation": document.outbox.append(try decoder.decode(SyncOperation.self, from: row.payload))
      case "conflict": document.conflicts.append(try decoder.decode(SyncConflict.self, from: row.payload))
      default:
        guard row.namespace.hasPrefix("story-media:") else { throw ArchiveStorageError.invalidMigration }
        let storyID = String(row.namespace.dropFirst("story-media:".count))
        let mediaID = try decoder.decode(String.self, from: row.payload)
        guard mediaID == row.entityID else { throw ArchiveStorageError.invalidMigration }
        storyMedia[storyID, default: []].append(mediaID)
      }
    }
    for index in document.snapshot.stories.indices {
      let id = document.snapshot.stories[index].id
      // Earlier v2 stores embedded mediaIDs in the story payload. Keep reading
      // those until the first edit materializes independently ordered relations.
      if let mediaIDs = storyMedia[id] { document.snapshot.stories[index].mediaIDs = mediaIDs }
    }
    guard Set(storyMedia.keys).isSubset(of: Set(document.snapshot.stories.map(\.id))) else { throw ArchiveStorageError.invalidMigration }
    try document.validate()
    return makeReadModel(document, owner: owner, revision: row.revision, libraryRevision: row.libraryRevision, searchRevision: row.searchRevision)
  }

  private func makeReadModel(_ document: LiveDocument, owner: String, revision: Int, libraryRevision: Int,
                             searchRevision: Int, reuseVisible: [MediaItem]? = nil) -> ArchiveReadModel {
    let visible: [MediaItem]
    if let reuseVisible { visible = reuseVisible }
    else {
      visible = document.media.values.filter { $0.accessible || (owner != "guest" && document.syncEnabled) }.sorted {
        let left = document.effectiveDay(for: $0)?.librarySortKey ?? 0
        let right = document.effectiveDay(for: $1)?.librarySortKey ?? 0
        return left == right ? $0.id < $1.id : left > right
      }
    }
    let model = ArchiveReadModel(document: document, visibleMedia: visible, revision: revision,
                                 libraryRevision: libraryRevision, searchRevision: searchRevision)
    cached[owner] = model
    return model
  }

  private func yearsData(_ document: LiveDocument, owner: String) throws -> Data {
    let years = Set(document.media.values.lazy.filter { $0.accessible || (owner != "guest" && document.syncEnabled) }
      .compactMap { document.effectiveDay(for: $0)?.year })
    return try JSONEncoder().encode(years.sorted(by: >))
  }

  @discardableResult
  func update(owner: String, impact: ArchiveMutationImpact = .library,
              _ mutation: @Sendable (inout LiveDocument) throws -> Void) throws -> ArchiveReadModel {
    let previous = try read(owner: owner)
    var next = previous.document
    try mutation(&next)
    return try commit(next, owner: owner, previous: previous, impact: impact)
  }

  @discardableResult
  func save(_ document: LiveDocument, owner: String) throws -> ArchiveReadModel {
    try commit(document, owner: owner, previous: read(owner: owner), impact: .library)
  }

  private func commit(_ next: LiveDocument, owner: String, previous: ArchiveReadModel,
                      impact: ArchiveMutationImpact) throws -> ArchiveReadModel {
    // Validation/encoding/comparison remain on this executor, never the UI actor.
    try next.validate()
    let old = previous.document
    if next == old, try ownerRow(owner) != nil { return previous }
    let mediaChanged = impact == .library && next.media != old.media
    let correctionsChanged = next.snapshot.corrections != old.snapshot.corrections
    let visibilityChanged = owner != "guest" && next.syncEnabled != old.syncEnabled
    let libraryChanged = mediaChanged || correctionsChanged || visibilityChanged
    do {
      try stage(next, replacing: old, owner: owner, mediaChanged: mediaChanged, correctionsChanged: correctionsChanged)
      let row = try ownerRow(owner) ?? ArchiveOwnerRow(owner: owner)
      if row.modelContext == nil { modelContext.insert(row) }
      row.schema = next.schema; row.snapshotVersion = next.snapshot.version
      row.cursor = next.cursor; row.syncEnabled = next.syncEnabled; row.lastSync = next.lastSync
      row.revision = previous.revision + 1
      row.libraryRevision = previous.libraryRevision + (libraryChanged ? 1 : 0)
      row.searchRevision = previous.searchRevision + (libraryChanged ? 1 : 0)
      if libraryChanged || row.yearsData.isEmpty { row.yearsData = try yearsData(next, owner: owner) }
      try modelContext.save()
      return makeReadModel(next, owner: owner, revision: row.revision, libraryRevision: row.libraryRevision,
                           searchRevision: row.searchRevision, reuseVisible: libraryChanged ? nil : previous.visibleMedia)
    } catch { modelContext.rollback(); throw error }
  }

  private func stage(_ next: LiveDocument, replacing old: LiveDocument, owner: String,
                     mediaChanged: Bool = true, correctionsChanged: Bool = true) throws {
    if mediaChanged || correctionsChanged {
      let correctionIDs = Set(next.snapshot.corrections.keys).union(old.snapshot.corrections.keys)
        .filter { next.snapshot.corrections[$0] != old.snapshot.corrections[$0] }
      var changed = Set(correctionIDs)
      if mediaChanged {
        for (id, item) in next.media where old.media[id] != item { changed.insert(id) }
        for id in old.media.keys where next.media[id] == nil { changed.insert(id) }
      }
      for id in changed {
        let key = ArchiveMediaRow.key(owner, id)
        var descriptor = FetchDescriptor<ArchiveMediaRow>(predicate: #Predicate { $0.key == key }); descriptor.fetchLimit = 1
        let existing = old.media[id] == nil ? nil : try modelContext.fetch(descriptor).first
        if let item = next.media[id] {
          let data = try JSONEncoder().encode(item)
          let day = next.effectiveDay(for: item)
          if let existing { existing.update(item: item, payload: data, effectiveDay: day) }
          else { modelContext.insert(ArchiveMediaRow(owner: owner, item: item, payload: data, effectiveDay: day)) }
        } else if let existing { modelContext.delete(existing) }
      }
    }
    try syncStories(next.snapshot.stories, old.snapshot.stories, owner: owner)
    try syncDictionary(next.snapshot.corrections, old.snapshot.corrections, owner: owner, namespace: "correction")
    try syncDictionary(next.cloudIDs, old.cloudIDs, owner: owner, namespace: "cloud")
    try syncDictionary(next.versions, old.versions, owner: owner, namespace: "version")
    try sync(next.outbox.map { ($0.id, $0) }, old.outbox.map { ($0.id, $0) }, owner: owner, namespace: "operation")
    try sync(next.conflicts.map { ($0.id, $0) }, old.conflicts.map { ($0.id, $0) }, owner: owner, namespace: "conflict")
  }

  private func syncStories(_ next: [Story], _ old: [Story], owner: String) throws {
    let before = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
    let remaining = Set(next.map(\.id))
    for (position, story) in next.enumerated() {
      let previous = before[story.id]
      guard previous?.0 != position || previous?.1 != story else { continue }
      let key = ArchiveEntityRow.key(owner, "story", story.id)
      var descriptor = FetchDescriptor<ArchiveEntityRow>(predicate: #Predicate { $0.key == key }); descriptor.fetchLimit = 1
      let existing = previous == nil ? nil : try modelContext.fetch(descriptor).first
      let persisted = try existing.map { try JSONDecoder().decode(Story.self, from: $0.payload) }
      let legacy = persisted?.mediaIDs.isEmpty == false
      let oldIDs = legacy ? [] : previous?.1.mediaIDs ?? []
      try sync(story.mediaIDs.map { ($0, $0) }, oldIDs.map { ($0, $0) }, owner: owner, namespace: "story-media:" + story.id)
      var metadata = story; metadata.mediaIDs = []
      let payload = try JSONEncoder().encode(metadata)
      if let existing {
        if existing.payload != payload { existing.payload = payload }
        if existing.position != position { existing.position = position }
      } else {
        modelContext.insert(ArchiveEntityRow(owner: owner, namespace: "story", id: story.id, position: position, payload: payload))
      }
    }
    for story in old where !remaining.contains(story.id) {
      try sync([String]().map { ($0, $0) }, story.mediaIDs.map { ($0, $0) }, owner: owner, namespace: "story-media:" + story.id)
      let key = ArchiveEntityRow.key(owner, "story", story.id)
      var descriptor = FetchDescriptor<ArchiveEntityRow>(predicate: #Predicate { $0.key == key }); descriptor.fetchLimit = 1
      if let row = try modelContext.fetch(descriptor).first { modelContext.delete(row) }
    }
  }

  private func syncDictionary<T: Codable & Equatable>(_ next: [String: T], _ old: [String: T], owner: String, namespace: String) throws {
    guard next != old else { return }
    // Unordered records have no meaningful position; avoid sorting the version table on every receipt.
    try sync(next.map { ($0.key, $0.value) }, old.map { ($0.key, $0.value) }, owner: owner, namespace: namespace, ordered: false)
  }
  private func sync<T: Codable & Equatable>(_ next: [(String, T)], _ old: [(String, T)], owner: String,
                                           namespace: String, ordered: Bool = true) throws {
    let previous = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.0, ($0.offset, $0.element.1)) })
    let ids = Set(next.map(\.0))
    for (position, entry) in next.enumerated() {
      if let old = previous[entry.0], old.1 == entry.1, !ordered || old.0 == position { continue }
      let key = ArchiveEntityRow.key(owner, namespace, entry.0)
      var descriptor = FetchDescriptor<ArchiveEntityRow>(predicate: #Predicate { $0.key == key }); descriptor.fetchLimit = 1
      let existing = previous[entry.0] == nil ? nil : try modelContext.fetch(descriptor).first
      let payload = try JSONEncoder().encode(entry.1)
      if let existing { existing.payload = payload; existing.position = ordered ? position : 0 }
      else { modelContext.insert(ArchiveEntityRow(owner: owner, namespace: namespace, id: entry.0, position: ordered ? position : 0, payload: payload)) }
    }
    for (id, _) in old where !ids.contains(id) {
      let key = ArchiveEntityRow.key(owner, namespace, id)
      var descriptor = FetchDescriptor<ArchiveEntityRow>(predicate: #Predicate { $0.key == key }); descriptor.fetchLimit = 1
      if let row = try modelContext.fetch(descriptor).first { modelContext.delete(row) }
    }
  }

  func importOwners(_ documents: [String: LiveDocument]) throws {
    modelContext.autosaveEnabled = false
    do {
      for (owner, document) in documents {
        try document.validate()
        guard try ownerRow(owner) == nil else { throw ArchiveStorageError.invalidMigration }
        try stage(document, replacing: LiveDocument(), owner: owner)
        let row = ArchiveOwnerRow(owner: owner)
        row.schema = document.schema; row.snapshotVersion = document.snapshot.version
        row.cursor = document.cursor; row.syncEnabled = document.syncEnabled; row.lastSync = document.lastSync
        row.yearsData = try yearsData(document, owner: owner)
        modelContext.insert(row)
      }
      try modelContext.save()
    } catch { modelContext.rollback(); throw error }
  }

  func adoptGuest(into owner: String, backupDirectory: URL) throws -> ArchiveReadModel {
    guard owner != "guest" else { throw ArchiveError.invalidData }
    let guest = try read(owner: "guest")
    let previous = try read(owner: owner)
    var account = previous.document
    let backup = backupDirectory.appendingPathComponent("guest-backup-\(UUID().uuidString).json")
    try JSONEncoder().encode(guest.document).write(to: backup, options: [.atomic, .completeFileProtection])
    for (id, item) in guest.document.media where account.media[id] == nil { account.media[id] = item }
    account.cloudIDs.merge(guest.document.cloudIDs) { old, _ in old }
    for story in guest.document.snapshot.stories where !account.snapshot.stories.contains(where: { $0.id == story.id }) { account.snapshot.stories.append(story) }
    account.snapshot.corrections.merge(guest.document.snapshot.corrections) { old, _ in old }
    for operation in guest.document.outbox where !account.outbox.contains(where: { $0.id == operation.id }) { account.outbox.append(operation) }
    // Guest versions/conflicts normally are empty, but must survive a recovered/offline archive.
    account.versions.merge(guest.document.versions) { max($0, $1) }
    for conflict in guest.document.conflicts where !account.conflicts.contains(where: { $0.id == conflict.id }) { account.conflicts.append(conflict) }
    account.syncEnabled = true
    try account.validate()
    do {
      try stage(account, replacing: previous.document, owner: owner)
      try stage(LiveDocument(), replacing: guest.document, owner: "guest")
      let accountRow = try ownerRow(owner) ?? ArchiveOwnerRow(owner: owner)
      if accountRow.modelContext == nil { modelContext.insert(accountRow) }
      accountRow.schema = account.schema; accountRow.snapshotVersion = account.snapshot.version
      accountRow.cursor = account.cursor; accountRow.syncEnabled = true; accountRow.lastSync = account.lastSync
      accountRow.yearsData = try yearsData(account, owner: owner)
      accountRow.revision = previous.revision + 1; accountRow.libraryRevision = previous.libraryRevision + 1; accountRow.searchRevision = previous.searchRevision + 1
      let guestRow = try ownerRow("guest") ?? ArchiveOwnerRow(owner: "guest")
      if guestRow.modelContext == nil { modelContext.insert(guestRow) }
      guestRow.cursor = 0; guestRow.syncEnabled = false; guestRow.lastSync = nil; guestRow.yearsData = try JSONEncoder().encode([Int]())
      guestRow.revision = guest.revision + 1; guestRow.libraryRevision = guest.libraryRevision + 1; guestRow.searchRevision = guest.searchRevision + 1
      try modelContext.save()
      cached.removeValue(forKey: "guest")
      return makeReadModel(account, owner: owner, revision: accountRow.revision,
                           libraryRevision: accountRow.libraryRevision, searchRevision: accountRow.searchRevision)
    } catch { modelContext.rollback(); throw error }
  }

  func remove(owner: String) throws {
    do {
      for row in try modelContext.fetch(FetchDescriptor<ArchiveMediaRow>(predicate: #Predicate { $0.owner == owner })) { modelContext.delete(row) }
      for row in try modelContext.fetch(FetchDescriptor<ArchiveEntityRow>(predicate: #Predicate { $0.owner == owner })) { modelContext.delete(row) }
      if let row = try ownerRow(owner) { modelContext.delete(row) }
      try modelContext.save(); cached.removeValue(forKey: owner)
    } catch { modelContext.rollback(); throw error }
  }

  func allDocuments() throws -> [String: LiveDocument] {
    var result: [String: LiveDocument] = [:]
    for row in try modelContext.fetch(FetchDescriptor<ArchiveOwnerRow>()) { result[row.owner] = try read(owner: row.owner).document }
    return result
  }

  func page(owner: String, query: LibraryQuery, cursor: LibraryCursor?, limit: Int) throws -> LibraryPage {
    // A cold first page reads only the owner header and at most limit + 1 media rows.
    // Compatibility snapshots are deliberately not loaded by the paging interface.
    let state = try ownerRow(owner)
    let revision = state?.libraryRevision ?? 0
    let years = try state.map { row in row.yearsData.isEmpty ? [] : try JSONDecoder().decode([Int].self, from: row.yearsData) } ?? []
    if let cursor, cursor.owner != owner || cursor.query != query || cursor.revision != revision { throw ArchiveStorageError.staleCursor }
    let allVisible = owner != "guest" && state?.syncEnabled == true && !query.accessibleOnly
    let kind = query.kind?.rawValue ?? ""
    let year = query.year ?? 0, month = query.month ?? 0
    let excluded = Array(query.excludedIDs), included = Array(query.includedIDs ?? [])
    let hasIncluded = query.includedIDs != nil
    let anniversary = query.anniversary != nil
    let anniversaryYear = query.anniversary?.year ?? 0, anniversaryMonth = query.anniversary?.month ?? 0, anniversaryDay = query.anniversary?.day ?? 0
    let visibility = #Predicate<ArchiveMediaRow> { row in row.owner == owner && (allVisible || row.accessible) }
    let typeAndDate = #Predicate<ArchiveMediaRow> { row in
      (kind == "" || row.kind == kind) && (year == 0 || row.year == year) && (month == 0 || row.month == month)
    }
    let selection = #Predicate<ArchiveMediaRow> { row in !excluded.contains(row.mediaID) && (!hasIncluded || included.contains(row.mediaID)) }
    let anniversaryFilter = #Predicate<ArchiveMediaRow> { row in
      !anniversary || (row.year > 0 && row.year < anniversaryYear && row.month == anniversaryMonth && row.day == anniversaryDay)
    }
    let base = #Predicate<ArchiveMediaRow> { row in
      visibility.evaluate(row) && typeAndDate.evaluate(row) && selection.evaluate(row) && anniversaryFilter.evaluate(row)
    }
    let total = try modelContext.fetchCount(FetchDescriptor<ArchiveMediaRow>(predicate: base))
    let hasCursor = cursor != nil, lastDay = cursor?.dayKey ?? 0, lastID = cursor?.mediaID ?? ""
    let paged = #Predicate<ArchiveMediaRow> { row in
      base.evaluate(row) && (!hasCursor || row.dayKey < lastDay || (row.dayKey == lastDay && row.mediaID > lastID))
    }
    var descriptor = FetchDescriptor<ArchiveMediaRow>(predicate: paged,
      sortBy: [SortDescriptor(\.dayKey, order: .reverse), SortDescriptor(\.mediaID)])
    let size = max(1, min(limit, 500)); descriptor.fetchLimit = size + 1
    let rows = try modelContext.fetch(descriptor)
    let selected = Array(rows.prefix(size))
    let items = try selected.map { try JSONDecoder().decode(MediaItem.self, from: $0.payload) }
    let next = rows.count > size ? selected.last.map { LibraryCursor(owner: owner, revision: revision, query: query, dayKey: $0.dayKey, mediaID: $0.mediaID) } : nil
    let days = Dictionary(uniqueKeysWithValues: selected.filter { $0.dayKey > 0 }.map { ($0.mediaID, ArchiveDay($0.year, $0.month, $0.day)) })
    return LibraryPage(items: items, nextCursor: next, totalCount: total, years: years, effectiveDays: days)
  }
}
