import Foundation
@preconcurrency import Photos
import UIKit
import AVFoundation
import Observation

@MainActor protocol PhotoLibraryAccessProviding {
  var authorization: PHAuthorizationStatus { get }
  func requestAuthorization() async
  func read(previous: [String: MediaItem]) async -> [MediaItem]
}

@MainActor @Observable final class PhotoKitLibrary: NSObject, PhotoLibraryAccessProviding, PHPhotoLibraryChangeObserver {
  private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  private(set) var scanning = false
  private(set) var scanned = 0
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored let manager = PHCachingImageManager()
  @ObservationIgnored private var observing = false
  override init() { super.init() }
  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor [weak self] in self?.onChange?() }
  }
  func requestAuthorization() async {
    authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
  }
  func read(previous: [String: MediaItem]) async -> [MediaItem] {
    authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard authorization == .authorized || authorization == .limited else { return [] }
    if !observing { PHPhotoLibrary.shared().register(self); observing = true }
    scanning = true; scanned = 0
    defer { scanning = false }
    // Build metadata away from the UI actor; only publish batched progress.
    return await Task.detached(priority: .userInitiated) { [weak self] in
      let options = PHFetchOptions()
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
      let assets = PHAsset.fetchAssets(with: options)
      let known = Dictionary(previous.values.compactMap { item in item.localIdentifier.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
      var result: [MediaItem] = []
      result.reserveCapacity(assets.count)
      for start in stride(from: 0, to: assets.count, by: 200) {
        for index in start..<min(start + 200, assets.count) {
          let asset = assets.object(at: index)
          let old = known[asset.localIdentifier]
          let day = old?.captureDate == asset.creationDate ? old?.originalDay : asset.creationDate.map(ArchiveDay.init)
          let location = asset.location.map { Place(name: "照片位置", latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
          var item = MediaItem(id: old?.id ?? UUID().uuidString.lowercased(), assetName: "",
            title: day?.label ?? (asset.mediaType == .video ? "视频" : "照片"),
            kind: asset.mediaType == .video ? .video : .photo, originalDay: day,
            originalPlace: location, source: "系统照片库", localIdentifier: asset.localIdentifier, accessible: true)
          item.captureDate = asset.creationDate
          result.append(item)
        }
        await self?.updateScanProgress(result.count)
      }
      return result
    }.value
  }
  private func updateScanProgress(_ count: Int) { scanned = count }

  func asset(_ id: String?) -> PHAsset? {
    guard let id else { return nil }
    return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
  }
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
