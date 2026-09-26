import Foundation
import Observation
@preconcurrency import Photos
import Vision
import UIKit
import CoreLocation
import Supabase

struct SearchUsage: Codable, Identifiable {
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

@MainActor @Observable final class PhotoSearchController {
  var query = PhotoSearchQuery()
  var history: [PhotoSearchQuery] = []
  var preferences = SearchPreferences()
  var analyses: [String: SearchAnalysis] = [:]
  var matches: [MediaItem] = []
  var possible: [MediaItem] = []
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

  func attach(_ store: ArchiveStore) async {
    let identity = store.isDemo ? "demo" : store.live?.account.userID ?? "guest"
    let identityChanged = owner != identity || repository == nil
    if identityChanged {
      stop(); owner = identity; query = PhotoSearchQuery(); history = []; analyses = [:]; assets = [:]
      matches = []; possible = []; usage = []; selectedAlbumID = nil; draftCloudQuery = nil; preferences = SearchPreferences(); geoCache = [:]; repository = nil
      searchID = UUID().uuidString.lowercased()
    }
    let items = store.media.filter { $0.kind == .photo }
    let corrections = store.snapshot.corrections
    let cached = analyses
    let namespace = ProcessInfo.processInfo.arguments.contains("-ui-testing") ? "SearchUITests" : "Search"
    let base = URL.applicationSupportDirectory.appendingPathComponent("PhotoArchive/" + namespace)
    loading = true
    let preparation = Task.detached(priority: .userInitiated) {
      let repository = try SearchRepository(base: base, owner: identity)
      let preferences = try repository.read(SearchPreferences.self, id: "preferences") ?? SearchPreferences()
      let geo = try repository.read([String: String].self, id: "geo") ?? [:]
      let fetched = PHAsset.fetchAssets(withLocalIdentifiers: items.compactMap(\.localIdentifier), options: nil)
      var byIdentifier: [String: PHAsset] = [:]
      fetched.enumerateObjects { asset, _, _ in byIdentifier[asset.localIdentifier] = asset }
      var assets: [String: PHAsset] = [:]
      var analyses: [String: SearchAnalysis] = [:]
      var readFailure = false
      for item in items {
        try Task.checkCancellation()
        let asset = item.localIdentifier.flatMap { byIdentifier[$0] }
        if let asset { assets[item.id] = asset }
        let correction = corrections[item.id]
        let day = correction?.effectiveDayMode == .clear ? nil : correction?.effectiveDayMode == .value ? correction?.day : item.originalDay
        let place = correction?.effectivePlaceMode == .clear ? nil : correction?.effectivePlaceMode == .value ? correction?.place : item.originalPlace
        let text = "v1|\(item.localIdentifier ?? item.id)|\(asset?.modificationDate?.timeIntervalSince1970 ?? 0)|\(item.captureDate?.timeIntervalSince1970 ?? 0)|\(String(describing: day))|\(String(describing: place))"
        let version = SearchDigest.of(Data(text.utf8))
        do {
          let old = try cached[item.id] ?? repository.read(SearchAnalysis.self, id: item.id)
          analyses[item.id] = old?.version == version ? old : SearchAnalysis(version: version)
        } catch { readFailure = true; analyses[item.id] = SearchAnalysis(version: version) }
      }
      return (repository, preferences, geo, assets, analyses, readFailure)
    }
    do {
      let result = try await withTaskCancellationHandler {
        try await preparation.value
      } onCancel: { preparation.cancel() }
      guard !Task.isCancelled, owner == identity else { return }
      repository = result.0
      if identityChanged { preferences = result.1; modelVersion = preferences.modelVersion ?? ""; geoCache = result.2 }
      assets = result.3; analyses = result.4
      if result.5 { message = "部分搜索索引读取失败，可重新分析。" }
      loading = false
      refresh(store)
    } catch {
      guard !Task.isCancelled, owner == identity else { return }
      loading = false; message = "搜索索引读取失败，原文件已保留：\(error.localizedDescription)"
    }
  }
  private func version(_ item: MediaItem, _ store: ArchiveStore) -> String {
    let asset = assets[item.id]
    let text = "v1|\(item.localIdentifier ?? item.id)|\(asset?.modificationDate?.timeIntervalSince1970 ?? 0)|\(item.captureDate?.timeIntervalSince1970 ?? 0)|\(String(describing: store.day(item)))|\(String(describing: store.place(item)))"
    return SearchDigest.of(Data(text.utf8))
  }
  func persistPreferences() {
    do { guard let repository else { throw ArchiveError.invalidData }; try repository.write(preferences, id: "preferences") }
    catch { message = "设置未保存：\(error.localizedDescription)" }
  }
  func update(_ next: PhotoSearchQuery, store: ArchiveStore) {
    do { try next.validate(); stop(); history.append(query); query = next; draftCloudQuery = nil; refresh(store) }
    catch { message = error.localizedDescription }
  }
  func submit(_ text: String, store: ArchiveStore) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if text.contains("撤回") { undo(store); return }
    update(LocalSearchParser.parse(String(text.prefix(2000)), current: query), store: store)
  }
  func undo(_ store: ArchiveStore) { guard let previous = history.popLast() else { return }; stop(); query = previous; refresh(store) }
  func reset(_ store: ArchiveStore) { stop(); history = []; query = PhotoSearchQuery(); selectedAlbumID = nil; draftCloudQuery = nil; searchID = UUID().uuidString.lowercased(); refresh(store) }
  func refresh(_ store: ArchiveStore) {
    guard query.hasConditions else { matches = []; possible = []; return }
    var matched: [MediaItem] = [], uncertain: [MediaItem] = []
    let excluded = preferences.albums.first { $0.id == selectedAlbumID }?.excluded ?? []
    for item in store.media where item.kind == .photo && !excluded.contains(item.id) {
      let a = analyses[item.id]
      let correction = store.snapshot.corrections[item.id]
      let day: String?
      if correction?.effectiveDayMode == .clear { day = nil }
      else if correction?.effectiveDayMode == .value { day = store.day(item).map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } }
      else { day = item.captureDate.map(SearchCalendar.format) ?? store.day(item).map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } }
      let place = store.place(item)
      // Explicitly cleared location must not leak back from an older geocode cache.
      let city = place == nil ? "" : (place?.name == "照片位置" ? a?.city ?? "" : place?.name ?? "")
      let hour = item.captureDate.map { SearchCalendar.calendar.component(.hour, from: $0) }
      switch SearchMatcher.match(query, day: day, place: city, hour: hour, analysis: a, screenshot: assets[item.id]?.mediaSubtypes.contains(.photoScreenshot) == true) {
      case .match: matched.append(item)
      case .possible: uncertain.append(item)
      case .excluded: break
      }
    }
    matches = matched; possible = uncertain
  }
  func saveAlbum(name: String) {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !query.needsYear else { message = "请填写名称并确认年份"; return }
    if let index = preferences.albums.firstIndex(where: { $0.id == selectedAlbumID }) { preferences.albums[index].name = String(name.prefix(100)); preferences.albums[index].query = query }
    else { let album = SearchAlbum(name: String(name.prefix(100)), query: query); preferences.albums.append(album); selectedAlbumID = album.id }
    persistPreferences()
  }
  func openAlbum(_ album: SearchAlbum, store: ArchiveStore) { reset(store); selectedAlbumID = album.id; query = album.query; refresh(store) }
  func exclude(_ id: String, store: ArchiveStore) {
    guard let index = preferences.albums.firstIndex(where: { $0.id == selectedAlbumID }) else { return }
    preferences.albums[index].excluded.insert(id); persistPreferences(); refresh(store)
  }
  func stop() { if busy { message = "处理已暂停，已完成的结果已保留。可点击继续。" }; generation = UUID(); task?.cancel(); task = nil; busy = false; geocoder.cancelGeocode() }
  private func check(_ token: UUID, _ store: ArchiveStore, item: MediaItem? = nil) throws {
    try Task.checkCancellation()
    guard generation == token, owner == (store.isDemo ? "demo" : store.live?.account.userID ?? "guest") else { throw CancellationError() }
    if let item {
      guard store.item(item.id)?.accessible == true, assets[item.id]?.localIdentifier != nil,
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
        PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier ?? ""], options: nil).firstObject != nil else { throw CancellationError() }
    }
  }
  private func save(_ a: SearchAnalysis, for item: MediaItem) throws {
    guard let repository else { throw ArchiveError.invalidData }
    try repository.write(a, id: item.id); analyses[item.id] = a
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
    let scale = min(1, 1024 / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    guard let bytes = rendered.jpegData(compressionQuality: 0.8) else { throw ArchiveError.invalidData }
    return bytes
  }
  func index(_ store: ArchiveStore, download: Bool = false, maximumItems: Int = .max) {
    guard !busy, repository != nil, !store.isDemo else { message = "请在真实照片库中进行本地分析"; return }
    let candidates = store.media.filter { item in
      guard item.kind == .photo, item.accessible else { return false }
      return analyses[item.id]?.needsLocalVision != false
    }.prefix(download ? min(maximumItems, 50) : maximumItems)
    guard !candidates.isEmpty else { message = "本地分析已完成，没有需要处理的新照片。试试搜索海边、聚餐或夜景。"; return }
    processedCount = 0; processingTotal = candidates.count
    busy = true; message = nil; progress = "准备分析 \(candidates.count) 张照片"; let token = generation
    let started = Date()
    recordLocalDiagnostic(status: "running", candidates: Array(candidates), started: started)
    task = Task {
      defer {
        if generation == token { busy = false; refresh(store) }
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
              let labels = try await Task.detached(priority: .utility) {
                try SearchVisionClassifier.classify(bytes)
              }.value
              try check(token, store, item: item); if a.labels != labels { a.decisions = [:] }; a.labels = labels; a.state = "ready"; a.failureReason = nil
            } catch is CancellationError { throw CancellationError() }
            catch { a.state = "waiting"; a.failureReason = error.localizedDescription; lastFailure = error.localizedDescription }
          }
          try check(token, store, item: item); try save(a, for: item)
          if a.state == "ready" { completed += 1 } else { waiting += 1 }
          processedCount = offset + 1
          if (offset + 1).isMultiple(of: 10) { refresh(store) }
        } catch is CancellationError { break }
        catch { message = error.localizedDescription; return }
      }
      if generation == token {
        message = "本地分析完成：\(completed) 张已就绪，\(waiting) 张待下载或重试。" + (lastFailure.map { "最近一次原因：" + $0 } ?? "")
      }
    }
  }
  private func recordLocalDiagnostic(status: String, candidates: [MediaItem], started: Date) {
    #if DEBUG
    guard ProcessInfo.processInfo.arguments.contains("-verify-local-search") else { return }
    UIApplication.shared.isIdleTimerDisabled = status == "running"
    let report: [String: Any] = ["status": status, "elapsedSeconds": Date().timeIntervalSince(started), "processed": processedCount, "total": processingTotal,
      "items": candidates.map { item in
        let a = analyses[item.id]
        return ["state": a?.state ?? "missing", "labelCount": a?.labels.count ?? 0, "failure": a?.failureReason ?? ""] as [String: Any]
      }]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
      try? data.write(to: URL.cachesDirectory.appendingPathComponent("search-local-diagnostic.json"), options: .atomic)
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
    task = Task {
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
              if !a.city.isEmpty { geoCache[key] = a.city; try repository?.write(geoCache, id: "geo") }
            } catch {
              timeout.cancel(); try check(token, store, item: item)
              message = "城市查询已暂停：服务暂时不可用或超时。已查询的 \(resolved) 张已保存，场景搜索仍可使用。"
              return
            }
          }
          try save(a, for: item); if !a.city.isEmpty { resolved += 1 }; processedCount = offset + 1
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
    guard let repository else { throw ArchiveError.invalidData }
    try repository.write(preferences, id: "preferences") // Must persist before a potentially billable request.
    let body = SearchCloudBody(requestId: requestID, searchId: searchID, query: query, text: text, image: image, description: description, labels: labels)
    let session = try await client.auth.session
    guard session.user.id.uuidString.lowercased() == owner, preferences.ai, !Task.isCancelled else { throw CancellationError() }
    let result: SearchCloudReply = try await client.functions.invoke(endpoint, options: .init(headers: ["Authorization": "Bearer " + session.accessToken], body: body))
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
        let candidates = (matches + possible).filter { analyses[$0.id]?.decisions[original.key] == nil }.prefix(50)
        for (offset, item) in candidates.enumerated() {
          try check(token, store, item: item)
          var a = analyses[item.id] ?? SearchAnalysis(version: version(item, store))
          progress = "云端补充 \(offset + 1)/\(candidates.count)"
          if a.description.isEmpty {
            let bytes: Data
            do { bytes = try await jpeg(item, network: download) }
            catch { a.state = "waiting"; try save(a, for: item); continue }
            try check(token, store, item: item)
            let result = try await call("analyze-photo", image: bytes.base64EncodedString(), key: "vision:\(modelVersion):\(item.id):\(a.version)", store: store)
            try check(token, store, item: item)
            guard let description = result.description, !description.isEmpty else { throw ArchiveError.invalidData }
            a.description = description; a.visualModel = result.model ?? "MiniMax-M3"; try save(a, for: item)
          }
          let evidenceKey = SearchDigest.of((try? JSONEncoder.sorted.encode([a.description] + a.labels.sorted())) ?? Data())
          let result = try await call("judge-candidates", query: original, description: a.description, labels: a.labels, key: "judge:\(modelVersion):\(item.id):\(a.version):\(original.key):\(evidenceKey)", store: store)
          try check(token, store, item: item)
          guard let p = result.probability, p.isFinite, (0...1).contains(p) else { throw ArchiveError.invalidData }
          a.decisions[original.key] = p; try save(a, for: item); refresh(store)
        }
        message = "本批处理完成；未分析的照片仍保留在候选中。"
      } catch is CancellationError { }
      catch { if generation == token { message = "云端补充暂停：\(error.localizedDescription)。已得到的结果保留，费用可在用量页核对。" } }
      if generation == token { await loadUsage(store) }
    }
  }
  func loadUsage(_ store: ArchiveStore) async {
    guard let client = store.live?.account.client, let account = store.live?.account.userID else { return }
    do {
      var records: [SearchUsage] = []; var offset = 0
      while true {
        let result: UsageReply = try await client.functions.invoke("usage-summary", options: .init(body: ["offset": offset]))
        guard account == store.live?.account.userID, owner == account else { return }
        if let models = result.models {
          let next = "\(models.vision)|\(models.judge)|\(models.version)"
          if modelVersion != next {
            modelVersion = next; preferences.modelVersion = next; persistPreferences()
            for (id, var a) in analyses { a.description = ""; a.decisions = [:]; a.visualModel = ""; analyses[id] = a; try repository?.write(a, id: id) }
          }
        }
        records += result.records
        guard let next = result.offset else { break }; offset = next
      }
      usage = records
    } catch { message = "费用暂时无法刷新，未确认的调用请稍后核对。" }
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


enum SearchVisionClassifier {
  static func classify(_ bytes: Data) throws -> [String] {
    let request = VNClassifyImageRequest()
    let supported = Set(try request.supportedIdentifiers())
    try VNImageRequestHandler(data: bytes).perform([request])
    return (request.results ?? []).filter { $0.confidence >= 0.3 && supported.contains($0.identifier) }.map(\.identifier)
  }
}
