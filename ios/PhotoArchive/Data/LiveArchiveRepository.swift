import Foundation

/// Small interface over migration, an isolated SwiftData executor and paged queries.
/// Initialization is cheap; opening/validation/migration happens off the UI actor.
actor LiveArchiveRepository {
  private let directory: URL
  private let inMemory: Bool
  private var opening: Task<ArchiveDatabase, Error>?
  init(directory: URL, inMemory: Bool = false) throws {
    self.directory = directory; self.inMemory = inMemory
  }
  private func database() async throws -> ArchiveDatabase {
    if let opening { return try await opening.value }
    let directory = directory, inMemory = inMemory
    let task = Task.detached(priority: .userInitiated) {
      try await ArchiveMigration.open(directory: directory, inMemory: inMemory)
    }
    opening = task
    do { return try await task.value }
    catch { opening = nil; throw error }
  }
  func bootstrap(owner: String) async throws -> ArchiveBootstrap { try await database().bootstrap(owner: owner) }
  func exists(owner: String) async throws -> Bool { try await database().exists(owner: owner) }
  func load(owner: String) async throws -> LiveDocument { try await database().read(owner: owner).document }
  func read(owner: String) async throws -> ArchiveReadModel { try await database().read(owner: owner) }
  func save(_ document: LiveDocument, owner: String) async throws { _ = try await database().save(document, owner: owner) }
  func update(owner: String, impact: ArchiveMutationImpact = .library,
              _ mutation: @escaping @Sendable (inout LiveDocument) throws -> Void) async throws -> ArchiveReadModel {
    try await database().update(owner: owner, impact: impact, mutation)
  }
  func adoptGuest(into owner: String) async throws -> LiveDocument {
    try await database().adoptGuest(into: owner, backupDirectory: directory).document
  }
  func adoptGuestReadModel(into owner: String) async throws -> ArchiveReadModel {
    try await database().adoptGuest(into: owner, backupDirectory: directory)
  }
  func remove(owner: String) async throws { try await database().remove(owner: owner) }
  func page(owner: String, query: LibraryQuery, cursor: LibraryCursor?, limit: Int = 120) async throws -> LibraryPage {
    try await database().page(owner: owner, query: query, cursor: cursor, limit: limit)
  }
  /// Explicit current-format export for recovery/rollback preparation. It includes edits made
  /// after migration; the immutable legacy backup alone is not a safe post-upgrade rollback.
  func exportCompatibilitySnapshot() async throws -> URL {
    let url = directory.appendingPathComponent("compatibility-\(UUID().uuidString.lowercased()).json")
    try await database().exportCompatibilitySnapshot(to: url)
    return url
  }
}

extension ArchiveDatabase {
  func exportCompatibilitySnapshot(to url: URL) throws {
    let snapshot = ArchiveCompatibilitySnapshot(owners: try allDocuments())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(snapshot)
    try bytes.write(to: url, options: [.atomic, .completeFileProtection])
    let check = try JSONDecoder().decode(ArchiveCompatibilitySnapshot.self, from: Data(contentsOf: url))
    guard check.owners == snapshot.owners else { throw ArchiveStorageError.invalidMigration }
  }
}
