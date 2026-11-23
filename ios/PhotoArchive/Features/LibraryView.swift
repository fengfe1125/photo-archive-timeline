import SwiftUI

struct LibraryView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var selecting = false
  @State private var selection = Set<String>()
  @State private var kind: MediaItem.Kind?
  @State private var year: Int?
  @State private var month: Int?
  @State private var context: LibraryNavigationContext?
  @State private var opened: MediaItem?
  @State private var draft: Story?
  var onInteraction: () -> Void = {}
  var onScrolling: (Bool) -> Void = { _ in }
  private var query: LibraryQuery { LibraryQuery(kind: kind, year: year, month: month) }
  private var reloadKey: LibraryReloadKey { LibraryReloadKey(query: query, revision: store.libraryRevision, owner: store.live?.owner ?? "demo") }
  var body: some View {
    VStack(spacing: 0) {
      if let live = store.live { PhotoPermissionSection(live: live).padding(.horizontal, 16) }
      let filterLayout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        : AnyLayout(HStackLayout(spacing: 16))
      filterLayout {
        Menu {
          Picker("年份", selection: $year) {
            Text("全部年份").tag(nil as Int?)
            ForEach(context?.years ?? [], id: \.self) { Text(String($0)).tag(Optional($0)) }
          }
          Picker("月份", selection: $month) {
            Text("全部月份").tag(nil as Int?)
            ForEach(1...12, id: \.self) { Text("\($0) 月").tag(Optional($0)) }
          }
        } label: { Label(year.map(String.init) ?? (month == nil ? "全部日期" : "日期筛选"), systemImage: "calendar") }
        Picker("媒体类型", selection: $kind) {
          Text("全部").tag(nil as MediaItem.Kind?)
          ForEach(MediaItem.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.pickerStyle(.menu)
        if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        NavigationLink { MemoriesView() } label: {
          if typeSize.isAccessibilitySize { Label("那年今日", systemImage: "clock.arrow.circlepath") }
          else { Image(systemName: "clock.arrow.circlepath") }
        }
          .accessibilityLabel("那年今日").accessibilityIdentifier("memories")
      }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
      if let context {
        ZStack {
          MediaGrid(items: context.items, effectiveDays: context.effectiveDays, selection: $selection, selecting: selecting,
                    library: store.live?.photos, remoteURL: remoteURL,
                    onOpen: { opened = $0 }, onLoadMore: { Task { await context.loadNext() } },
                    onInteraction: onInteraction, onScrolling: onScrolling)
          if context.items.isEmpty {
            if context.loading { ProgressView("正在打开图库") }
            else { ContentUnavailableView("没有符合筛选的照片", systemImage: "photo", description: Text("选择其他日期，或检查照片访问范围。")) }
          }
        }
        if let error = context.error {
          HStack { Text(error).font(.caption); Button("重试") { Task { await context.reload() } } }.padding(12)
        }
      } else { Spacer(); ProgressView(); Spacer() }
    }
    .background(Color(uiColor: .systemBackground)).navigationTitle("图库")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button(selecting ? "完成" : "选择") { onInteraction(); selecting.toggle(); if !selecting { selection.removeAll() } }
          .accessibilityIdentifier("select-mode")
      }
    }
    .safeAreaInset(edge: .bottom) {
      if selecting {
        Button("用 \(selection.count) 张照片创建故事") {
          let loaded = context?.mediaIDs ?? []
          let ordered = loaded.filter { selection.contains($0) } + selection.subtracting(loaded).sorted()
          draft = Story(title: "", mediaIDs: ordered, coverID: ordered.first)
        }.buttonStyle(.borderedProminent).disabled(selection.isEmpty || !store.archiveReady).padding().frame(maxWidth: .infinity).background(.bar)
      }
    }
    .task(id: reloadKey) {
      if context?.query != query || context?.owner != (store.live?.owner ?? "demo") { context = LibraryNavigationContext(store: store, query: query) }
      await context?.reload()
    }
    .onChange(of: kind) { _, _ in onInteraction() }
    .onChange(of: year) { _, _ in onInteraction() }
    .onChange(of: month) { _, _ in onInteraction() }
    .onDisappear { onScrolling(false) }
    .onChange(of: store.live?.owner) { _, _ in opened = nil; selection = []; draft = nil }
    .navigationDestination(item: $opened) { item in
      PhotoDetailView(initialID: item.id, mediaIDs: context?.mediaIDs ?? [item.id], libraryContext: context)
    }
    .sheet(item: $draft) { StoryEditor(story: $0) }
  }
  private var remoteURL: ((String) async throws -> URL?)? {
    guard let live = store.live else { return nil }
    return { try await live.cloudMediaURL(for: $0, preview: true) }
  }
}

private struct LibraryReloadKey: Hashable {
  var query: LibraryQuery
  var revision: Int
  var owner: String
}

struct MemoriesView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(PhotoSearchController.self) private var search
  @State private var date = Date.now
  @State private var context: LibraryNavigationContext?
  @State private var opened: MediaItem?
  private var query: LibraryQuery { LibraryQuery(anniversary: ArchiveDay(date)) }
  var body: some View {
    VStack(spacing: 0) {
      DatePicker("选择日期", selection: $date, displayedComponents: .date).padding(16)
      if let context {
        if !context.loading && context.items.isEmpty {
          ContentUnavailableView("这一天还没有回忆", systemImage: "calendar", description: Text("选择其他日期，看看从前的照片。"))
        } else {
          MediaGrid(items: context.items, effectiveDays: context.effectiveDays, library: store.live?.photos,
                    remoteURL: store.live.map { live in { try await live.cloudMediaURL(for: $0, preview: true) } },
                    onOpen: { opened = $0 }, onLoadMore: { Task { await context.loadNext() } },
                    onInteraction: { search.userDidInteract() }, onScrolling: { search.setScrolling($0) })
        }
      } else { ProgressView(); Spacer() }
    }.background(Color(uiColor: .systemBackground)).navigationTitle("那年今日")
      .task(id: LibraryReloadKey(query: query, revision: store.libraryRevision, owner: store.live?.owner ?? "demo")) {
        if context?.query != query || context?.owner != (store.live?.owner ?? "demo") { context = LibraryNavigationContext(store: store, query: query) }
        await context?.reload()
      }
      .onChange(of: date) { _, _ in search.userDidInteract() }
      .onAppear { search.userDidInteract() }
      .onDisappear { search.setScrolling(false) }
      .navigationDestination(item: $opened) { item in
        PhotoDetailView(initialID: item.id, mediaIDs: context?.mediaIDs ?? [item.id], libraryContext: context)
      }
  }
}
