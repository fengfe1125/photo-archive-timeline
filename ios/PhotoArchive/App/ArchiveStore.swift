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
  private var demoLoaded = false
  var loaded: Bool { live?.loaded ?? demoLoaded }
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
    if let live { do { try live.saveStory(story); error = nil; return true } catch { self.error = error.localizedDescription; return false } }
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
    if let live { do { try live.saveCorrection(correction, id: id); error = nil; return true } catch { self.error = error.localizedDescription; return false } }
    var next = snapshot
    next.corrections[id] = correction
    return await commit(next)
  }
  private func commit(_ next: ArchiveSnapshot) async -> Bool {
    guard loaded, !saving else { return false }
    saving = true
    defer { saving = false }
    do {
      try await repository.save(next)
      demoSnapshot = next
      demoRevision &+= 1
      error = nil
      return true
    } catch {
      self.error = "保存失败，草稿仍保留。\n\(error.localizedDescription)"
      return false
    }
  }
  func deleteStory(_ id: String) async -> Bool {
    if let live { do { try live.deleteStory(id); return true } catch { self.error = error.localizedDescription; return false } }
    var next = snapshot; next.stories.removeAll { $0.id == id }; return await commit(next)
  }
  func reset() async {
    guard isDemo else { return }
    guard !saving else { return }
    saving = true
    defer { saving = false }
    do {
      demoSnapshot = try await repository.reset()
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
