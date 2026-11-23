import Foundation
import SwiftData

// Keep this exact legacy entity available only to the read-only migration reader.
@Model final class StoredArchive {
  @Attribute(.unique) var owner: String
  var data: Data
  init(owner: String, data: Data) { self.owner = owner; self.data = data }
}

@Model final class ArchiveOwnerRow {
  @Attribute(.unique) var owner: String
  var schema: Int
  var snapshotVersion: Int
  var cursor: Int64
  var syncEnabled: Bool
  var lastSync: Date?
  var revision: Int
  var libraryRevision: Int
  var searchRevision: Int
  var yearsData: Data
  init(owner: String) {
    self.owner = owner; schema = 1; snapshotVersion = 1; cursor = 0
    syncEnabled = false; revision = 0; libraryRevision = 0; searchRevision = 0; yearsData = Data()
  }
}

/// Media has queryable date/type columns; paging never decodes the entire archive.
@Model final class ArchiveMediaRow {
  #Index<ArchiveMediaRow>([\.owner, \.dayKey, \.mediaID], [\.owner, \.year, \.month], [\.owner, \.kind])
  @Attribute(.unique) var key: String
  var owner: String
  var mediaID: String
  var payload: Data
  var kind: String
  var accessible: Bool
  var dayKey: Int
  var year: Int
  var month: Int
  var day: Int
  init(owner: String, item: MediaItem, payload: Data, effectiveDay: ArchiveDay?) {
    self.key = Self.key(owner, item.id); self.owner = owner; mediaID = item.id; self.payload = payload
    kind = item.kind.rawValue; accessible = item.accessible
    dayKey = effectiveDay?.librarySortKey ?? 0
    year = effectiveDay?.year ?? 0; month = effectiveDay?.month ?? 0; day = effectiveDay?.day ?? 0
  }
  static func key(_ owner: String, _ id: String) -> String { "\(owner.utf8.count):\(owner)\(id)" }
  func update(item: MediaItem, payload: Data, effectiveDay: ArchiveDay?) {
    self.payload = payload; kind = item.kind.rawValue; accessible = item.accessible
    dayKey = effectiveDay?.librarySortKey ?? 0
    year = effectiveDay?.year ?? 0; month = effectiveDay?.month ?? 0; day = effectiveDay?.day ?? 0
  }
}

/// Each story metadata, ordered story-media relation, correction, mapping, version, operation and conflict is its own row.
/// Position preserves story/outbox/conflict ordering, including attempted operation UUIDs.
@Model final class ArchiveEntityRow {
  #Index<ArchiveEntityRow>([\.owner, \.namespace, \.position])
  @Attribute(.unique) var key: String
  var owner: String
  var namespace: String
  var entityID: String
  var position: Int
  var payload: Data
  init(owner: String, namespace: String, id: String, position: Int, payload: Data) {
    key = Self.key(owner, namespace, id); self.owner = owner; self.namespace = namespace
    entityID = id; self.position = position; self.payload = payload
  }
  static func key(_ owner: String, _ namespace: String, _ id: String) -> String {
    "\(owner.utf8.count):\(owner)\(namespace.utf8.count):\(namespace)\(id)"
  }
}

/// A bounded startup view, never inserted into the complete-document cache.
struct ArchiveBootstrap: Sendable {
  let document: LiveDocument
  let firstPage: LibraryPage
}

struct ArchiveReadModel: Sendable {
  let document: LiveDocument
  let visibleMedia: [MediaItem]
  let revision: Int
  let libraryRevision: Int
  let searchRevision: Int
}

enum ArchiveMutationImpact: Sendable { case metadata, organization, library }
