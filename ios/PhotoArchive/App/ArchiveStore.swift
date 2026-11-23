import Foundation
import Observation

enum DemoSync: String, CaseIterable {
  case signedOut = "演示：未登录"
  case ready = "演示：已登录，未同步"
  case syncing = "演示：同步中"
  case failed = "演示：同步失败"
  case complete = "演示：同步完成（未连接云端）"
}

@MainActor @Observable final class ArchiveStore {
  private let demoMedia: [MediaItem]
  var media: [MediaItem] { live?.visibleMedia ?? demoMedia }
  let live: LiveArchiveController?
  var isDemo: Bool { live == nil }
  private let repository: any ArchiveRepository
  let accountService: any AccountService = UnconnectedServices()
  let syncService: any SyncService = UnconnectedServices()
  private var demoSnapshot = ArchiveSnapshot(stories: [])
  var snapshot: ArchiveSnapshot { live?.document.snapshot ?? demoSnapshot }
  private var demoRevision = 0
  var searchRevision: Int { live?.searchRevision ?? demoRevision }
  var libraryRevision: Int { live?.libraryRevision ?? demoRevision }
  private var demoLoaded = false
  var loaded: Bool { live?.loaded ?? demoLoaded }
  var archiveReady: Bool { live?.archiveReady ?? demoLoaded }
  private(set) var saving = false
  var error: String?
  var demoSync: DemoSync = .signedOut
  init(repository: any ArchiveRepository, library: any PhotoLibraryProviding = SampleLibrary()) {
    self.repository = repository
    demoMedia = library.media
    live = nil
  }
  init(live: LiveArchiveController) {
    self.live = live
    demoMedia = []
    repository = JSONArchiveRepository(directory: URL.applicationSupportDirectory.appendingPathComponent("PhotoArchive/UnusedDemo"))
  }
  func load() async {
    if let live { await live.load(); error = live.error; return }
    do {
      demoSnapshot = try await repository.load()
      demoRevision &+= 1
      demoLoaded = true
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  func libraryPage(query: LibraryQuery, cursor: LibraryCursor? = nil, limit: Int = 120) async throws -> LibraryPage {
    if let live { return try await live.libraryPage(query: query, cursor: cursor, limit: limit) }
    let items = demoMedia, snapshot = demoSnapshot, revision = demoRevision
    return try await Task.detached(priority: .userInitiated) {
      if let cursor, cursor.owner != "demo" || cursor.query != query || cursor.revision != revision { throw ArchiveStorageError.staleCursor }
      func day(_ item: MediaItem) -> ArchiveDay? {
        guard let correction = snapshot.corrections[item.id], correction.effectiveDayMode != .original else { return item.originalDay }
        return correction.effectiveDayMode == .value ? correction.day : nil
      }
      let years = Array(Set(items.compactMap { day($0)?.year })).sorted(by: >)
      let filtered = items.filter { item in
        let date = day(item)
        return (query.kind == nil || query.kind == item.kind)
          && (!query.accessibleOnly || item.accessible)
          && (query.year == nil || query.year == date?.year)
          && (query.month == nil || query.month == date?.month)
          && !query.excludedIDs.contains(item.id)
          && (query.includedIDs == nil || query.includedIDs!.contains(item.id))
          && (query.anniversary == nil || date?.isAnniversary(of: query.anniversary!) == true)
      }.sorted {
        let lhs = day($0)?.librarySortKey ?? 0, rhs = day($1)?.librarySortKey ?? 0
        return lhs == rhs ? $0.id < $1.id : lhs > rhs
      }
      let remaining = filtered.filter { item in
        guard let cursor else { return true }
        let date = day(item)?.librarySortKey ?? 0
        return date < cursor.dayKey || (date == cursor.dayKey && item.id > cursor.mediaID)
      }
      let size = max(1, min(limit, 500)), page = Array(remaining.prefix(max(1, min(limit, 500))))
      let next = remaining.count > size ? page.last.map { LibraryCursor(owner: "demo", revision: revision, query: query, dayKey: day($0)?.librarySortKey ?? 0, mediaID: $0.id) } : nil
      let days = Dictionary(uniqueKeysWithValues: page.compactMap { item in day(item).map { (item.id, $0) } })
      return LibraryPage(items: page, nextCursor: next, totalCount: filtered.count, years: years, effectiveDays: days)
    }.value
  }
  func item(_ id: String) -> MediaItem? { live?.item(id) ?? demoMedia.first { $0.id == id } }
  func day(_ item: MediaItem) -> ArchiveDay? {
    if let correction = snapshot.corrections[item.id], correction.effectiveDayMode != .original { return correction.effectiveDayMode == .clear ? nil : correction.day }
    return item.originalDay
  }
  func place(_ item: MediaItem) -> Place? {
    if let correction = snapshot.corrections[item.id], correction.effectivePlaceMode != .original { return correction.effectivePlaceMode == .clear ? nil : correction.place }
    return item.originalPlace
  }
  func memories(on day: ArchiveDay) -> [MediaItem] {
    media.filter { self.day($0)?.isAnniversary(of: day) == true }
  }
  func saveStory(_ story: Story) async -> Bool {
    guard archiveReady, !saving else { return false }
    saving = true
    defer { saving = false }
    if let live { do { try await live.saveStory(story); error = nil; return true } catch { self.error = error.localizedDescription; return false } }
    var next = snapshot
    var normalized = story
    normalized.normalize()
    if let i = next.stories.firstIndex(where: { $0.id == story.id }) {
      next.stories[i] = normalized
    } else {
      next.stories.append(normalized)
    }
    return await commit(next)
  }
  func saveCorrection(_ correction: MetadataCorrection?, for id: String) async -> Bool {
    guard archiveReady, !saving else { return false }
    saving = true
    defer { saving = false }
    if let live { do { try await live.saveCorrection(correction, id: id); error = nil; return true } catch { self.error = error.localizedDescription; return false } }
    var next = snapshot
    next.corrections[id] = correction
    return await commit(next)
  }
  private func commit(_ next: ArchiveSnapshot) async -> Bool {
    do {
      try await repository.save(next)
      if demoSnapshot.corrections != next.corrections { demoRevision &+= 1 }
      demoSnapshot = next
      error = nil
      return true
    } catch {
      self.error = "保存失败，草稿仍保留。\n\(error.localizedDescription)"
      return false
    }
  }
  func deleteStory(_ id: String) async -> Bool {
    guard archiveReady, !saving else { return false }
    saving = true
    defer { saving = false }
    if let live { do { try await live.deleteStory(id); error = nil; return true } catch { self.error = error.localizedDescription; return false } }
    var next = snapshot; next.stories.removeAll { $0.id == id }; return await commit(next)
  }
  func reset() async {
    guard isDemo else { return }
    guard !saving else { return }
    saving = true
    defer { saving = false }
    do {
      demoSnapshot = try await repository.reset()
      demoRevision &+= 1
      demoLoaded = true
      error = nil
      demoSync = .signedOut
    } catch { self.error = error.localizedDescription }
  }
  func runDemoSync(fail: Bool) async {
    guard demoSync != .syncing else { return }
    demoSync = .syncing
    try? await Task.sleep(for: .milliseconds(650))
    demoSync = fail ? .failed : .complete
  }
}
