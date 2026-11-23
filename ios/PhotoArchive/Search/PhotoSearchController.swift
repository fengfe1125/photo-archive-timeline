import Foundation
import Observation
@preconcurrency import Photos
import Vision
import CoreML
import UIKit
import CoreLocation
import Supabase

struct SearchUsage: Codable, Identifiable, Sendable {
  var id: String
  var search_id: String
  var model: String
  var provider: String
  var status: String
  var created_at: String
  var input_tokens: Int?
  var output_tokens: Int?
  var cached_tokens: Int?
  var reasoning_tokens: Int?
  var cost: Double?
  var currency: String
  var estimated: Bool
  var elapsed_ms: Int?
  var provider_request_id: String?
  var price_version: String?
  var fx_rate: Double?
  var fx_date: String?
  var billing_mode: String?
}
private struct SearchCloudBody: Encodable {
  var requestId: String
  var searchId: String
  var query: PhotoSearchQuery?
  var text: String?
  var image: String?
  var description: String?
  var labels: [String]?
}
private struct SearchCloudReply: Decodable {
  var query: PhotoSearchQuery?
  var description: String?
  var labels: [String]?
  var probability: Double?
  var model: String?
}
private struct CloudModels: Decodable { var vision: String; var judge: String; var version: String }
private struct UsageReply: Decodable { var records: [SearchUsage]; var offset: Int?; var models: CloudModels? }

/// Pending writes belong to an owner, not the currently visible search session.
/// A returning owner must read only after all of its queued snapshots have committed.
@MainActor final class SearchPreferenceWrites {
  private struct Entry { let id: UUID; let task: Task<Void, Error> }
  private var pending: [String: Entry] = [:]
  func enqueue(owner: String, operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
    let previous = pending[owner]?.task
    let task = Task {
      _ = try? await previous?.value
      try await operation()
    }
    pending[owner] = Entry(id: UUID(), task: task)
    return task
  }
  func read(owner: String, repository: SearchRepository) async throws -> SearchPreferences {
    while true {
      let entry = pending[owner]
      // Failed writes have already been reported by their caller. Reading the last
      // committed state must remain possible after a disk error or cancelled save.
      _ = try? await entry?.task.value
      try Task.checkCancellation()
      let preferences = try await repository.read(SearchPreferences.self, id: "preferences") ?? SearchPreferences()
      try Task.checkCancellation()
      // Another edit can arrive while waiting or reading. Do not publish its predecessor.
      if pending[owner]?.id == entry?.id { return preferences }
    }
  }
}

@MainActor @Observable final class PhotoSearchController {
  var query = PhotoSearchQuery()
  var history: [PhotoSearchQuery] = []
  var preferences = SearchPreferences()
  var analyses: [String: SearchAnalysis] = [:]
  var matches: [MediaItem] = []
  var possible: [MediaItem] = []
  private(set) var effectiveDays: [String: ArchiveDay] = [:]
  private(set) var matchCount = 0
  private(set) var possibleCount = 0
  private(set) var pendingCount = 0
  private(set) var waitingCount = 0
  let scheduler = LibraryWorkScheduler()
  @ObservationIgnored private var allMatches: [MediaItem] = []
  @ObservationIgnored private var allPossible: [MediaItem] = []
  @ObservationIgnored private var resultTask: Task<Void, Never>?
  @ObservationIgnored private var resultGeneration = UUID()
  @ObservationIgnored private var attachGeneration = UUID()
  @ObservationIgnored private var identityGeneration = UUID()
  @ObservationIgnored private var attachedRevision: Int?
  @ObservationIgnored private let preferenceWrites: SearchPreferenceWrites
  @ObservationIgnored private var analysisMutationRevision = 0
  @ObservationIgnored private var automaticWork = false
  @ObservationIgnored private var automaticCandidates: [MediaItem] = []
  @ObservationIgnored private var automaticCursor = 0
  @ObservationIgnored private var screenshots: Set<String> = []
  @ObservationIgnored private weak var attachedStore: ArchiveStore?

  var usage: [SearchUsage] = []
  var message: String?
  var loading = false
  var busy = false
  var progress = ""
  var processedCount = 0
  var processingTotal = 0
  var selectedAlbumID: String?
  var searchID = UUID().uuidString.lowercased()
  var draftCloudQuery: PhotoSearchQuery?
  private var modelVersion = "MiniMax-M3|typesafe/jev-1.13|1"
  private(set) var owner = ""
  @ObservationIgnored private var repository: SearchRepository?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let geocoder = CLGeocoder()
  @ObservationIgnored private var geoCache: [String: String] = [:]
  @ObservationIgnored private var geoLastRequest = Date.distantPast
  @ObservationIgnored private var assets: [String: PHAsset] = [:]

