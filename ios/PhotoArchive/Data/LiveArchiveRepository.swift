import Foundation
import SwiftData

@Model final class StoredArchive {
  @Attribute(.unique) var owner: String
  var data: Data
  init(owner: String, data: Data) { self.owner = owner; self.data = data }
}

@MainActor final class LiveArchiveRepository {
  private let container: ModelContainer
  private let context: ModelContext
  private let directory: URL
  init(directory: URL, inMemory: Bool = false) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = inMemory
      ? ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      : ModelConfiguration(url: directory.appendingPathComponent("archive.store"), cloudKitDatabase: .none)
    container = try ModelContainer(for: StoredArchive.self, configurations: config)
    context = ModelContext(container)
    context.autosaveEnabled = false
  }
  private func row(_ owner: String) throws -> StoredArchive? {
    var descriptor = FetchDescriptor<StoredArchive>(predicate: #Predicate { $0.owner == owner })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }
  func exists(owner: String) throws -> Bool { try row(owner) != nil }
  func load(owner: String) throws -> LiveDocument {
    guard let row = try row(owner) else { return LiveDocument() }
    let document = try JSONDecoder().decode(LiveDocument.self, from: row.data)
    try document.validate()
    return document
  }
  func save(_ document: LiveDocument, owner: String) throws {
    try document.validate()
    let bytes = try JSONEncoder().encode(document)
    do {
      if let existing = try row(owner) { existing.data = bytes }
      else { context.insert(StoredArchive(owner: owner, data: bytes)) }
      try context.save()
    } catch { context.rollback(); throw error }
  }
  func adoptGuest(into owner: String) throws -> LiveDocument {
    guard owner != "guest" else { throw ArchiveError.invalidData }
    let guest = try load(owner: "guest")
    var account = try load(owner: owner)
    // Save the exact previous guest document before the atomic two-owner transaction.
    let backup = directory.appendingPathComponent("guest-backup-\(UUID().uuidString).json")
    try JSONEncoder().encode(guest).write(to: backup, options: [.atomic, .completeFileProtection])
    for (id, item) in guest.media where account.media[id] == nil { account.media[id] = item }
    account.cloudIDs.merge(guest.cloudIDs) { old, _ in old }
    for story in guest.snapshot.stories {
      guard !account.snapshot.stories.contains(where: { $0.id == story.id }) else { continue }
      account.snapshot.stories.append(story)
    }
    account.snapshot.corrections.merge(guest.snapshot.corrections) { old, _ in old }
    for operation in guest.outbox where !account.outbox.contains(where: { $0.id == operation.id }) {
      account.outbox.append(operation)
    }
    account.syncEnabled = true
    try account.validate()
    do {
      let bytes = try JSONEncoder().encode(account)
      if let row = try row(owner) { row.data = bytes } else { context.insert(StoredArchive(owner: owner, data: bytes)) }
      if let guestRow = try row("guest") { guestRow.data = try JSONEncoder().encode(LiveDocument()) }
      try context.save()
      return account
    } catch { context.rollback(); throw error }
  }
  func remove(owner: String) throws {
    do { if let row = try row(owner) { context.delete(row); try context.save() } }
    catch { context.rollback(); throw error }
  }
}
