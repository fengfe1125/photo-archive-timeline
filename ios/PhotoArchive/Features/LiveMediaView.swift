import SwiftUI
import AVKit
import ImageIO
import UniformTypeIdentifiers

struct LiveMediaView: View {
  let item: MediaItem
  let active: Bool
  let live: LiveArchiveController
  @State private var request = PhotoRequest()
  @State private var retry = 0
  @State private var cancelled = false
  @State private var remotePlayer: AVPlayer?
  @State private var remoteImage: UIImage?
  @State private var remoteMessage: String?
  @State private var remoteLoading = false
  @State private var linking = false
  @State private var linkSelection = Set<String>()
  @State private var share: ShareFile?
  @State private var sharing = false
  @State private var shareTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 12) {
      if let player = request.player { VideoPlayer(player: player).frame(minHeight: 250) }
      else if let image = request.image ?? remoteImage {
        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(item.title)
      } else if let remotePlayer { VideoPlayer(player: remotePlayer).frame(minHeight: 250) }
      else {
        ContentUnavailableView("照片暂不可见", systemImage: "photo.badge.exclamationmark",
          description: Text(remoteMessage ?? request.message ?? "正在加载"))
      }
      if request.loading || remoteLoading {
        ProgressView(request.progress > 0 ? "正在从 iCloud 下载" : "正在加载")
        Button("取消加载") {
          cancelled = true; releaseMedia(); remoteMessage = "加载已取消，可重新加载。"
        }
      } else if remoteMessage != nil || request.message != nil || cancelled {
        Text(remoteMessage ?? request.message ?? "加载已取消").font(.footnote).foregroundStyle(.secondary)
        Button("重新加载") { cancelled = false; retry += 1 }
      }
      if !item.accessible {
        Button("关联这台设备上的照片") { linkSelection = []; linking = true }
      }
      if let image = request.image ?? remoteImage, item.kind == .photo {
        Button("分享去位置信息副本", systemImage: "square.and.arrow.up") {
          sharing = true
          let owner = live.owner
          shareTask = Task {
            defer { sharing = false }
            do {
              let url = try await PrivacyShare.makeInBackground(image: image)
              guard !Task.isCancelled, owner == live.owner else { try? FileManager.default.removeItem(at: url); return }
              share = ShareFile(url: url)
            }
            catch { if !Task.isCancelled && owner == live.owner { live.error = error.localizedDescription } }
          }
        }.disabled(sharing)
      }
    }
    .task(id: "\(live.owner)-\(item.id)-\(item.accessible)-\(active)-\(cancelled)-\(item.localIdentifier ?? "")-\(item.modificationDate?.timeIntervalSince1970 ?? 0)-\(retry)") {
      let owner = live.owner
      guard active, !cancelled else { releaseMedia(); return }
      request.cancel(); remotePlayer?.pause(); remotePlayer = nil; remoteImage = nil; remoteLoading = false
      remoteMessage = nil
      if item.accessible {
        request.load(item: item, library: live.photos, detail: true, network: true)
      } else {
        remoteLoading = true
        defer { if !Task.isCancelled { remoteLoading = false } }
        do {
          guard let url = try await live.cloudMediaURL(for: item.id) else {
            remoteMessage = "原片尚未上传或云端不可用。"; return
          }
          try Task.checkCancellation()
          guard live.owner == owner else { return }
          if item.kind == .video { remotePlayer = AVPlayer(url: url) }
          else {
            let (file, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudMediaError.invalidResponse }
            try Task.checkCancellation()
            let decoding = Task.detached(priority: .userInitiated) {
              try Task.checkCancellation()
              guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2400,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary) else { return UIImage?.none }
              return UIImage(cgImage: pixels)
            }
            let decoded = try await withTaskCancellationHandler { try await decoding.value } onCancel: { decoding.cancel() }
            try Task.checkCancellation()
            guard live.owner == owner else { return }
            remoteImage = decoded
            if decoded == nil { remoteMessage = "照片无法解码，请重新加载。" }
          }
        } catch {
          if !Task.isCancelled && live.owner == owner { remoteMessage = error.localizedDescription }
        }
      }
    }
    .onDisappear { releaseMedia() }
    .sheet(isPresented: $linking) {
      MediaPicker(title: "关联这台设备上的照片", selection: $linkSelection,
        query: LibraryQuery(kind: item.kind, accessibleOnly: true, excludedIDs: [item.id]),
        maximumItems: 1) { ids in
          guard let id = ids.first, let candidate = live.item(id) else { return }
          Task {
            await live.associate(id: item.id, with: candidate)
            if live.item(item.id)?.accessible == true { linking = false; retry += 1 }
          }
        }
        .safeAreaInset(edge: .bottom) {
          if let error = live.error { Text(error).foregroundStyle(.red).padding() }
        }
    }
    .sheet(item: $share, onDismiss: { PrivacyShare.cleanExpired() }) { file in
      ActivityShare(url: file.url).onDisappear { try? FileManager.default.removeItem(at: file.url) }
    }
  }

  private func releaseMedia() {
    shareTask?.cancel(); shareTask = nil
    request.cancel(); remotePlayer?.pause(); remotePlayer = nil; remoteImage = nil; remoteLoading = false
  }
}
struct ShareFile: Identifiable { let id = UUID(); let url: URL }
enum PrivacyShare {
  static var directory: URL { URL.temporaryDirectory.appendingPathComponent("PhotoArchiveShares", isDirectory: true) }
  static func make(image: UIImage) throws -> URL {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    try Task.checkCancellation()
    guard let pixels = rendered.cgImage else { throw ArchiveError.invalidData }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw ArchiveError.invalidData }
    CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ArchiveError.invalidData }
    try Task.checkCancellation()
    let url = directory.appendingPathComponent("Photo-\(UUID().uuidString).jpg")
    try (bytes as Data).write(to: url, options: [.atomic, .completeFileProtection])
    if Task.isCancelled { try? FileManager.default.removeItem(at: url); throw CancellationError() }
    return url
  }
  static func makeInBackground(image: UIImage) async throws -> URL {
    let work = Task.detached(priority: .userInitiated) { try make(image: image) }
    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
  }
  static func cleanExpired() {
    guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
    for file in files {
      let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      if date < .now.addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: file) }
    }
  }
}
struct ActivityShare: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
    return controller
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
