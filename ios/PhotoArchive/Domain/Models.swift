import Foundation

struct ArchiveDay: Codable, Hashable, Comparable, Sendable {
  var year: Int
  var month: Int
  var day: Int
  init(_ year: Int, _ month: Int, _ day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }
  init(_ date: Date) {
    let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
    self.init(c.year!, c.month!, c.day!)
  }
  var date: Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day)) ?? .now
  }
  var label: String { "\(year) 年 \(month) 月 \(day) 日" }
  var isValid: Bool {
    guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
      return false
    }
    let calendar = Calendar(identifier: .gregorian)
    guard let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
      return false
    }
    let components = calendar.dateComponents([.year, .month, .day], from: value)
    return components.year == year && components.month == month && components.day == day
  }
  static func < (a: Self, b: Self) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
  func isAnniversary(of target: Self) -> Bool {
    year < target.year && month == target.month && day == target.day
  }
}

struct Place: Codable, Hashable, Sendable {
  var name: String
  var latitude: Double?
  var longitude: Double?
}

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case photo = "照片"
    case video = "视频"
  }
  let id: String  // Archive identity, never a PhotoKit localIdentifier.
  let assetName: String
  let title: String
  let kind: Kind
  let originalDay: ArchiveDay?
  let originalPlace: Place?
  let source: String
  var localIdentifier: String? = nil
  var accessible: Bool = false
  var captureDate: Date? = nil
}

struct MetadataCorrection: Codable, Equatable, Sendable {
  let mediaID: String
  let originalDay: ArchiveDay?
  let originalPlace: Place?
  var day: ArchiveDay?
  var place: Place?
  var description: String
  var dayMode: OverrideMode? = nil
  var placeMode: OverrideMode? = nil
  var effectiveDayMode: OverrideMode { dayMode ?? (day == nil ? .clear : .value) }
  var effectivePlaceMode: OverrideMode { placeMode ?? (place == nil ? .clear : .value) }
}

struct Story: Codable, Identifiable, Equatable, Sendable {
  var id = UUID().uuidString.lowercased()
  var title: String
  var description = ""
  var mediaIDs: [String]
  var coverID: String?
  var count: Int { mediaIDs.count }
  mutating func normalize() {
    var seen = Set<String>()
    mediaIDs = mediaIDs.filter { seen.insert($0).inserted }
    if !mediaIDs.contains(coverID ?? "") { coverID = mediaIDs.first }
  }
  mutating func remove(_ id: String) {
    mediaIDs.removeAll { $0 == id }
    normalize()
  }
}

struct ArchiveSnapshot: Codable, Equatable, Sendable {
  var version = 1
  var stories: [Story]
  var corrections: [String: MetadataCorrection] = [:]
  func validate(mediaIDs: Set<String>) throws {
    guard version == 1, Set(stories.map(\.id)).count == stories.count else {
      throw ArchiveError.invalidData
    }
    for story in stories {
      guard !story.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        story.title.count <= 500, story.description.count <= 20_000, story.mediaIDs.count <= 5_000,
        Set(story.mediaIDs).count == story.count,
        Set(story.mediaIDs).isSubset(of: mediaIDs),
        story.mediaIDs.isEmpty ? story.coverID == nil : story.mediaIDs.contains(story.coverID ?? "")
      else { throw ArchiveError.invalidData }
    }
    for (id, correction) in corrections {
      guard id == correction.mediaID, mediaIDs.contains(id), correction.description.count <= 20_000,
        correction.effectiveDayMode != .value || correction.day != nil,
        correction.effectivePlaceMode != .value || correction.place != nil,
        correction.day?.isValid != false,
        correction.originalDay?.isValid != false
      else { throw ArchiveError.invalidData }
      for place in [correction.place, correction.originalPlace].compactMap({ $0 }) {
        guard place.name.count <= 1000 else { throw ArchiveError.invalidData }
        if let lat = place.latitude, let lon = place.longitude {
          guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon)
          else { throw ArchiveError.invalidData }
        } else if place.latitude != nil || place.longitude != nil {
          throw ArchiveError.invalidData
        }
      }
    }
  }
}

enum ArchiveError: LocalizedError {
  case invalidData, notConnected
  var errorDescription: String? {
    switch self {
    case .invalidData: "档案格式无法读取。原文件已保留，请重试或确认重置示例数据。"
    case .notConnected: "尚未接入。当前只在本机整理，未连接账号或云端。"
    }
  }
}

protocol PhotoLibraryProviding: Sendable { var media: [MediaItem] { get } }
protocol ArchiveRepository: Sendable {
  func load() async throws -> ArchiveSnapshot
  func save(_ snapshot: ArchiveSnapshot) async throws
  func reset() async throws -> ArchiveSnapshot
}
protocol AccountService: Sendable {
  func signIn(email: String) async throws
  func verify(email: String, token: String) async throws
  func signOut() async throws
  func deleteAccount() async throws
}
extension AccountService {
  func verify(email: String, token: String) async throws { throw ArchiveError.notConnected }
  func signOut() async throws { throw ArchiveError.notConnected }
  func deleteAccount() async throws { throw ArchiveError.notConnected }
}
protocol SyncService: Sendable { func synchronize() async throws }
struct UnconnectedServices: AccountService, SyncService {
  func signIn(email: String) async throws { throw ArchiveError.notConnected }
  func synchronize() async throws { throw ArchiveError.notConnected }
}

struct PhotoMapPoint: Sendable {
  var id: String
  var latitude: Double
  var longitude: Double
}
struct PhotoMapCluster: Identifiable, Sendable {
  var id: String
  var latitude: Double
  var longitude: Double
  var mediaIDs: [String]
  /// Bound map rendering work without dropping any valid photo references.
  static func build(_ points: [PhotoMapPoint], limit: Int = 120) -> [Self] {
    let valid = points.filter { $0.latitude.isFinite && $0.longitude.isFinite && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }
    var step = 0.02
    while true {
      if Task.isCancelled { return [] }
      let bins = Dictionary(grouping: valid) { "\(Int(floor(($0.latitude + 90) / step))):\(Int(floor(($0.longitude + 180) / step)))" }
      if bins.count <= max(1, limit) {
        return bins.keys.sorted().map { key in
          let group = bins[key]!
          return Self(id: key, latitude: group.reduce(0) { $0 + $1.latitude } / Double(group.count), longitude: group.reduce(0) { $0 + $1.longitude } / Double(group.count), mediaIDs: group.map(\.id))
        }
      }
      step *= 2
    }
  }
}
