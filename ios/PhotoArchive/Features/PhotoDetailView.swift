import SwiftUI

struct PhotoDetailView: View {
  @Environment(ArchiveStore.self) private var store
  let initialID: String
  let mediaIDs: [String]
  @State private var currentID: String
  @State private var info = false
  @State private var storyDraft: Story?
  @State private var choosingStory = false
  init(initialID: String, mediaIDs: [String]) {
    self.initialID = initialID
    self.mediaIDs = mediaIDs
    _currentID = State(initialValue: initialID)
  }
  private var detailWindow: [String] {
    guard !mediaIDs.isEmpty else { return [] }
    let index = mediaIDs.firstIndex(of: currentID) ?? 0
    return Array(mediaIDs[max(0, index - 1)...min(mediaIDs.count - 1, index + 1)])
  }
  var body: some View {
    VStack(spacing: 12) {
      TabView(selection: $currentID) {
        ForEach(detailWindow, id: \.self) { id in
          if let item = store.item(id) {
            VStack(spacing: 20) {
              if let live = store.live { LiveMediaView(item: item, active: currentID == id, live: live) }
              else { Image(item.assetName).resizable().scaledToFit().accessibilityLabel(item.title) }
              if store.isDemo && item.kind == .video {
                ContentUnavailableView(
                  "视频暂不可播放", systemImage: "video.slash", description: Text("此处仅演示媒体类型，尚未接入视频文件。"))
              }
            }.tag(id)
          }
        }
      }.tabViewStyle(.page(indexDisplayMode: .never))
      if let item = store.item(currentID) {
        VStack(spacing: 8) {
          Text(store.day(item)?.label ?? "日期待确认").font(.headline)
          Text(store.place(item)?.name ?? "没有位置信息").font(.footnote).foregroundStyle(.secondary)
          if let notes = store.snapshot.corrections[item.id]?.description, !notes.isEmpty {
            Text(notes).font(.body)
          }
          Text("\((mediaIDs.firstIndex(of: currentID) ?? 0) + 1) / \(mediaIDs.count) · 左右滑动浏览")
            .font(.caption)
          Button("加入故事", systemImage: "book.closed") { choosingStory = true }.buttonStyle(.bordered)
        }.padding(.bottom)
      }
    }.background(ArchiveStyle.background)
      .navigationTitle(store.item(currentID)?.title ?? "照片").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("照片信息", systemImage: "info.circle") { info = true }.accessibilityIdentifier(
            "photo-info")
        }
        ToolbarItem(placement: .bottomBar) {
          if store.isDemo, let item = store.item(currentID), item.kind == .photo {
            ShareLink(
              item: Image(item.assetName),
              preview: SharePreview(item.title, image: Image(item.assetName))
            ) { Label("分享无 GPS 样片", systemImage: "square.and.arrow.up") }
          }
        }
      }
      .sheet(isPresented: $info) {
        if let item = store.item(currentID) {
          PhotoInfoView(item: item).presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
      }
      .sheet(item: $storyDraft) { StoryEditor(story: $0) }
      .confirmationDialog("加入故事", isPresented: $choosingStory) {
        Button("新建故事") { storyDraft = Story(title: "", mediaIDs: [currentID], coverID: currentID) }
        ForEach(store.snapshot.stories) { story in
          Button(story.title) {
            var draft = story
            if !draft.mediaIDs.contains(currentID) { draft.mediaIDs.append(currentID) }
            storyDraft = draft
          }
        }
      }
  }
}

