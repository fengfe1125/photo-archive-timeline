import SwiftUI

struct LibraryView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduced
  @Namespace private var namespace
  @State private var selecting = false
  @State private var selection = Set<String>()
  @State private var kind = "全部"
  @State private var year = 0
  @State private var month = 0
  @State private var draft: Story?
  var filtered: [MediaItem] {
    store.media.filter {
      (kind == "全部" || $0.kind.rawValue == kind) && (year == 0 || store.day($0)?.year == year)
        && (month == 0 || store.day($0)?.month == month)
    }
  }
  var body: some View {
    let items = filtered
    let mediaIDs = items.map(\.id)
    let grouped = Dictionary(grouping: items) { store.day($0) }
    let groups = grouped.keys.sorted {
      ($0 ?? ArchiveDay(0, 0, 0)) > ($1 ?? ArchiveDay(0, 0, 0))
    }
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if let live = store.live { PhotoPermissionSection(live: live) }
        Text("按日子收好，每次都能找回。").font(.footnote).foregroundStyle(ArchiveStyle.secondary)
        let filterLayout =
          typeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
          : AnyLayout(HStackLayout())
        filterLayout {
          Menu {
            Picker("年份", selection: $year) {
              Text("全部年份").tag(0)
              ForEach(
                Array(Set(store.media.compactMap { store.day($0)?.year })).sorted(by: >), id: \.self
              ) { Text(String($0)).tag($0) }
            }
            Picker("月份", selection: $month) {
              Text("全部月份").tag(0)
              ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
            }
          } label: {
            Label(year == 0 && month == 0 ? "全部日期" : "日期筛选", systemImage: "calendar")
          }
          if !typeSize.isAccessibilitySize { Spacer() }
          Picker("媒体类型", selection: $kind) { ForEach(["全部", "照片", "视频"], id: \.self) { Text($0) } }
            .pickerStyle(.menu)
        }.padding().background(ArchiveStyle.tint, in: .rect(cornerRadius: 16))
        NavigationLink {
          MemoriesView()
        } label: {
          HStack(spacing: 12) {
            if !typeSize.isAccessibilitySize {
              Image(systemName: "clock.arrow.circlepath").resizable().scaledToFit().frame(width: 60, height: 60).padding(10)
                .clipShape(.rect(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
              Label("那年今日", systemImage: "clock.arrow.circlepath").font(.headline)
              Text("回到同一天，看看从前的风景。").font(.footnote).foregroundStyle(ArchiveStyle.secondary)
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize { Image(systemName: "chevron.right") }
          }.padding(12).background(ArchiveStyle.tint, in: .rect(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityIdentifier("memories")
        if items.isEmpty {
          ContentUnavailableView(
            "没有符合筛选的照片", systemImage: "photo", description: Text("选择全部日期或其他媒体类型。"))
        }
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(groups, id: \.self) { day in
            Text(day?.label ?? "日期待确认").font(.headline)
            LazyVGrid(
              columns: Array(
                repeating: GridItem(.flexible(), spacing: 6),
                count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 6
            ) {
              ForEach(grouped[day] ?? []) { item in
                if selecting {
                  Button {
                    if selection.contains(item.id) {
                      selection.remove(item.id)
                    } else {
                      selection.insert(item.id)
                    }
                  } label: {
                    PhotoTile(item: item, selected: selection.contains(item.id), selecting: true)
                  }.buttonStyle(.plain).accessibilityIdentifier("select-\(item.id)")
                    .accessibilityLabel(
                      "\(item.title)，\(selection.contains(item.id) ? "已选择" : "未选择")")
                } else {
                  NavigationLink {
                    PhotoDetailView(initialID: item.id, mediaIDs: mediaIDs).modifier(
                      ZoomDetail(id: item.id, namespace: namespace))
                  } label: {
                    PhotoTile(item: item).matchedTransitionSource(id: item.id, in: namespace)
                  }.buttonStyle(.plain).accessibilityIdentifier("photo-\(item.id)")
                }
              }
            }
          }
        }.id("\(kind)-\(year)-\(month)").transition(.opacity)
        Text(store.isDemo ? "本地演示 · 公开样片 · 未访问你的照片库" : "本机照片保留在系统图库 · 云端原片需登录后读取").font(.caption).foregroundStyle(ArchiveStyle.secondary)
      }.padding(24)
    }.background(ArchiveStyle.background).navigationTitle("图库")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink {
            SettingsView()
          } label: {
            Image(systemName: "gearshape")
          }.accessibilityLabel("设置")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(selecting ? "完成" : "选择") {
            selecting.toggle()
            selection.removeAll()
          }.accessibilityIdentifier("select-mode")
        }
      }
      .safeAreaInset(edge: .bottom) {
        if selecting {
          Button("用 \(selection.count) 张照片创建故事") {
            draft = Story(
              title: "", mediaIDs: store.media.filter { selection.contains($0.id) }.map(\.id),
              coverID: nil)
          }
          .buttonStyle(.borderedProminent).foregroundStyle(Color("OnAccent"))
          .disabled(selection.isEmpty).padding().frame(
            maxWidth: .infinity
          ).background(.regularMaterial)
        }
      }
      .sheet(item: $draft) { StoryEditor(story: $0) }
      .animation(reduced ? nil : .easeOut(duration: 0.18), value: kind)
      .animation(reduced ? nil : .easeOut(duration: 0.18), value: year)
      .animation(reduced ? nil : .easeOut(duration: 0.18), value: month)
  }
}

struct MemoriesView: View {
  @Environment(ArchiveStore.self) private var store
  @Namespace private var namespace
  @State private var date = Date.now
  var items: [MediaItem] { store.memories(on: ArchiveDay(date)) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        DatePicker("选择日期", selection: $date, displayedComponents: .date)
        Text("只收录往年同月同日；日期未知的照片不参与。").font(.footnote).foregroundStyle(.secondary)
        if items.isEmpty {
          ContentUnavailableView(
            "这一天还没有回忆", systemImage: "calendar", description: Text("选择其他日期，看看从前的照片。"))
        }
        ForEach(Array(Set(items.compactMap { store.day($0)?.year })).sorted(by: >), id: \.self) {
          year in
          Text(String(year)).font(.title2.bold())
          ForEach(items.filter { store.day($0)?.year == year }) { item in
            NavigationLink {
              PhotoDetailView(initialID: item.id, mediaIDs: items.map(\.id)).modifier(
                ZoomDetail(id: item.id, namespace: namespace))
            } label: {
              PhotoTile(item: item).matchedTransitionSource(id: item.id, in: namespace)
            }.buttonStyle(.plain)
          }
        }
      }.padding(24)
    }.background(ArchiveStyle.background).navigationTitle("那年今日")
  }
}
