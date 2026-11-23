import Foundation
@preconcurrency import Photos
import UIKit
import AVFoundation
import Observation

struct PhotoLibraryDelta: Sendable {
  var upserts: [MediaItem]
  var inaccessibleIDs: Set<String>
  var isFullSnapshot: Bool
}

@MainActor protocol PhotoLibraryAccessProviding {
  var authorization: PHAuthorizationStatus { get }
  func requestAuthorization() async
  func read(previous: [String: MediaItem]) async -> [MediaItem]
}

private struct PhotoScanResult: @unchecked Sendable {
  var delta: PhotoLibraryDelta
}

@MainActor @Observable final class PhotoKitLibrary: NSObject, PhotoLibraryAccessProviding, PHPhotoLibraryChangeObserver {
  private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  private(set) var scanning = false
  private(set) var scanned = 0
  var cacheNamespace = "guest" { didSet { if oldValue != cacheNamespace { MediaPipeline.shared.clear() } } }
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored let manager = MediaPipeline.shared.manager
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
  @ObservationIgnored private var pendingChanged = Set<String>()
  @ObservationIgnored private var pendingRemoved = Set<String>()
  @ObservationIgnored private var needsFullRead = true
  @ObservationIgnored private var changeRevision = 0
  @ObservationIgnored private var scanTask: Task<PhotoScanResult, Error>?
  @ObservationIgnored private var scanID = UUID()
  override init() { super.init() }
  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor [weak self] in self?.accept(changeInstance) }
  }
  private func accept(_ change: PHChange) {
    guard let fetchResult else {
      needsFullRead = true; changeRevision &+= 1; scanTask?.cancel(); onChange?(); return
    }
    guard let details = change.changeDetails(for: fetchResult) else { return }
    self.fetchResult = details.fetchResultAfterChanges
    changeRevision &+= 1
    if details.hasIncrementalChanges {
      let updated = Set(details.insertedObjects.map(\.localIdentifier) + details.changedObjects.map(\.localIdentifier))
      let removed = Set(details.removedObjects.map(\.localIdentifier))
      pendingChanged.subtract(removed); pendingChanged.formUnion(updated)
      pendingRemoved.subtract(updated); pendingRemoved.formUnion(removed)
      MediaPipeline.shared.invalidate(localIdentifiers: updated.union(removed))
    } else { needsFullRead = true; MediaPipeline.shared.reduceMemory() }
    scanTask?.cancel()
    onChange?()
  }
  func requestAuthorization() async {
    let next = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    if authorization != next { needsFullRead = true }
    authorization = next
  }
  /// Compatibility for callers that still expect a complete accessible snapshot.
  func read(previous: [String: MediaItem]) async -> [MediaItem] {
    do {
      let delta = try await readChanges(previous: previous)
      var next = previous
      for id in delta.inaccessibleIDs { next[id]?.accessible = false }
      for item in delta.upserts { next[item.id] = item }
      return next.values.filter(\.accessible)
    } catch { return previous.values.filter(\.accessible) }
  }
  func readChanges(previous: [String: MediaItem]) async throws -> PhotoLibraryDelta {
    let latestAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if authorization != latestAuthorization { needsFullRead = true; MediaPipeline.shared.clear() }
    authorization = latestAuthorization
    scanTask?.cancel()
    let token = UUID(); scanID = token
    guard authorization == .authorized || authorization == .limited else {
      fetchResult = nil; needsFullRead = true; pendingChanged = []; pendingRemoved = []
      scanning = false
      return PhotoLibraryDelta(upserts: [], inaccessibleIDs: Set(previous.values.filter(\.accessible).map(\.id)), isFullSnapshot: true)
    }
    if !observing { PHPhotoLibrary.shared().register(self); observing = true }
    let full = needsFullRead || fetchResult == nil
    if !full && pendingChanged.isEmpty && pendingRemoved.isEmpty {
      return PhotoLibraryDelta(upserts: [], inaccessibleIDs: [], isFullSnapshot: false)
    }
    let baseline = fetchResult
    let changed = pendingChanged, removed = pendingRemoved, revision = changeRevision
    scanning = true; scanned = 0
    let task = Task.detached(priority: .utility) { [weak self] () throws -> PhotoScanResult in
      let fetched: PHFetchResult<PHAsset>
      if full {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        fetched = PHAsset.fetchAssets(with: options)
      } else if let baseline { fetched = baseline }
      else { throw CancellationError() }
      await self?.acceptFetchResult(fetched, token: token, revision: revision)
      let known = Dictionary(previous.values.compactMap { item in item.localIdentifier.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
      let source = full ? fetched : PHAsset.fetchAssets(withLocalIdentifiers: Array(changed), options: nil)
      var upserts: [MediaItem] = []
      upserts.reserveCapacity(source.count)
      var seen = Set<String>()
      for start in stride(from: 0, to: source.count, by: 200) {
        try Task.checkCancellation()
        for index in start..<min(start + 200, source.count) {
          let asset = source.object(at: index)
          seen.insert(asset.localIdentifier)
          let old = known[asset.localIdentifier]
          let day = old?.captureDate == asset.creationDate ? old?.originalDay : asset.creationDate.map(ArchiveDay.init)
          let location = asset.location.map { Place(name: "照片位置", latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
          let item = MediaItem(id: old?.id ?? UUID().uuidString.lowercased(), assetName: "",
            title: day?.label ?? (asset.mediaType == .video ? "视频" : "照片"),
            kind: asset.mediaType == .video ? .video : .photo, originalDay: day,
            originalPlace: location, source: "系统照片库", localIdentifier: asset.localIdentifier, accessible: true,
            captureDate: asset.creationDate, modificationDate: asset.modificationDate)
          if old != item { upserts.append(item) }
        }
        await self?.updateScanProgress(min(start + 200, source.count), token: token)
      }
      try Task.checkCancellation()
      let unavailable = full ? Set(known.keys).subtracting(seen) : removed
      let ids = Set(unavailable.compactMap { known[$0]?.id })
      return PhotoScanResult(delta: PhotoLibraryDelta(upserts: upserts, inaccessibleIDs: ids, isFullSnapshot: full))
    }
    scanTask = task
    defer { if scanID == token { scanning = false; scanTask = nil } }
    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    try Task.checkCancellation()
    guard scanID == token, revision == changeRevision else { throw CancellationError() }
    needsFullRead = false; pendingChanged.subtract(changed); pendingRemoved.subtract(removed)
    return result.delta
  }
  /// Retry reconciliation after a caller could not commit a successfully read delta.
  func invalidateSnapshot() { needsFullRead = true }
  func cancelScan() { scanTask?.cancel(); scanID = UUID(); scanning = false }
  private func acceptFetchResult(_ result: PHFetchResult<PHAsset>, token: UUID, revision: Int) {
    if scanID == token, changeRevision == revision { fetchResult = result }
  }
  private func updateScanProgress(_ count: Int, token: UUID) { if scanID == token { scanned = count } }
  func asset(_ id: String?) -> PHAsset? { MediaPipeline.shared.asset(id) }
  func cloudMappings(_ identifiers: [String]) async -> [String: String] {
    guard !identifiers.isEmpty else { return [:] }
    return await Task.detached(priority: .utility) {
      PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: identifiers).reduce(into: [:]) {
        if case .success(let cloud) = $1.value { $0[$1.key] = cloud.stringValue }
      }
    }.value
  }
  func localMappings(_ identifiers: [String]) async -> [String: String] {
    guard !identifiers.isEmpty else { return [:] }
    return await Task.detached(priority: .utility) {
      let clouds = identifiers.map(PHCloudIdentifier.init(stringValue:))
      return PHPhotoLibrary.shared().localIdentifierMappings(for: clouds).reduce(into: [:]) {
        if case .success(let local) = $1.value { $0[$1.key.stringValue] = local }
      }
    }.value
  }
  var permissionLabel: String {
    switch authorization {
    case .authorized: "完整照片访问"
    case .limited: "有限照片访问"
    case .denied: "照片访问被拒绝"
    case .restricted: "照片访问受限制"
    default: "尚未授权照片访问"
    }
  }
}

@MainActor @Observable final class PhotoRequest {
  var image: UIImage?
  var player: AVPlayer?
  var progress: Double = 0
  var loading = false
  var message: String?
  @ObservationIgnored private var requestID: PHImageRequestID = PHInvalidImageRequestID
  @ObservationIgnored private var manager: PHImageManager?
  @ObservationIgnored private var generation = UUID()
  func cancel() {
    generation = UUID()
    if let manager, requestID != PHInvalidImageRequestID { manager.cancelImageRequest(requestID) }
    requestID = PHInvalidImageRequestID
    player?.pause(); player = nil
    image = nil; progress = 0
    loading = false
  }
  func load(item: MediaItem, library: PhotoKitLibrary, detail: Bool, network: Bool) {
    cancel(); image = nil; message = nil; progress = 0
    guard let asset = library.asset(item.localIdentifier) else { message = "照片无法访问或尚未关联"; return }
    loading = true
    manager = library.manager
    let token = generation
    if item.kind == .video && detail {
      let options = PHVideoRequestOptions()
      options.isNetworkAccessAllowed = network
      options.deliveryMode = .automatic
      options.progressHandler = { [weak self] value, _, _, _ in
        Task { @MainActor in if self?.generation == token { self?.progress = value } }
      }
      requestID = library.manager.requestPlayerItem(forVideo: asset, options: options) { [weak self] playerItem, info in
        let failure = (info?[PHImageErrorKey] as? Error)?.localizedDescription
        Task { @MainActor in
          guard let self, self.generation == token else { return }
          self.loading = false
          if let playerItem { self.player = AVPlayer(playerItem: playerItem) }
          else { self.message = failure ?? "视频需要从 iCloud 下载，请重试" }
        }
      }
    } else {
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = network
      options.deliveryMode = detail ? .highQualityFormat : .opportunistic
      options.resizeMode = .fast
      options.progressHandler = { [weak self] value, _, _, _ in
        Task { @MainActor in if self?.generation == token { self?.progress = value } }
      }
      let size = detail ? CGSize(width: 2400, height: 2400) : CGSize(width: 360, height: 360)
      requestID = library.manager.requestImage(for: asset, targetSize: size,
        contentMode: detail ? .aspectFit : .aspectFill, options: options) { [weak self] image, info in
          let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
          let failure = (info?[PHImageErrorKey] as? Error)?.localizedDescription
          Task { @MainActor in
            guard let self, self.generation == token else { return }
            if let image { self.image = image }
            if !degraded {
              self.loading = false
              if image == nil { self.message = failure ?? "照片需要从 iCloud 下载，请重试" }
            }
          }
        }
    }
  }
}