struct PhotoInfoView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let item: MediaItem
  @State private var editing = false
  @State private var restoring = false
  var body: some View {
    NavigationStack {
      Form {
        Section("档案信息") {
          LabeledContent("日期", value: store.day(item)?.label ?? "未知")
          LabeledContent("地点", value: store.place(item)?.name ?? "无位置")
          Text(store.snapshot.corrections[item.id]?.description ?? "尚未添加描述")
          Button("修正档案信息") { editing = true }.accessibilityIdentifier("edit-metadata")
        }
        Section("照片原始信息") {
          Text(item.originalDay?.label ?? "日期未知")
          Text(item.originalPlace?.name ?? "没有 GPS")
          Text(item.source).font(.footnote)
          if store.snapshot.corrections[item.id] != nil { Button("恢复原始值") { restoring = true } }
        }
        Section("所属故事") {
          let stories = store.snapshot.stories.filter { $0.mediaIDs.contains(item.id) }
          if stories.isEmpty { Text("尚未加入故事") }
          ForEach(stories) { Text($0.title) }
        }
        Text("修正仅保存在本 App，不会修改或删除系统照片原件。").font(.footnote)
        if let error = store.error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("照片信息").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { dismiss() }.accessibilityIdentifier("close-info")
          }
        }
        .sheet(isPresented: $editing) {
          MetadataEditor(item: item, correction: store.snapshot.corrections[item.id])
        }
        .confirmationDialog("恢复日期、地点和描述为原始状态？", isPresented: $restoring, titleVisibility: .visible)
      {
        Button("确认恢复") { Task { _ = await store.saveCorrection(nil, for: item.id) } }
      }
    }
  }
}

struct MetadataEditor: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let item: MediaItem
  @State private var date: Date
  @State private var hasDate: Bool
  @State private var dayMode: OverrideMode
  @State private var placeMode: OverrideMode
  @State private var place: String
  @State private var notes: String
  @State private var discard = false
  let baseline: MetadataCorrection
  init(item: MediaItem, correction: MetadataCorrection?) {
    self.item = item
    let initial =
      correction
      ?? MetadataCorrection(
        mediaID: item.id, originalDay: item.originalDay, originalPlace: item.originalPlace,
        day: nil, place: nil, description: "", dayMode: .original, placeMode: .original)
    baseline = initial
    _date = State(initialValue: initial.day?.date ?? item.originalDay?.date ?? .now)
    _dayMode = State(initialValue: initial.effectiveDayMode)
    _placeMode = State(initialValue: initial.effectivePlaceMode)
    _hasDate = State(initialValue: initial.day != nil || item.originalDay != nil)
    _place = State(initialValue: initial.place?.name ?? item.originalPlace?.name ?? "")
    _notes = State(initialValue: initial.description)
  }
  var draft: MetadataCorrection {
    var edited = baseline
    edited.dayMode = dayMode
    edited.placeMode = placeMode
    edited.day = dayMode == .value ? ArchiveDay(date) : nil
    edited.place = placeMode == .value ? Place(name: place, latitude: nil, longitude: nil) : nil
    edited.description = notes
    return edited
  }
  var dirty: Bool { draft != baseline }
  var body: some View {
    NavigationStack {
      Form {
        Section("档案日期") {
          Picker("日期来源", selection: $dayMode) {
            Text("原始日期").tag(OverrideMode.original); Text("清空").tag(OverrideMode.clear); Text("自定义").tag(OverrideMode.value)
          }
          if dayMode == .value { DatePicker("日期", selection: $date, displayedComponents: .date) }
        }
        Section("地点与描述") {
          Picker("地点来源", selection: $placeMode) {
            Text("原始地点").tag(OverrideMode.original); Text("清空").tag(OverrideMode.clear); Text("自定义").tag(OverrideMode.value)
          }
          if placeMode == .value { TextField("地点名称（不自动生成 GPS）", text: $place) }
          TextField("描述", text: $notes, axis: .vertical).accessibilityIdentifier("metadata-notes")
        }
        Section("原始值") {
          Text(item.originalDay?.label ?? "日期未知")
          Text(item.originalPlace?.name ?? "没有位置")
        }
        Text("只修正档案，不修改系统原件。修改地点名称后不沿用旧坐标。")
        if let error = store.error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("修正信息").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { if dirty { discard = true } else { dismiss() } }.disabled(store.saving)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(store.saving ? "保存中…" : "保存") {
              Task { if await store.saveCorrection(draft, for: item.id) { dismiss() } }
            }.disabled(store.saving).accessibilityIdentifier("save-metadata")
          }
        }
        .interactiveDismissDisabled(dirty || store.saving)
        .confirmationDialog("放弃未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
          Button("放弃修改", role: .destructive) { dismiss() }
        }
    }
  }
}