  init(preferenceWrites: SearchPreferenceWrites = SearchPreferenceWrites()) {
    self.preferenceWrites = preferenceWrites
    scheduler.configure(work: { [weak self] in
      guard let self, let store = self.attachedStore, !self.busy, !self.loading, store.archiveReady, !store.isDemo,
        self.pendingCount > 0 else { return false }
      self.index(store, maximumItems: 1, automatic: true)
      guard self.busy && self.automaticWork else { return false }
      await self.task?.value
      return !Task.isCancelled && self.processedCount > 0 && self.pendingCount > 0 && !self.busy
    }, cancel: { [weak self] in self?.cancelAutomaticWork() })
  }
  func setForeground(_ foreground: Bool, store: ArchiveStore) {
    attachedStore = store
    scheduler.update { $0.foreground = foreground }
    if !foreground { cancelWork(showMessage: false) }
  }
  func userDidInteract() { scheduler.userDidInteract() }
  func setScrolling(_ scrolling: Bool) { scheduler.update { $0.scrolling = scrolling } }
  func setDetailPresented(_ presented: Bool) { scheduler.update { $0.detailPresented = presented } }
  func setAnalysisPaused(_ paused: Bool) {
    preferences.localAnalysisPaused = paused
    scheduler.update { $0.paused = paused }
    if paused { cancelWork(showMessage: true) }
    persistPreferences()
  }
  private func cancelAutomaticWork() { if automaticWork { cancelWork(showMessage: false) } }
  @discardableResult func prepareIdentity(_ identity: String) -> Bool {
    guard owner != identity || repository == nil else { return false }
    cancelWork(showMessage: false); scheduler.invalidate(); owner = identity
    resultGeneration = UUID(); resultTask?.cancel()
    query = PhotoSearchQuery(); history = []; analyses = [:]; assets = [:]; screenshots = []
    matches = []; possible = []; allMatches = []; allPossible = []; effectiveDays = [:]; matchCount = 0; possibleCount = 0
    pendingCount = 0; waitingCount = 0; usage = []; selectedAlbumID = nil; draftCloudQuery = nil
    preferences = SearchPreferences(); geoCache = [:]; repository = nil; attachedRevision = nil
    searchID = UUID().uuidString.lowercased()
    analysisMutationRevision &+= 1
    identityGeneration = UUID(); attachGeneration = UUID(); automaticCandidates = []; automaticCursor = 0
    modelVersion = ""; message = nil; loading = true
    return true
  }
  func attach(_ store: ArchiveStore) async {
    attachedStore = store
    let identity = store.isDemo ? "demo" : store.live?.account.userID ?? "guest"
    let identityChanged = owner != identity || repository == nil
    let revision = store.searchRevision
    guard identityChanged || attachedRevision != revision else { return }
    if identityChanged { prepareIdentity(identity) }
    guard store.archiveReady else { loading = true; scheduler.invalidate(); return }
    // Only a real media/correction revision invalidates in-flight evidence; sync progress does not.
    if !identityChanged { cancelWork(showMessage: false) }
    let token = UUID(); attachGeneration = token
    let items = store.media, corrections = store.snapshot.corrections, cached = analyses
    let namespace = ProcessInfo.processInfo.arguments.contains("-ui-testing") ? "SearchUITests" : "Search"
    let base = URL.applicationSupportDirectory.appendingPathComponent("PhotoArchive/" + namespace)
    let existingRepository = repository, preferenceWrites = preferenceWrites
    loading = true
    let preparation = Task.detached(priority: .utility) {
      let repository = existingRepository ?? SearchRepository(base: base, owner: identity)
      try await repository.prepare()
      let preferences = try await preferenceWrites.read(owner: identity, repository: repository)
      let geo = try await repository.read([String: String].self, id: "geo") ?? [:]
      let photos = items.filter { $0.kind == .photo }
      let persisted = try await repository.readAnalyses(ids: photos.map(\.id))
      let fetched = PHAsset.fetchAssets(withLocalIdentifiers: photos.compactMap(\.localIdentifier), options: nil)
      var byIdentifier: [String: PHAsset] = [:]
      fetched.enumerateObjects { asset, _, _ in byIdentifier[asset.localIdentifier] = asset }
      var assets: [String: PHAsset] = [:], analyses: [String: SearchAnalysis] = [:]
      var screenshots = Set<String>()
      for item in photos {
        try Task.checkCancellation()
        let asset = item.localIdentifier.flatMap { byIdentifier[$0] }
        if let asset { assets[item.id] = asset }
        if asset?.mediaSubtypes.contains(.photoScreenshot) == true { screenshots.insert(item.id) }
        let correction = corrections[item.id]
        let day = correction?.effectiveDayMode == .clear ? nil : correction?.effectiveDayMode == .value ? correction?.day : item.originalDay
        let place = correction?.effectivePlaceMode == .clear ? nil : correction?.effectivePlaceMode == .value ? correction?.place : item.originalPlace
        let text = "v1|\(item.localIdentifier ?? item.id)|\((asset?.modificationDate ?? item.modificationDate)?.timeIntervalSince1970 ?? 0)|\(item.captureDate?.timeIntervalSince1970 ?? 0)|\(String(describing: day))|\(String(describing: place))"
        let version = SearchDigest.of(Data(text.utf8))
        let old = persisted[item.id] ?? cached[item.id]
        analyses[item.id] = old?.version == version ? old : SearchAnalysis(version: version)
      }
      let pending = analyses.values.filter { $0.state == "pending" }.count
      let waiting = analyses.values.filter { $0.state == "waiting" }.count
      let automatic = photos.filter { $0.accessible && analyses[$0.id]?.state == "pending" }
      return (repository, preferences, geo, assets, analyses, screenshots, pending, waiting, automatic)
    }
    do {
      let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
      guard !Task.isCancelled, owner == identity, attachGeneration == token else { return }
      repository = result.0
      if identityChanged { preferences = result.1; modelVersion = preferences.modelVersion ?? ""; geoCache = result.2 }
      assets = result.3; screenshots = result.5
      analyses = result.4; analysisMutationRevision &+= 1; pendingCount = result.6; waitingCount = result.7
      automaticCandidates = result.8; automaticCursor = 0
      attachedRevision = revision; loading = false; refresh(store)
      scheduler.update { $0.paused = preferences.localAnalysisPaused == true }
      scheduler.requestWork()
      if identityChanged {
        let migration = Task.detached(priority: .background) { try await SearchRepository.migrateExistingOwners(base: base) }
        Task { [weak self] in
          do { try await migration.value }
          catch { if self?.owner == identity { self?.message = "部分旧账号搜索资料迁移未完成，原文件已保留：\(error.localizedDescription)" } }
        }
      }
    } catch {
      guard !Task.isCancelled, owner == identity, attachGeneration == token else { return }
      loading = false; message = "搜索索引读取失败，原文件已保留：\(error.localizedDescription)"
    }
  }
  private func version(_ item: MediaItem, _ store: ArchiveStore) -> String {
    let asset = assets[item.id]
    let text = "v1|\(item.localIdentifier ?? item.id)|\((asset?.modificationDate ?? item.modificationDate)?.timeIntervalSince1970 ?? 0)|\(item.captureDate?.timeIntervalSince1970 ?? 0)|\(String(describing: store.day(item)))|\(String(describing: store.place(item)))"
    return SearchDigest.of(Data(text.utf8))
  }
  private func savePreferences() -> Task<Void, Error> {
    let repository = repository, value = preferences
    return preferenceWrites.enqueue(owner: owner) {
      guard let repository else { throw ArchiveError.invalidData }
      try await repository.write(value, id: "preferences")
    }
  }
  func persistPreferences() {
    let identity = owner, task = savePreferences()
    Task {
      do { try await task.value }
      catch { if owner == identity { message = "设置未保存：\(error.localizedDescription)" } }
    }
  }
  func update(_ next: PhotoSearchQuery, store: ArchiveStore) {
    do { try next.validate(); cancelWork(showMessage: false); userDidInteract(); history.append(query); query = next; draftCloudQuery = nil; refresh(store) }
    catch { message = error.localizedDescription }
  }
  func submit(_ text: String, store: ArchiveStore) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if text.contains("撤回") { undo(store); return }
    update(LocalSearchParser.parse(String(text.prefix(2000)), current: query), store: store)
  }
  func undo(_ store: ArchiveStore) { guard let previous = history.popLast() else { return }; cancelWork(showMessage: false); userDidInteract(); query = previous; refresh(store) }
  func reset(_ store: ArchiveStore) { cancelWork(showMessage: false); userDidInteract(); history = []; query = PhotoSearchQuery(); selectedAlbumID = nil; draftCloudQuery = nil; searchID = UUID().uuidString.lowercased(); refresh(store) }
  func refresh(_ store: ArchiveStore) {
    resultTask?.cancel(); let token = UUID(); resultGeneration = token
    guard query.hasConditions else { matches = []; possible = []; allMatches = []; allPossible = []; effectiveDays = [:]; matchCount = 0; possibleCount = 0; return }
    let query = query, items = store.media, corrections = store.snapshot.corrections, analyses = analyses, screenshots = screenshots
    let excluded = preferences.albums.first { $0.id == selectedAlbumID }?.excluded ?? []
    let identity = owner
    resultTask = Task {
      let matching = Task.detached(priority: .userInitiated) {
        try SearchResultMatcher.results(query: query, items: items, corrections: corrections, analyses: analyses, screenshots: screenshots, excluded: excluded)
      }
      do {
        let results = try await withTaskCancellationHandler { try await matching.value } onCancel: { matching.cancel() }
        guard !Task.isCancelled, resultGeneration == token, owner == identity else { return }
        allMatches = results.matches; allPossible = results.possible; effectiveDays = results.effectiveDays
        matchCount = results.matches.count; possibleCount = results.possible.count
        matches = Array(allMatches.prefix(max(120, matches.count))); possible = Array(allPossible.prefix(max(120, possible.count)))
      } catch { /* Cancelled searches must not replace the newest result. */ }
    }
  }
  func resultIDs(possible uncertain: Bool) -> [String] { (uncertain ? allPossible : allMatches).map(\.id) }
  func waitForResults() async { await resultTask?.value }
  func loadMore(possible uncertain: Bool) {
    if uncertain { possible = Array(allPossible.prefix(possible.count + 120)) }
    else { matches = Array(allMatches.prefix(matches.count + 120)) }
  }
  func saveAlbum(name: String) {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !query.needsYear else { message = "请填写名称并确认年份"; return }
    if let index = preferences.albums.firstIndex(where: { $0.id == selectedAlbumID }) { preferences.albums[index].name = String(name.prefix(100)); preferences.albums[index].query = query }
    else { let album = SearchAlbum(name: String(name.prefix(100)), query: query); preferences.albums.append(album); selectedAlbumID = album.id }
    persistPreferences()
  }
  func openAlbum(_ album: SearchAlbum, store: ArchiveStore) { reset(store); selectedAlbumID = album.id; query = album.query; refresh(store) }
  func exclude(_ id: String, store: ArchiveStore) { exclude([id], store: store) }
  func exclude(_ ids: Set<String>, store: ArchiveStore) {
    guard let index = preferences.albums.firstIndex(where: { $0.id == selectedAlbumID }) else { return }
    preferences.albums[index].excluded.formUnion(ids); persistPreferences(); refresh(store)
  }
  func deleteAlbum(_ id: String) {
    preferences.albums.removeAll { $0.id == id }
    if selectedAlbumID == id { selectedAlbumID = nil }
    persistPreferences()
  }
  func cancelCurrentWork() { cancelWork(showMessage: false) }
  func stop() { setAnalysisPaused(true) }
  private func cancelWork(showMessage: Bool) {
    if busy && showMessage { message = "处理已暂停，已完成的结果已保留。可点击继续。" }
    generation = UUID(); task?.cancel(); task = nil; busy = false; automaticWork = false; geocoder.cancelGeocode()
  }
  private func check(_ token: UUID, _ store: ArchiveStore, item: MediaItem? = nil) throws {
    try Task.checkCancellation()
    guard generation == token, owner == (store.isDemo ? "demo" : store.live?.account.userID ?? "guest") else { throw CancellationError() }
    if let item {
      guard store.item(item.id)?.accessible == true, assets[item.id]?.localIdentifier != nil,
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
        PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier ?? ""], options: nil).firstObject != nil else { throw CancellationError() }
    }
  }
  private func save(_ a: SearchAnalysis, for item: MediaItem) async throws {
    guard let repository else { throw ArchiveError.invalidData }
    let identity = owner, token = generation
    guard analyses[item.id]?.version == a.version else { throw CancellationError() }
    let saved = try await repository.saveAnalysis(a, id: item.id)
    guard owner == identity, generation == token, analyses[item.id]?.version == a.version else { throw CancellationError() }
    let oldState = analyses[item.id]?.state
    analyses[item.id] = saved; analysisMutationRevision &+= 1
    if oldState == "pending" { pendingCount -= 1 }; if oldState == "waiting" { waitingCount -= 1 }
    if a.state == "pending" { pendingCount += 1 }; if a.state == "waiting" { waitingCount += 1 }
  }
  private func jpeg(_ item: MediaItem, network: Bool) async throws -> Data {
    guard let asset = assets[item.id] else { throw ArchiveServiceError(message: "照片暂时不可访问") }
    let request = SearchImageRequest()
    let image = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        request.start(asset: asset, network: network, continuation: continuation)
      }
    } onCancel: { Task { @MainActor in request.finish(.failure(CancellationError())) } }
    let box = SearchImageBox(image: image)
    let encoding = Task.detached(priority: .utility) { try box.jpeg() }
    return try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
  }
  func index(_ store: ArchiveStore, download: Bool = false, maximumItems: Int = .max, automatic: Bool = false) {
    guard !busy, !loading, repository != nil, !store.isDemo else { message = "请在真实照片库中进行本地分析"; return }
    if !automatic { setAnalysisPaused(false); scheduler.invalidate() }
    let candidates: [MediaItem]
    if automatic {
      // A forward cursor avoids rescanning an already analysed library once per image.
      while automaticCursor < automaticCandidates.count && analyses[automaticCandidates[automaticCursor].id]?.state != "pending" { automaticCursor += 1 }
      candidates = automaticCursor < automaticCandidates.count ? [automaticCandidates[automaticCursor]] : []
    } else {
      candidates = Array(store.media.lazy.filter { item in
        item.kind == .photo && item.accessible && self.analyses[item.id]?.needsLocalVision != false
      }.prefix(download ? min(maximumItems, 50) : maximumItems))
    }
    guard !candidates.isEmpty else {
      if !automatic { message = "本地分析已完成，没有需要处理的新照片。试试搜索海边、聚餐或夜景。" }
      return
    }
    processedCount = 0; processingTotal = candidates.count
    automaticWork = automatic
    busy = true; if !automatic { message = nil }; progress = "准备分析 \(candidates.count) 张照片"; let token = generation
    let started = Date()
    recordLocalDiagnostic(status: "running", candidates: Array(candidates), started: started)
    task = Task {
      defer {
        if generation == token { busy = false; automaticWork = false; refresh(store); if !automatic { scheduler.requestWork() } }
        recordLocalDiagnostic(status: generation == token ? "finished" : "interrupted", candidates: Array(candidates), started: started)
      }
      var completed = 0, waiting = 0
      var lastFailure: String?
      for (offset, item) in candidates.enumerated() {
        progress = "本地分析 \(offset + 1)/\(candidates.count) · 已完成 \(completed) 张"
        await Task.yield()
        do {
          try check(token, store, item: item)
          var a = analyses[item.id] ?? SearchAnalysis(version: version(item, store))
          if a.state != "ready" {
            do {
              progress = "读取图片 \(offset + 1)/\(candidates.count)"
              let bytes = try await jpeg(item, network: download); try check(token, store, item: item)
              progress = "识别画面 \(offset + 1)/\(candidates.count)"
              let classification = Task.detached(priority: .utility) { try await SearchVisionWorker.shared.classify(bytes) }
              let labels = try await withTaskCancellationHandler { try await classification.value } onCancel: { classification.cancel() }
              try check(token, store, item: item); if a.labels != labels { a.decisions = [:] }; a.labels = labels; a.state = "ready"; a.failureReason = nil
            } catch is CancellationError { throw CancellationError() }
            catch { a.state = "waiting"; a.failureReason = error.localizedDescription; lastFailure = error.localizedDescription }
          }
          try check(token, store, item: item); try await save(a, for: item)
          if a.state == "ready" { completed += 1 } else { waiting += 1 }
          processedCount = offset + 1
          if (offset + 1).isMultiple(of: 10) { refresh(store) }
        } catch is CancellationError { break }
        catch { message = error.localizedDescription; return }
      }
      if generation == token && !automatic {
        message = "本地分析完成：\(completed) 张已就绪，\(waiting) 张待下载或重试。" + (lastFailure.map { "最近一次原因：" + $0 } ?? "")
      }
    }
  }
  private func recordLocalDiagnostic(status: String, candidates: [MediaItem], started: Date) {
    #if DEBUG
    guard ProcessInfo.processInfo.arguments.contains("-verify-local-search") else { return }
    UIApplication.shared.isIdleTimerDisabled = status == "running"
    let elapsed = Date().timeIntervalSince(started), processed = processedCount, total = processingTotal, evidence = analyses
    Task.detached(priority: .utility) {
      struct Item: Encodable { let state: String; let labelCount: Int; let failure: String }
      struct Report: Encodable { let status: String; let elapsedSeconds: Double; let processed: Int; let total: Int; let items: [Item] }
      let report = Report(status: status, elapsedSeconds: elapsed, processed: processed, total: total,
        items: candidates.map { item in
          let analysis = evidence[item.id]
          return Item(state: analysis?.state ?? "missing", labelCount: analysis?.labels.count ?? 0, failure: analysis?.failureReason ?? "")
        })
      if let data = try? JSONEncoder.sorted.encode(report) {
        try? data.write(to: URL.cachesDirectory.appendingPathComponent("search-local-diagnostic.json"), options: .atomic)
      }
    }
    #endif
  }
  func locate(_ store: ArchiveStore) {
    guard !busy, !loading, preferences.geo, repository != nil else { message = "请先在搜索设置中允许联网查询城市。"; return }
    let candidates = store.media.filter { item in
      item.kind == .photo && analyses[item.id]?.city.isEmpty != false && store.place(item)?.latitude != nil && store.place(item)?.longitude != nil
    }
    guard !candidates.isEmpty else { message = "没有需要查询城市的新照片。"; return }
    processedCount = 0; processingTotal = candidates.count
    busy = true; message = nil; progress = "准备查询城市"; let token = generation
    task = Task { [self] in
      defer { if generation == token { busy = false; refresh(store) } }
      var resolved = 0
      for (offset, item) in candidates.enumerated() {
        do {
          try check(token, store, item: item)
          guard let lat = store.place(item)?.latitude, let lon = store.place(item)?.longitude else { continue }
          progress = "查询城市 \(offset + 1)/\(candidates.count) · 不影响已完成的场景识别"
          let key = "\(lat),\(lon)"
          var a = analyses[item.id] ?? SearchAnalysis(version: version(item, store))
          if let cached = geoCache[key] { a.city = cached }
          else {
            let delay = max(0, 1.2 - Date().timeIntervalSince(geoLastRequest))
            try await Task.sleep(for: .seconds(delay)); try check(token, store, item: item)
            geoLastRequest = .now
            let timeout = Task { [weak self] in
              do { try await Task.sleep(for: .seconds(10)) } catch { return }
              if self?.generation == token { self?.geocoder.cancelGeocode() }
            }
            do {
              let places = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon), preferredLocale: Locale(identifier: "zh_CN"))
              timeout.cancel(); try check(token, store, item: item)
              a.city = places.first?.locality ?? places.first?.administrativeArea ?? ""
              if !a.city.isEmpty { geoCache[key] = a.city; try await repository?.write(geoCache, id: "geo") }
            } catch {
              timeout.cancel(); try check(token, store, item: item)
              message = "城市查询已暂停：服务暂时不可用或超时。已查询的 \(resolved) 张已保存，场景搜索仍可使用。"
              return
            }
          }
          try check(token, store, item: item)
          try await save(a, for: item); if !a.city.isEmpty { resolved += 1 }; processedCount = offset + 1
          if (offset + 1).isMultiple(of: 10) { refresh(store) }
        } catch { if generation == token { message = "城市查询已停止：\(error.localizedDescription)" }; return }
      }
      if generation == token { message = "城市查询完成：\(resolved) 张获得城市信息。" }
    }
  }
  private func call(_ endpoint: String, query: PhotoSearchQuery? = nil, text: String? = nil, image: String? = nil, description: String? = nil, labels: [String]? = nil, key: String, store: ArchiveStore) async throws -> SearchCloudReply {
    guard preferences.ai, let client = store.live?.account.client, store.live?.account.userID != nil else { throw ArchiveServiceError(message: "请登录并开启云端 AI") }
    let requestID = preferences.pending[key] ?? UUID().uuidString.lowercased()
    preferences.pending[key] = requestID
    let token = generation, identity = owner, requestedModelVersion = modelVersion
    try await savePreferences().value // Must persist before a potentially billable request.
    guard generation == token, owner == identity, modelVersion == requestedModelVersion, !Task.isCancelled else { throw CancellationError() }
    let body = SearchCloudBody(requestId: requestID, searchId: searchID, query: query, text: text, image: image, description: description, labels: labels)
    let session = try await client.auth.session
    guard session.user.id.uuidString.lowercased() == owner, generation == token, owner == identity, modelVersion == requestedModelVersion, preferences.ai, !Task.isCancelled else { throw CancellationError() }
    let result: SearchCloudReply = try await client.functions.invoke(endpoint, options: .init(headers: ["Authorization": "Bearer " + session.accessToken], body: body))
    guard generation == token, owner == identity, modelVersion == requestedModelVersion, preferences.ai, !Task.isCancelled else { throw CancellationError() }
    return result
  }
  func supplement(_ store: ArchiveStore, download: Bool = false) {
    guard !busy, preferences.ai, store.live?.account.userID != nil else { message = "请先登录并开启云端 AI"; return }
    guard !query.needsYear else { message = "请先选择春节年份"; return }
    processingTotal = 0; processedCount = 0
    busy = true; let token = generation; let original = query
    task = Task {
      defer { if generation == token { busy = false; refresh(store) } }
      do {
        await loadUsage(store); try check(token, store)
        guard !modelVersion.isEmpty else { throw ArchiveServiceError(message: "暂时无法确认云端模型版本，请稍后重试") }
        if !original.unresolved.isEmpty {
          progress = "正在理解搜索条件"
          let result = try await call("parse-query", query: original, text: original.unresolved, key: "parse:" + original.key, store: store)
          try check(token, store)
          guard let next = result.query else { throw ArchiveError.invalidData }; try next.validate()
          draftCloudQuery = next; message = "请确认解析后的条件，再点击云端补充。"
          await loadUsage(store); return
        }
        let semantic = !original.include.filter({ $0 != "截图" }).isEmpty || !original.exclude.filter({ $0 != "截图" }).isEmpty
        guard semantic else { message = "当前条件可在本地筛选，无需调用模型。"; return }
        await waitForResults(); try check(token, store)
        let candidates = (allMatches + allPossible).filter { analyses[$0.id]?.decisions[original.key] == nil }.prefix(50)
        for (offset, item) in candidates.enumerated() {
          try check(token, store, item: item)
          var a = analyses[item.id] ?? SearchAnalysis(version: version(item, store))
          progress = "云端补充 \(offset + 1)/\(candidates.count)"
          if a.cloudModelVersion != modelVersion { a.description = ""; a.decisions = [:]; a.visualModel = ""; a.cloudModelVersion = modelVersion }
          if a.description.isEmpty {
            let bytes: Data
            do { bytes = try await jpeg(item, network: download) }
            catch is CancellationError { throw CancellationError() }
            catch { a.state = "waiting"; try await save(a, for: item); continue }
            try check(token, store, item: item)
            let result = try await call("analyze-photo", image: bytes.base64EncodedString(), key: "vision:\(modelVersion):\(item.id):\(a.version)", store: store)
            try check(token, store, item: item)
            guard let description = result.description, !description.isEmpty else { throw ArchiveError.invalidData }
            a.description = description; a.visualModel = result.model ?? "MiniMax-M3"; try await save(a, for: item)
          }
          let evidenceKey = SearchDigest.of((try? JSONEncoder.sorted.encode([a.description] + a.labels.sorted())) ?? Data())
          let result = try await call("judge-candidates", query: original, description: a.description, labels: a.labels, key: "judge:\(modelVersion):\(item.id):\(a.version):\(original.key):\(evidenceKey)", store: store)
          try check(token, store, item: item)
          guard let p = result.probability, p.isFinite, (0...1).contains(p) else { throw ArchiveError.invalidData }
          a.decisions[original.key] = p; try await save(a, for: item); refresh(store)
        }
        message = "本批处理完成；未分析的照片仍保留在候选中。"
      } catch is CancellationError { }
      catch { if generation == token { message = "云端补充暂停：\(error.localizedDescription)。已得到的结果保留，费用可在用量页核对。" } }
      if generation == token { await loadUsage(store) }
    }
  }
  func loadUsage(_ store: ArchiveStore) async {
    guard let client = store.live?.account.client, let account = store.live?.account.userID else { return }
    let token = generation, identityToken = identityGeneration
    do {
      var records: [SearchUsage] = []; var offset = 0
      while true {
        let result: UsageReply = try await client.functions.invoke("usage-summary", options: .init(body: ["offset": offset]))
        guard account == store.live?.account.userID, owner == account, identityGeneration == identityToken, generation == token, !Task.isCancelled else { return }
        if let models = result.models {
          let next = "\(models.vision)|\(models.judge)|\(models.version)"
          if modelVersion != next {
            guard let repository else { throw ArchiveError.invalidData }
            let transition = preferenceWrites.enqueue(owner: account) {
              try await repository.transitionCloudModel(to: next)
            }
            try await transition.value
            guard owner == account, identityGeneration == identityToken else { return }
            modelVersion = next; preferences.modelVersion = next
            // A local analysis may finish during the database transaction. Rebuild from a
            // stable in-memory snapshot, preserving any labels/city saved in that interval.
            while owner == account && identityGeneration == identityToken {
              let revision = analysisMutationRevision, current = analyses
              let cleared = await Task.detached(priority: .utility) {
                current.mapValues { value in
                  var value = value
                  if value.cloudModelVersion != next {
                    value.description = ""; value.decisions = [:]; value.visualModel = ""; value.cloudModelVersion = next
                  }
                  return value
                }
              }.value
              guard owner == account, identityGeneration == identityToken else { return }
              if revision == analysisMutationRevision { analyses = cleared; analysisMutationRevision &+= 1; refresh(store); break }
            }
          }
        }
        records += result.records
        guard let next = result.offset else { break }; offset = next
      }
      guard owner == account, identityGeneration == identityToken, generation == token, !Task.isCancelled else { return }
      usage = records
    } catch { if owner == account && identityGeneration == identityToken && generation == token { message = "费用暂时无法刷新，未确认的调用请稍后核对。" } }
  }
}


