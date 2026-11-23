import Foundation

/// Shared by the library and every media picker. Nil filters mean all values.
struct LibraryQuery: Hashable, Codable, Sendable {
  var kind: MediaItem.Kind? = nil
  var accessibleOnly = false
  var year: Int? = nil
  var month: Int? = nil
  var excludedIDs: Set<String> = []
  var includedIDs: Set<String>? = nil
  var anniversary: ArchiveDay? = nil
}

struct LibraryCursor: Hashable, Codable, Sendable {
  let owner: String
  let revision: Int
  let query: LibraryQuery
  let dayKey: Int
  let mediaID: String
}

struct LibraryPage: Sendable {
  var items: [MediaItem]
  var nextCursor: LibraryCursor?
  var totalCount: Int
  var years: [Int]
  var effectiveDays: [String: ArchiveDay]
}

enum ArchiveStorageError: LocalizedError {
  case invalidMigration, staleCursor, identityChanged
  var errorDescription: String? {
    switch self {
    case .invalidMigration: "档案升级校验失败，原数据和备份已保留。"
    case .staleCursor: "图库已变化，请重新读取列表。"
    case .identityChanged: "账号已变化，本次操作已停止。"
    }
  }
}

extension ArchiveDay {
  var librarySortKey: Int { year * 10_000 + month * 100 + day }
}

extension LiveDocument {
  func effectiveDay(for item: MediaItem) -> ArchiveDay? {
    guard let correction = snapshot.corrections[item.id], correction.effectiveDayMode != .original else { return item.originalDay }
    return correction.effectiveDayMode == .value ? correction.day : nil
  }
}
