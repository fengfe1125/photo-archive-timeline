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
  @State private var remotePlayer: AVPlayer?
  @State private var remoteImage: UIImage?
  @State private var remoteMessage: String?
  @State private var linking = false
  @State private var share: ShareFile?
  var body: some View {
    VStack(spacing: 12) {
      if let player = request.player { VideoPlayer(player: player).frame(minHeight: 250) }
      else if let image = request.image ?? remoteImage { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(item.title) }
      else if let remotePlayer { VideoPlayer(player: remotePlayer).frame(minHeight: 250) }
      else { ContentUnavailableView("照片暂不可见", systemImage: "photo.badge.exclamationmark", description: Text(remoteMessage ?? request.message ?? "正在加载")) }
      if request.loading {
        ProgressView(request.progress > 0 ? "正在从 iCloud 下载" : "正在加载", value: request.progress)
        Button("取消加载") { request.cancel(); request.message = "加载已取消，可重新加载。" }
      } else if request.message != nil { Text(request.message ?? "").font(.footnote); Button("重新加载") { retry += 1 } }
      if !item.accessible { Button("关联这台设备上的照片") { linking = true } }
      if let image = request.image, item.kind == .photo {
        Button("分享去位置信息副本", systemImage: "square.and.arrow.up") {
          do { share = ShareFile(url: try PrivacyShare.make(image: image)) }
          catch { live.error = error.localizedDescription }
        }
      }
    }
    .task(id: "\(active)-\(item.localIdentifier ?? "")-\(retry)") {
      if active {
        if item.accessible { request.load(item: item, library: live.photos, detail: true, network: true) }
        else {
          do {
            if let url = try await live.cloudMediaURL(for: item.id) {
              if item.kind == .video { remotePlayer = AVPlayer(url: url) }
              else {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudMediaError.invalidResponse }
                remoteImage = UIImage(data: data)
              }
            } else { remoteMessage = "原片尚未上传或云端不可用。" }
          } catch { remoteMessage = error.localizedDescription }
        }
      } else { request.cancel(); remotePlayer?.pause(); remotePlayer = nil; remoteImage = nil }
    }
    .onDisappear { request.cancel() }
    .sheet(isPresented: $linking) {
      NavigationStack {
        List(live.visibleMedia.filter { $0.kind == item.kind && $0.accessible && $0.id != item.id }) { candidate in
          Button {
            live.associate(id: item.id, with: candidate)
            if live.item(item.id)?.accessible == true { linking = false }
          } label: {
            HStack { SampleImage(item: candidate).frame(width: 60, height: 60).clipped(); Text(candidate.title) }
          }
        }.navigationTitle("选择对应的照片")
          .safeAreaInset(edge: .bottom) { if let error = live.error { Text(error).foregroundStyle(.red).padding() } }
          .toolbar { Button("取消") { linking = false } }
      }
    }
    .sheet(item: $share, onDismiss: { PrivacyShare.cleanExpired() }) { file in
      ActivityShare(url: file.url).onDisappear { try? FileManager.default.removeItem(at: file.url) }
    }
  }
}
struct ShareFile: Identifiable { let id = UUID(); let url: URL }
@MainActor enum PrivacyShare {
  static var directory: URL { URL.temporaryDirectory.appendingPathComponent("PhotoArchiveShares", isDirectory: true) }
  static func make(image: UIImage) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    guard let pixels = rendered.cgImage else { throw ArchiveError.invalidData }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw ArchiveError.invalidData }
    CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ArchiveError.invalidData }
    let url = directory.appendingPathComponent("Photo-\(UUID().uuidString).jpg")
    try (bytes as Data).write(to: url, options: [.atomic, .completeFileProtection])
    return url
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
