#if DEBUG
import Foundation

/// Explicit UI-test fixture. No PhotoKit identifiers or external image requests.
struct PerformanceLibrary: PhotoLibraryProviding {
  let media: [MediaItem] = (0..<1_000).map { index in
    let suffix = String(format: "%04d", index)
    return MediaItem(
      id: "paging-\(suffix)", assetName: "Sample\(10 + index % 6)",
      title: "分页照片 \(suffix)", kind: .photo,
      originalDay: ArchiveDay(2024, 1, 15), originalPlace: nil,
      source: "分页测试素材 · 日期为固定示例")
  }
  static var seed: ArchiveSnapshot { ArchiveSnapshot(stories: []) }
}
#endif
