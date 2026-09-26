import MapKit
import SwiftUI

struct ArchiveMapView: View {
  @Environment(ArchiveStore.self) private var store
  @State private var selected: String?
  @State private var clusters: [PhotoMapCluster] = []
  @State private var loading = true
  @State private var mediaIDs: [String] = []
  private var revision: String { "\(store.live?.owner ?? "demo"):\(store.searchRevision)" }
  var body: some View {
    VStack(spacing: 0) {
      Text(store.isDemo ? "虚构样例坐标 · 不请求定位" : "按区域汇总照片 · 不请求设备实时定位")
        .font(.caption).padding().frame(maxWidth: .infinity).background(ArchiveStyle.tint)
      if loading {
        ProgressView("正在整理照片位置").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if clusters.isEmpty {
        ContentUnavailableView("没有带位置的照片", systemImage: "map", description: Text("无 GPS 的照片不会生成地图标记。"))
      } else {
        Map(selection: $selected) {
          ForEach(clusters) { group in
            Marker("\(group.mediaIDs.count) 张照片", coordinate: CLLocationCoordinate2D(latitude: group.latitude, longitude: group.longitude)).tag(group.id)
          }
        }.mapStyle(.standard(elevation: .flat))
        if let group = clusters.first(where: { $0.id == selected }) {
          NavigationLink {
            MapPhotoList(mediaIDs: group.mediaIDs)
          } label: {
            Label("查看这个区域的 \(group.mediaIDs.count) 张照片", systemImage: "photo.on.rectangle").padding()
          }
        }
        NavigationLink("查看全部 \(mediaIDs.count) 张有位置照片") {
          MapPhotoList(mediaIDs: mediaIDs)
        }.padding()
      }
    }.background(ArchiveStyle.background).navigationTitle("地图")
      .task(id: revision) {
        loading = true; selected = nil; clusters = []; mediaIDs = []
        let items = store.media
        let corrections = store.snapshot.corrections
        let work = Task.detached(priority: .userInitiated) {
          let points = items.compactMap { item -> PhotoMapPoint? in
            let correction = corrections[item.id]
            let place = correction?.effectivePlaceMode == .clear ? nil : correction?.effectivePlaceMode == .value ? correction?.place : item.originalPlace
            guard let lat = place?.latitude, let lon = place?.longitude else { return nil }
            return PhotoMapPoint(id: item.id, latitude: lat, longitude: lon)
          }
          return PhotoMapCluster.build(points)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        clusters = result; mediaIDs = result.flatMap(\.mediaIDs); loading = false
      }
  }
}

private struct MapPhotoList: View {
  @Environment(ArchiveStore.self) private var store
  let mediaIDs: [String]
  var body: some View {
    List(mediaIDs, id: \.self) { id in
      if let item = store.item(id) {
        NavigationLink { PhotoDetailView(initialID: id, mediaIDs: mediaIDs) } label: {
          HStack {
            SampleImage(item: item).frame(width: 60, height: 60).clipped()
            Text(item.title)
          }
        }
      }
    }.navigationTitle("位置照片")
  }
}

struct SettingsView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var reset = false
  var body: some View {
    Group {
    if let live = store.live { LiveSettingsView(live: live) } else {
    Form {
      Section("本地演示") {
        Label("公开样片模式", systemImage: "photo")
        Text("未请求照片权限，不读取你的照片库。整理结果存放在本机独立目录。")
        LabeledContent("账号", value: "尚未接入")
        LabeledContent("Supabase 同步", value: "尚未接入")
      }
      Section("隐私") {
        Text("整理信息同步不等于照片备份。当前版本没有上传功能。")
        Text("分享只发送已去除元数据的公开样片，不附带档案中的虚构 GPS。")
      }
      Section("调试场景 · 不是真实服务") {
        Text("系统减少动态效果：\(reduced ? "已开启" : "已关闭")")
          .accessibilityIdentifier("motion-status")
        Text(store.demoSync.rawValue).accessibilityIdentifier("demo-sync-status")
        NavigationLink("演示账号与同步") { DemoSyncView() }
        NavigationLink("演示照片访问与错误状态") { DemoScenariosView() }
      }
      Section {
        Button("重置示例数据", role: .destructive) { reset = true }.disabled(store.saving)
        Text("需要确认。旧档案会备份，只影响本 App 演示存储。").font(.footnote)
        if let error = store.error { Text(error).foregroundStyle(.red) }
      }
    }.navigationTitle("设置")
      .confirmationDialog("重置故事和档案修正？", isPresented: $reset, titleVisibility: .visible) {
        Button("确认重置", role: .destructive) { Task { await store.reset() } }
      }
    }
    }
  }
}

struct DemoSyncView: View {
  @Environment(ArchiveStore.self) private var store
  @State private var email = ""
  @State private var consent = false
  var body: some View {
    Form {
      Section("始终为演示：不会发送邮件或连接 Supabase") {
        Text(store.demoSync.rawValue).accessibilityIdentifier("demo-sync-status")
        if store.demoSync == .signedOut {
          TextField("演示邮箱", text: $email).textInputAutocapitalization(.never).keyboardType(
            .emailAddress)
          Button("演示登录") { store.demoSync = .ready }.disabled(!email.contains("@"))
        } else {
          Toggle("演示：同意同步整理信息（不含媒体）", isOn: $consent)
          Button("演示同步成功") { Task { await store.runDemoSync(fail: false) } }.disabled(
            !consent || store.demoSync == .syncing)
          Button(store.demoSync == .failed ? "演示重试" : "演示同步失败") {
            Task { await store.runDemoSync(fail: store.demoSync != .failed) }
          }.disabled(!consent || store.demoSync == .syncing)
          if store.demoSync == .syncing { ProgressView("演示处理中") }
          Button("退出演示账号") {
            store.demoSync = .signedOut
            consent = false
          }.disabled(store.demoSync == .syncing)
        }
      }
      Text("演示状态仅在本次 App 会话共享。真实账号与同步仍未接入，不会显示真实云端成功。")
    }.navigationTitle("同步演示")
  }
}

enum DemoScenario: String, CaseIterable, Identifiable {
  case limited = "有限授权"
  case denied = "拒绝授权"
  case empty = "空图库"
  case loading = "加载中"
  case offline = "离线"
  case download = "iCloud 下载"
  case downloadFailed = "iCloud 下载失败"
  case unavailable = "照片无法访问"
  case unlinked = "照片未关联"
  var id: String { rawValue }
  var message: String {
    switch self {
    case .limited: "只能浏览获准的照片。正式接入后可管理授权范围。"
    case .denied: "系统照片库不可访问。本轮可继续浏览公开样片。"
    case .empty: "还没有可展示的照片。可返回示例图库。"
    case .loading: "缩略图正在加载；此处只是状态演示。"
    case .offline: "本地故事仍可编辑。地图底图可能无法加载。"
    case .download: "照片仅在 iCloud 中，需要下载。这与整理信息同步是两回事。"
    case .downloadFailed: "原图下载失败。恢复网络后可重试。"
    case .unavailable: "原照片可能已移除或不在授权范围内。不会删除档案整理信息。"
    case .unlinked: "保留故事信息，等待在这台设备关联原照片。登录不代表照片已备份。"
    }
  }
}

struct DemoScenariosView: View {
  @State private var scenario: DemoScenario = .limited
  @State private var retried = false
  var body: some View {
    Form {
      Picker("演示场景", selection: $scenario) {
        ForEach(DemoScenario.allCases) { Text($0.rawValue).tag($0) }
      }
      Section("演示 · 非系统权限弹窗") {
        ContentUnavailableView(
          scenario.rawValue, systemImage: "photo.badge.exclamationmark",
          description: Text(scenario.message))
        if scenario == .loading || scenario == .download { ProgressView("演示等待状态") }
        Button("演示重试／恢复") { retried = true }
        if retried { Text("演示恢复完成。返回图库可继续浏览样片；未执行实际授权或下载。") }
      }
    }.navigationTitle("状态演示").onChange(of: scenario) { retried = false }
  }
}
