import Foundation
@preconcurrency import Photos
import UIKit
import ImageIO

/// The complete representation identity, never just the archive UUID.
struct MediaImageKey: Hashable, Sendable {
  let namespace: String
  let mediaID: String
  let resource: String
  let version: Date?
  let width: Int
  let height: Int
  init(item: MediaItem, pixels: CGSize, namespace: String) {
    self.namespace = namespace
    mediaID = item.id
    resource = item.accessible ? item.localIdentifier ?? item.id : "remote:" + item.id
    version = item.modificationDate
    width = max(1, Int(pixels.width.rounded(.up)))
    height = max(1, Int(pixels.height.rounded(.up)))
  }
}

@MainActor final class MediaPipeline {
  static let shared = MediaPipeline()
  static let thumbnailBudget = 48 * 1024 * 1024
  typealias RemoteLoader = @Sendable (URL) async throws -> Data
  private let remoteLoader: RemoteLoader
  let manager = PHCachingImageManager()
  struct Ticket: Hashable { fileprivate let key: MediaImageKey; fileprivate let id: UUID }
  private final class KeyBox: NSObject {
    let key: MediaImageKey
    init(_ key: MediaImageKey) { self.key = key }
    override var hash: Int { key.hashValue }
    override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
  }
  private final class Flight {
    var callbacks: [UUID: (UIImage?) -> Void] = [:]
    var request: PHImageRequestID = PHInvalidImageRequestID
    var task: Task<Void, Never>?
    let generation = UUID()
  }
  private struct Preheat {
    var keys: Set<MediaImageKey>
    var assets: [MediaImageKey: PHAsset]
  }
  private let cache = NSCache<KeyBox, UIImage>()
  private let assets = NSCache<NSString, PHAsset>()
  private var flights: [MediaImageKey: Flight] = [:]
  private var preheats: [UUID: Preheat] = [:]
  private var memoryObserver: NSObjectProtocol?
  private(set) var activeRequestCount = 0
  init(remoteLoader: @escaping RemoteLoader = MediaPipeline.download) {
    self.remoteLoader = remoteLoader
    cache.totalCostLimit = Self.thumbnailBudget
    assets.countLimit = 600
    memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.reduceMemory() }
    }
  }
  private func options() -> PHImageRequestOptions {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = false
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    return options
  }
  func asset(_ identifier: String?) -> PHAsset? {
    guard let identifier else { return nil }
    if let asset = assets.object(forKey: identifier as NSString) { return asset }
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
    assets.setObject(asset, forKey: identifier as NSString)
    return asset
  }
  func prepareAssets(_ items: [MediaItem]) {
    let identifiers = items.filter(\.accessible).compactMap(\.localIdentifier).filter { assets.object(forKey: $0 as NSString) == nil }
    guard !identifiers.isEmpty else { return }
    let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
    for index in 0..<result.count {
      let asset = result.object(at: index)
      assets.setObject(asset, forKey: asset.localIdentifier as NSString)
    }
  }
  func invalidate(localIdentifiers: Set<String>) {
    guard !localIdentifiers.isEmpty else { return }
    for id in localIdentifiers { assets.removeObject(forKey: id as NSString) }
    // NSCache cannot enumerate representations; a PhotoKit edit is infrequent and
    // clearing avoids serving an old bitmap after permission/content changes.
    cache.removeAllObjects()
    for key in Array(flights.keys) where localIdentifiers.contains(key.resource) { cancelFlight(key) }
  }
  @discardableResult func thumbnail(
    item: MediaItem, pixels: CGSize, namespace: String,
    remoteURL: ((String) async throws -> URL?)? = nil,
    completion: @escaping (UIImage?) -> Void
  ) -> Ticket {
    let key = MediaImageKey(item: item, pixels: pixels, namespace: namespace)
    let ticket = Ticket(key: key, id: UUID())
    if let image = cache.object(forKey: KeyBox(key)) { completion(image); return ticket }
    if let flight = flights[key] { flight.callbacks[ticket.id] = completion; return ticket }
    let flight = Flight()
    flight.callbacks[ticket.id] = completion
    flights[key] = flight
    activeRequestCount = flights.count
    let generation = flight.generation
    if item.accessible, let asset = asset(item.localIdentifier) {
      flight.request = manager.requestImage(for: asset, targetSize: CGSize(width: key.width, height: key.height), contentMode: .aspectFill, options: options()) { [weak self] image, info in
        let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
        let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
        Task { @MainActor in self?.deliver(image, key: key, generation: generation, terminal: !degraded || cancelled) }
      }
    } else if !item.accessible, let remoteURL {
      let loader = remoteLoader
      flight.task = Task { [weak self] in
        do {
          guard let url = try await remoteURL(item.id) else { throw URLError(.resourceUnavailable) }
          try Task.checkCancellation()
          let data = try await loader(url)
          try Task.checkCancellation()
          let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return Self.downsample(data, maximumPixelSize: max(key.width, key.height))
          }
          let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
          try Task.checkCancellation()
          self?.deliver(image, key: key, generation: generation, terminal: true)
        } catch { self?.deliver(nil, key: key, generation: generation, terminal: true) }
      }
    } else { deliver(nil, key: key, generation: generation, terminal: true) }
    return ticket
  }
  private func deliver(_ image: UIImage?, key: MediaImageKey, generation: UUID, terminal: Bool) {
    guard let flight = flights[key], flight.generation == generation else { return }
    if terminal, let image { cache.setObject(image, forKey: KeyBox(key), cost: Self.byteCost(image)) }
    let callbacks = Array(flight.callbacks.values)
    if terminal { flights.removeValue(forKey: key); activeRequestCount = flights.count }
    for callback in callbacks { callback(image) }
  }
  func cancel(_ ticket: Ticket?) {
    guard let ticket, let flight = flights[ticket.key] else { return }
    flight.callbacks.removeValue(forKey: ticket.id)
    if flight.callbacks.isEmpty { cancelFlight(ticket.key) }
  }
  private func cancelFlight(_ key: MediaImageKey) {
    guard let flight = flights.removeValue(forKey: key) else { return }
    flight.task?.cancel()
    if flight.request != PHInvalidImageRequestID { manager.cancelImageRequest(flight.request) }
    activeRequestCount = flights.count
  }
  /// One screen before and after the visible range. Consumers release their own window.
  func preheat(items: [MediaItem], pixels: CGSize, namespace: String, consumer: UUID) {
    let local = items.filter { $0.accessible && $0.localIdentifier != nil }
    prepareAssets(local)
    var next = Preheat(keys: [], assets: [:])
    for item in local {
      let key = MediaImageKey(item: item, pixels: pixels, namespace: namespace)
      if let asset = assets.object(forKey: (item.localIdentifier ?? "") as NSString) { next.keys.insert(key); next.assets[key] = asset }
    }
    let old = preheats[consumer] ?? Preheat(keys: [], assets: [:])
    let otherKeys = preheats.filter { $0.key != consumer }.values.reduce(into: Set<MediaImageKey>()) { $0.formUnion($1.keys) }
    for key in old.keys.subtracting(next.keys).subtracting(otherKeys) {
      if let asset = old.assets[key] { manager.stopCachingImages(for: [asset], targetSize: CGSize(width: key.width, height: key.height), contentMode: .aspectFill, options: options()) }
    }
    let added = next.keys.subtracting(old.keys).subtracting(otherKeys)
    if let key = added.first {
      manager.startCachingImages(for: added.compactMap { next.assets[$0] }, targetSize: CGSize(width: key.width, height: key.height), contentMode: .aspectFill, options: options())
    }
    preheats[consumer] = next
  }
  func stopPreheating(_ consumer: UUID) { preheat(items: [], pixels: .zero, namespace: "", consumer: consumer); preheats.removeValue(forKey: consumer) }
  func reduceMemory() {
    preheats = [:]; manager.stopCachingImagesForAllAssets()
    cache.removeAllObjects(); assets.removeAllObjects()
  }
  func clear() {
    for key in Array(flights.keys) { cancelFlight(key) }
    preheats = [:]; manager.stopCachingImagesForAllAssets()
    cache.removeAllObjects(); assets.removeAllObjects()
  }
  nonisolated private static func download(_ url: URL) async throws -> Data {
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      response.expectedContentLength <= 16 * 1024 * 1024 else { throw URLError(.badServerResponse) }
    var data = Data()
    if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
    for try await byte in bytes {
      if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
      guard data.count < 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return data
  }
  nonisolated static func byteCost(_ image: UIImage) -> Int {
    if let bitmap = image.cgImage { return bitmap.bytesPerRow * bitmap.height }
    return max(1, Int(ceil(image.size.width * image.scale)) * Int(ceil(image.size.height * image.scale)) * 4)
  }
  nonisolated static func downsample(_ data: Data, maximumPixelSize: Int) -> UIImage? {
    autoreleasepool {
      guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize)
        ] as CFDictionary) else { return nil }
      return UIImage(cgImage: image)
    }
  }
}
