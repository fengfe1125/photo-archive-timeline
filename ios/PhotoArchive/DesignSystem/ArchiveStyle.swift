import SwiftUI

enum ArchiveStyle {
  // Hallmark: native minimal; system semantic colors and typography, photo-first.
  static let background = Color(uiColor: .systemBackground)
  static let surface = Color(uiColor: .secondarySystemGroupedBackground)
  static let ink = Color.primary
  static let secondary = Color.secondary
  static let tint = Color(uiColor: .secondarySystemBackground)
  static func selectionMotion(reduced: Bool) -> Animation? {
    reduced ? nil : .spring(response: 0.28, dampingFraction: 0.88)
  }
}

struct SampleImage: View {
  let item: MediaItem
  @Environment(ArchiveStore.self) private var store
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?
  @State private var ticket: MediaPipeline.Ticket?
  @State private var representation: MediaImageKey?
  var body: some View {
    GeometryReader { geometry in
      let size = CGSize(width: max(1, geometry.size.width * displayScale), height: max(1, geometry.size.height * displayScale))
      let key = MediaImageKey(item: item, pixels: size, namespace: store.live?.photos.cacheNamespace ?? "demo")
      Group {
        if store.isDemo { Image(item.assetName).resizable().scaledToFill() }
        else if let image { Image(uiImage: image).resizable().scaledToFill() }
        else { ZStack { Color(uiColor: .secondarySystemBackground); Image(systemName: item.accessible ? "photo" : "photo.badge.exclamationmark").foregroundStyle(.secondary) } }
      }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        .task(id: key) {
          MediaPipeline.shared.cancel(ticket); image = nil; representation = key
          guard let live = store.live else { return }
          ticket = MediaPipeline.shared.thumbnail(item: item, pixels: size, namespace: live.photos.cacheNamespace,
            remoteURL: { try await live.cloudMediaURL(for: $0, preview: true) }) { loaded in
              guard representation == key else { return }
              if let loaded { image = loaded }
            }
        }
        .onDisappear { representation = nil; MediaPipeline.shared.cancel(ticket); ticket = nil; image = nil }
    }.accessibilityLabel(item.title)
  }
}

struct PhotoTile: View {
  let item: MediaItem
  var selected = false
  var selecting = false
  @Environment(\.accessibilityReduceMotion) private var reduced
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Color.clear.aspectRatio(1, contentMode: .fit)
        .overlay { SampleImage(item: item) }
        .clipped().clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
          if selecting {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .font(.title2).foregroundStyle(selected ? Color.accentColor : .white)
              .background(.regularMaterial, in: Circle()).padding(6)
              .animation(ArchiveStyle.selectionMotion(reduced: reduced), value: selected)
          } else if item.kind == .video {
            Image(systemName: "video.fill").padding(8).foregroundStyle(.white)
          }
        }
    }.contentShape(Rectangle())
  }
}

struct ZoomDetail: ViewModifier {
  let id: String
  let namespace: Namespace.ID
  @Environment(\.accessibilityReduceMotion) private var reduced
  func body(content: Content) -> some View {
    if reduced { content } else { content.navigationTransition(.zoom(sourceID: id, in: namespace)) }
  }
}
