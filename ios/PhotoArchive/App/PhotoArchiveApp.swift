import SwiftUI

@main struct PhotoArchiveApp: App {
  @State private var store: ArchiveStore?
  @State private var startupError: String?
  @Environment(\.scenePhase) private var scenePhase
  init() {
    let args = ProcessInfo.processInfo.arguments
    let base = URL.applicationSupportDirectory.appendingPathComponent(
      "PhotoArchive", isDirectory: true)
    let testing = args.contains("-ui-testing")
    if testing || args.contains("-demo") {
      let folder = testing ? "UITests" : "Demo"
      _store = State(initialValue: ArchiveStore(repository: JSONArchiveRepository(directory: base.appendingPathComponent(folder))))
    } else {
      do {
        let liveFolder = args.contains("-live-ui-testing") ? "LiveUITests" : "Live"
        let directory = base.appendingPathComponent(liveFolder)
        if liveFolder == "LiveUITests" && args.contains("-reset-live-test-data") && FileManager.default.fileExists(atPath: directory.path) {
          try FileManager.default.removeItem(at: directory)
        }
        _store = State(initialValue: ArchiveStore(live: try LiveArchiveController(directory: directory)))
      }
      catch { _startupError = State(initialValue: "本地档案无法打开，原数据已保留：\(error.localizedDescription)") }
    }
  }
  var body: some Scene {
    WindowGroup {
      if let store {
      RootView().environment(store).tint(.accentColor)
        .task {
          if ProcessInfo.processInfo.arguments.contains("-ui-testing")
            && ProcessInfo.processInfo.arguments.contains("-reset-test-data")
          {
            await store.reset()
          } else {
            await store.load()
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { Task { await store.live?.foreground() } }
        }
      } else { ContentUnavailableView("档案暂时无法读取", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "请重新启动 App。")) }
    }
  }
}

struct RootView: View {
  @Environment(ArchiveStore.self) private var store
  @AppStorage("hasBrowsedSamples") private var started = false
  @State private var reset = false
  var body: some View {
    Group {
      if !store.loaded {
        VStack(spacing: 24) {
          if let error = store.error ?? store.live?.error {
            ContentUnavailableView(
              "档案暂时无法读取", systemImage: "externaldrive.badge.exclamationmark",
              description: Text(error))
            Button("重试读取") { Task { await store.load() } }
            if store.isDemo { Button("重置示例数据", role: .destructive) { reset = true } }
          } else {
            ProgressView("正在打开本地档案")
          }
        }
      } else if store.isDemo && !started && !ProcessInfo.processInfo.arguments.contains("-ui-testing") {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            Image("Sample11").resizable().scaledToFit().clipShape(.rect(cornerRadius: 24))
            Text("把日子，\n好好收起来。").font(.largeTitle.bold())
            Text("温暖的私人照片档案").font(.title2)
            Text("本轮浏览公开样片，不访问系统照片库。所有整理仅保存在本机，不上传照片或位置信息。")
            Button("浏览示例照片") { started = true }.buttonStyle(.borderedProminent).controlSize(.large)
              .foregroundStyle(Color("OnAccent"))
          }.padding(24)
        }
      } else {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-verify-local-search") {
          NavigationStack { PhotoSearchView() }
        } else { mainTabs }
        #else
        mainTabs
        #endif
      }
    }.background(ArchiveStyle.background).foregroundStyle(ArchiveStyle.ink)
      .confirmationDialog("重置示例数据？现有整理会备份在本机，仅重置此演示档案。", isPresented: $reset, titleVisibility: .visible) {
        Button("确认重置", role: .destructive) { Task { await store.reset() } }
      }
  }
  private var mainTabs: some View {
        TabView {
          Tab("图库", systemImage: "photo.on.rectangle.angled") { NavigationStack { LibraryView() } }
          Tab("找照片", systemImage: "magnifyingglass") { NavigationStack { PhotoSearchView() } }
          Tab("故事", systemImage: "book.closed") { NavigationStack { StoriesView() } }
          Tab("地图", systemImage: "map") { NavigationStack { ArchiveMapView() } }
        }
  }
}
