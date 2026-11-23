import Foundation
import SwiftData
import CryptoKit

struct ArchiveCompatibilitySnapshot: Codable, Sendable {
  var format = 1
  var createdAt = Date()
  var owners: [String: LiveDocument]
}

private struct ArchiveActiveStore: Codable {
  var format = 2
  var folder: String
  var migratedOwners: [String: String]
}

/// Legacy is opened read-only. Its logical export includes SQLite's committed WAL state;
/// copying just archive.store would omit those transactions. Nothing replaces the source.
enum ArchiveMigration {
  static let markerName = "archive-v2-active.json"

  static func open(directory: URL, inMemory: Bool,
                   beforePublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveDatabase {
    if inMemory { return try ArchiveDatabase(modelContainer: ArchiveDatabase.container(at: nil, inMemory: true)) }
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let marker = directory.appendingPathComponent(markerName)
    if files.fileExists(atPath: marker.path) {
      let active = try JSONDecoder().decode(ArchiveActiveStore.self, from: Data(contentsOf: marker))
      guard active.format == 2, active.folder.hasPrefix("archive-v2-"), !active.folder.contains("/"), !active.folder.contains("..") else { throw ArchiveStorageError.invalidMigration }
      let url = directory.appendingPathComponent(active.folder).appendingPathComponent("archive.store")
      guard files.fileExists(atPath: url.path) else { throw ArchiveStorageError.invalidMigration }
      // An invalid active store is surfaced, never silently replaced with an older backup.
      return try ArchiveDatabase(modelContainer: ArchiveDatabase.container(at: url))
    }

    let documents = try readLegacy(directory: directory)
    let identifier = UUID().uuidString.lowercased()
    let backups = directory.appendingPathComponent("migration-backups", isDirectory: true)
    try files.createDirectory(at: backups, withIntermediateDirectories: true)
    let snapshot = ArchiveCompatibilitySnapshot(owners: documents)
    let backup = backups.appendingPathComponent("legacy-\(identifier).json")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(snapshot)
    try bytes.write(to: backup, options: [.atomic, .completeFileProtection])
    let restored = try JSONDecoder().decode(ArchiveCompatibilitySnapshot.self, from: Data(contentsOf: backup))
    guard restored.owners == documents else { throw ArchiveStorageError.invalidMigration }

    let folderName = "archive-v2-\(identifier)"
    let folder = directory.appendingPathComponent(folderName, isDirectory: true)
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let storeURL = folder.appendingPathComponent("archive.store")
    try await writeImported(documents, at: storeURL)
    // Open a new container and read every owner back before publishing the switch marker.
    let reopened = try ArchiveDatabase(modelContainer: ArchiveDatabase.container(at: storeURL))
    let checked = try await reopened.allDocuments()
    guard checked == documents else { throw ArchiveStorageError.invalidMigration }
    var checksums: [String: String] = [:]
    for (owner, document) in documents { checksums[owner] = SHA256.hash(data: try encoder.encode(document)).map { String(format: "%02x", $0) }.joined() }
    let active = ArchiveActiveStore(folder: folderName, migratedOwners: checksums)
    // Internal failure injection proves that a validated staging store is still
    // recoverable when cancellation or a disk-write error prevents publication.
    try beforePublish?()
    try encoder.encode(active).write(to: marker, options: [.atomic, .completeFileProtection])
    return reopened
  }

  private static func writeImported(_ documents: [String: LiveDocument], at url: URL) async throws {
    let writer = try ArchiveDatabase(modelContainer: ArchiveDatabase.container(at: url))
    try await writer.importOwners(documents)
  }

  private static func readLegacy(directory: URL) throws -> [String: LiveDocument] {
    let url = directory.appendingPathComponent("archive.store")
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let configuration = ModelConfiguration(url: url, allowsSave: false, cloudKitDatabase: .none)
    let container = try ModelContainer(for: StoredArchive.self, configurations: configuration)
    let context = ModelContext(container); context.autosaveEnabled = false
    var documents: [String: LiveDocument] = [:]
    for row in try context.fetch(FetchDescriptor<StoredArchive>()) {
      let document = try JSONDecoder().decode(LiveDocument.self, from: row.data)
      try document.validate()
      guard documents[row.owner] == nil else { throw ArchiveStorageError.invalidMigration }
      documents[row.owner] = document
    }
    return documents
  }
}
