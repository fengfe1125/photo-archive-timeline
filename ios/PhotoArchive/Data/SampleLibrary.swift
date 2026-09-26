import Foundation

struct SampleLibrary: PhotoLibraryProviding {
  let media: [MediaItem] = [
    MediaItem(
      id: "sample-10", assetName: "Sample10", title: "湖边", kind: .photo,
      originalDay: ArchiveDay(2023, 9, 21),
      originalPlace: Place(name: "湖畔 · 虚构地点", latitude: 30.24, longitude: 120.14),
      source: "公开样片 · 日期与位置为虚构"),
    MediaItem(
      id: "sample-11", assetName: "Sample11", title: "河谷", kind: .photo,
      originalDay: ArchiveDay(2023, 9, 21),
      originalPlace: Place(name: "河谷 · 虚构地点", latitude: 30.25, longitude: 120.15),
      source: "公开样片 · 日期与位置为虚构"),
    MediaItem(
      id: "sample-12", assetName: "Sample12", title: "海风", kind: .photo,
      originalDay: ArchiveDay(2023, 9, 21), originalPlace: nil, source: "公开样片 · 无位置"),
    MediaItem(
      id: "sample-13", assetName: "Sample13", title: "远山", kind: .photo,
      originalDay: ArchiveDay(2021, 9, 21),
      originalPlace: Place(name: "海岸 · 虚构地点", latitude: 30.28, longitude: 120.18),
      source: "公开样片 · 日期与位置为虚构"),
    MediaItem(
      id: "sample-14", assetName: "Sample14", title: "岸边", kind: .photo,
      originalDay: ArchiveDay(2020, 2, 29), originalPlace: nil, source: "公开样片 · 闰日示例"),
    MediaItem(
      id: "sample-15", assetName: "Sample15", title: "溪流", kind: .photo, originalDay: nil,
      originalPlace: nil, source: "公开样片 · 日期未知"),
    MediaItem(
      id: "sample-video", assetName: "Sample15", title: "溪流视频示意", kind: .video,
      originalDay: ArchiveDay(2021, 9, 21), originalPlace: nil, source: "类型演示 · 没有视频文件"),
  ]
  static var seed: ArchiveSnapshot {
    ArchiveSnapshot(stories: [
      Story(
        id: "sample-story", title: "风吹过河谷", description: "把沿途的风景，收进同一个故事。",
        mediaIDs: (10...15).map { "sample-\($0)" }, coverID: "sample-11")
    ])
  }
}