/// One terminal result for PhotoKit success, error, cancellation, or timeout.
@MainActor private final class SearchImageRequest {
  private var continuation: CheckedContinuation<UIImage, Error>?
  private var requestID: PHImageRequestID = PHInvalidImageRequestID
  private var timeout: Task<Void, Never>?
  func start(asset: PHAsset, network: Bool, continuation: CheckedContinuation<UIImage, Error>) {
    self.continuation = continuation
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat; options.resizeMode = .fast; options.isNetworkAccessAllowed = network
    requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024), contentMode: .aspectFit, options: options) { [weak self] image, info in
      let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
      let cancelled = info?[PHImageCancelledKey] as? Bool == true
      let photoError = info?[PHImageErrorKey] as? NSError
      let reason = photoError.map { error in
        error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.networkAccessRequired.rawValue
          ? "这张照片需要从 iCloud 下载。点击下载待分析照片后继续，最多50张一批。"
          : error.localizedDescription
      }
      Task { @MainActor in
        guard let self else { return }
        if cancelled { self.finish(.failure(CancellationError())) }
        else if let reason { self.finish(.failure(ArchiveServiceError(message: reason))) }
        else if !degraded {
          if let image { self.finish(.success(image)) }
          else { self.finish(.failure(ArchiveServiceError(message: network ? "图片下载失败，请检查网络" : "图片不在本机，请在搜索设置中允许下载后重试"))) }
        }
      }
    }
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      self?.finish(.failure(ArchiveServiceError(message: "读取图片超时，可稍后重试")))
    }
  }
  func finish(_ result: Result<UIImage, Error>) {
    guard let continuation else { return }
    self.continuation = nil; timeout?.cancel(); timeout = nil
    if requestID != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(requestID); requestID = PHInvalidImageRequestID }
    continuation.resume(with: result)
  }
}


