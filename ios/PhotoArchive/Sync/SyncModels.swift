import Foundation

enum OverrideMode: String, Codable, CaseIterable, Sendable { case original, clear, value }

// Explicit network allowlist. Never encode MediaItem or MetadataCorrection for the network.
struct WirePayload: Codable, Equatable, Sendable {
  var kind: String?
  var cloudIdentifier: String?
  var title: String?
  var description: String?
  var mediaIDs: [String]?
  var coverID: String?
  var dayMode: OverrideMode?
  var day: ArchiveDay?
  var placeMode: OverrideMode?
  var place: Place?
  static func story(_ value: Story) -> Self {
    Self(title: value.title, description: value.description, mediaIDs: value.mediaIDs, coverID: value.coverID)
  }
  static func correction(_ value: MetadataCorrection) -> Self {
    Self(description: value.description, dayMode: value.effectiveDayMode,
         day: value.effectiveDayMode == .value ? value.day : nil,
         placeMode: value.effectivePlaceMode,
         place: value.effectivePlaceMode == .value ? value.place : nil)
  }
}
struct SyncRecord: Codable, Equatable, Sendable {
  var entity: String
  var id: String
  var version: Int64
  var deleted: Bool
  var payload: WirePayload
  var key: String { "\(entity):\(id)" }
}
struct SyncOperation: Codable, Equatable, Identifiable, Sendable {
  var id = UUID().uuidString.lowercased()
  var entity: String
  var entityID: String
  var baseVersion: Int64
  var deleted = false
  var payload: WirePayload
  var resolving: String?
  var attempted = false // local only; transport DTO below deliberately excludes this flag
  var key: String { "\(entity):\(entityID)" }
  var wire: PushOperation { PushOperation(id: id, entity: entity, entityID: entityID,
    baseVersion: baseVersion, deleted: deleted, payload: payload, resolving: resolving) }
}
struct PushOperation: Codable, Sendable {
  var id: String
  var entity: String
  var entityID: String
  var baseVersion: Int64
  var deleted: Bool
  var payload: WirePayload
  var resolving: String?
}
struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var local: SyncRecord
  var remote: SyncRecord
  var key: String { local.key }
}
struct SyncChange: Codable, Sendable { var sequence: Int64; var record: SyncRecord }
struct PullPage: Codable, Sendable {
  var changes: [SyncChange]
  var conflicts: [SyncConflict]
  var cursor: Int64
  var hasMore: Bool
}
struct PushResult: Codable, Sendable {
  var status: String
  var record: SyncRecord
  var conflict: SyncConflict?
}
protocol ArchiveTransport: Sendable {
  func pull(after cursor: Int64) async throws -> PullPage
  func push(_ operation: PushOperation) async throws -> PushResult
}
struct LiveDocument: Codable, Equatable, Sendable {
  var schema = 1
  var snapshot = ArchiveSnapshot(stories: [])
  var media: [String: MediaItem] = [:]
  var cloudIDs: [String: String] = [:]
  var versions: [String: Int64] = [:]
  var outbox: [SyncOperation] = []
  var conflicts: [SyncConflict] = []
  var cursor: Int64 = 0
  var syncEnabled = false
  var lastSync: Date?

  mutating func enqueue(entity: String, id: String, payload: WirePayload, deleted: Bool = false,
                        resolving: String? = nil) {
    let key = "\(entity):\(id)"
    // Never modify an operation already sent: its UUID is an immutable idempotency key.
    if let index = outbox.lastIndex(where: { $0.key == key && !$0.attempted && $0.resolving == nil }), resolving == nil {
      outbox[index].payload = payload
      outbox[index].deleted = deleted
    } else {
      outbox.append(SyncOperation(entity: entity, entityID: id, baseVersion: versions[key] ?? 0,
                                  deleted: deleted, payload: payload, resolving: resolving))
    }
  }
  mutating func apply(_ record: SyncRecord, preservePending: Bool = true) {
    guard record.version >= (versions[record.key] ?? 0) else { return }
    versions[record.key] = record.version
    if preservePending && (outbox.contains { $0.key == record.key } || conflicts.contains { $0.key == record.key }) { return }
    switch record.entity {
    case "media":
      if let cloud = record.payload.cloudIdentifier { cloudIDs[record.id] = cloud }
      if media[record.id] == nil {
        media[record.id] = MediaItem(id: record.id, assetName: "", title: "照片未关联",
          kind: record.payload.kind == "video" ? .video : .photo, originalDay: nil,
          originalPlace: nil, source: "云端整理引用")
      }
    case "story":
      snapshot.stories.removeAll { $0.id == record.id }
      if !record.deleted {
        snapshot.stories.append(Story(id: record.id, title: record.payload.title ?? "",
          description: record.payload.description ?? "", mediaIDs: record.payload.mediaIDs ?? [], coverID: record.payload.coverID))
      }
    case "correction":
      snapshot.corrections.removeValue(forKey: record.id)
      if !record.deleted {
        snapshot.corrections[record.id] = MetadataCorrection(mediaID: record.id,
          originalDay: nil, originalPlace: nil, day: record.payload.day, place: record.payload.place,
          description: record.payload.description ?? "", dayMode: record.payload.dayMode,
          placeMode: record.payload.placeMode)
      }
    default: break
    }
  }
  mutating func accept(_ result: PushResult, operationID: String) {
    guard let index = outbox.firstIndex(where: { $0.id == operationID }) else { return }
    let operation = outbox.remove(at: index)
    if let conflict = result.conflict {
      if let resolving = operation.resolving { conflicts.removeAll { $0.id == resolving } }
      conflicts.removeAll { $0.id == conflict.id }
      conflicts.append(conflict)
      versions[result.record.key] = result.record.version
      return
    }
    if let resolving = operation.resolving { conflicts.removeAll { $0.id == resolving } }
    // Edits made during an in-flight request follow that request's committed version.
    for index in outbox.indices where outbox[index].key == operation.key && !outbox[index].attempted {
      outbox[index].baseVersion = result.record.version
    }
    apply(result.record)
  }
  func validate() throws {
    guard schema == 1, cursor >= 0,
      Set(outbox.map(\.id)).count == outbox.count,
      media.allSatisfy({ $0.key == $0.value.id }) else { throw ArchiveError.invalidData }
    try snapshot.validate(mediaIDs: Set(media.keys))
  }
}
