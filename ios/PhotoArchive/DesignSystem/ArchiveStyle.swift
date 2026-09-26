import SwiftUI

enum ArchiveStyle {
  static let background = Color("Paper")
  static let surface = Color("Surface")
  static let ink = Color("Ink")
  static let secondary = Color("Muted")
  static let tint = Color("Tint")
  static func selectionMotion(reduced: Bool) -> Animation? {
    reduced ? nil : .spring(response: 0.28, dampingFraction: 0.88)
  }
}

struct SampleImage: View {
  let item: MediaItem
  @Environment(ArchiveStore.self) private var store
  @State private var request = PhotoRequest()
  @State private var remoteImage: UIImage?
  var body: some View {
    Group {
      if store.isDemo { Image(item.assetName).resizable().scaledToFill() }
      else if let image = request.image ?? remoteImage { Image(uiImage: image).resizable().scaledToFill() }
      else { ZStack { ArchiveStyle.tint; Image(systemName: item.accessible ? "photo" : "photo.badge.exclamationmark").foregroundStyle(.secondary) } }
    }
    .accessibilityLabel(item.title)
    .task(id: "\(item.id)-\(item.localIdentifier ?? "")-\(item.accessible)") {
      if let live = store.live {
        if item.accessible { request.load(item: item, library: live.photos, detail: false, network: false) }
        else if let url = try? await live.cloudMediaURL(for: item.id, preview: true),
          let (data, response) = try? await URLSession.shared.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200 { remoteImage = UIImage(data: data) }
      }
    }
    .onDisappear { request.cancel() }
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