/// Serializes even a cancelled Vision request that the system has not yet returned from.
actor SearchVisionWorker {
  static let shared = SearchVisionWorker()
  func classify(_ bytes: Data) throws -> [String] { try SearchVisionClassifier.classify(bytes) }
}

enum SearchVisionClassifier {
  static func classify(_ bytes: Data) throws -> [String] {
    try Task.checkCancellation()
    let request = VNClassifyImageRequest()
    #if targetEnvironment(simulator)
    // Simulator runtimes can advertise an unavailable Espresso GPU/ANE context.
    // Keep the same real Vision classifier and choose a supported CPU per stage.
    for (stage, devices) in try request.supportedComputeStageDevices {
      if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
        request.setComputeDevice(cpu, for: stage)
      }
    }
    #endif
    let supported = Set(try request.supportedIdentifiers())
    try VNImageRequestHandler(data: bytes).perform([request])
    try Task.checkCancellation()
    return (request.results ?? []).filter { $0.confidence >= 0.3 && supported.contains($0.identifier) }.map(\.identifier)
  }
}

/// UIKit image rendering and compression run off the main actor; the immutable image is retained for this operation only.
private final class SearchImageBox: @unchecked Sendable {
  let image: UIImage
  init(image: UIImage) { self.image = image }
  func jpeg() throws -> Data {
    try Task.checkCancellation()
    let scale = min(1, 1024 / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    try Task.checkCancellation()
    guard let bytes = rendered.jpegData(compressionQuality: 0.8) else { throw ArchiveError.invalidData }
    return bytes
  }
}

struct SearchResults: Sendable {
  var matches: [MediaItem]
  var possible: [MediaItem]
  var effectiveDays: [String: ArchiveDay]
}

enum SearchResultMatcher {
  static func results(query: PhotoSearchQuery, items: [MediaItem], corrections: [String: MetadataCorrection], analyses: [String: SearchAnalysis], screenshots: Set<String>, excluded: Set<String>) throws -> SearchResults {
    var matched: [MediaItem] = [], uncertain: [MediaItem] = []
    let queryKey = query.key
    var effectiveDays: [String: ArchiveDay] = [:]
    for item in items where item.kind == .photo && !excluded.contains(item.id) {
      try Task.checkCancellation()
      let analysis = analyses[item.id], correction = corrections[item.id]
      let effectiveDay = correction?.effectiveDayMode == .clear ? nil : correction?.effectiveDayMode == .value ? correction?.day : item.originalDay
      let day = (query.start == nil && query.end == nil) || correction?.effectiveDayMode == .clear ? nil : correction?.effectiveDayMode == .value ? effectiveDay.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } : item.captureDate.map(SearchCalendar.format) ?? effectiveDay.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) }
      let place = correction?.effectivePlaceMode == .clear ? nil : correction?.effectivePlaceMode == .value ? correction?.place : item.originalPlace
      let city = place == nil ? "" : place?.name == "照片位置" ? analysis?.city ?? "" : place?.name ?? ""
      let hour = query.night ? item.captureDate.map { SearchCalendar.calendar.component(.hour, from: $0) } : nil
      switch SearchMatcher.match(query, day: day, place: city, hour: hour, analysis: analysis, screenshot: screenshots.contains(item.id), queryKey: queryKey) {
      case .match: matched.append(item); if let effectiveDay { effectiveDays[item.id] = effectiveDay }
      case .possible: uncertain.append(item); if let effectiveDay { effectiveDays[item.id] = effectiveDay }
      case .excluded: break
      }
    }
    return SearchResults(matches: matched, possible: uncertain, effectiveDays: effectiveDays)
  }
}
