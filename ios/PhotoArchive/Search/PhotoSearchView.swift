import SwiftUI

struct PhotoSearchView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(PhotoSearchController.self) private var search
  @State private var text = ""
  @FocusState private var searchFocused: Bool
  @State private var selection = Set<String>()
  @State private var draft: Story?
  @State private var editing: PhotoSearchQuery?
  @State private var showConditions = false
  @State private var showSettings = false
  @State private var saveAlbum = false
  @State private var albumName = ""
  @State private var showPossible = false
  @State private var detail: MediaItem?
  @State private var selecting = false
  var body: some View {
    @Bindable var search = search
    GeometryReader { geometry in
    VStack(spacing: 0) {
      let controls = VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top) {
            TextField("例如：去年春节在武汉的照片", text: $text, axis: .vertical)
              .focused($searchFocused).lineLimit(1...3).submitLabel(.search).accessibilityIdentifier("photo-search-input")
              .onSubmit { submit() }
            Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
              .accessibilityLabel("搜索").accessibilityIdentifier("photo-search-submit").disabled(text.isEmpty || search.loading)
          }.padding().background(ArchiveStyle.surface, in: .rect(cornerRadius: 16))
          if !search.query.hasConditions {
            ScrollView(.horizontal, showsIndicators: false) { HStack {
              ForEach(["海边", "去年春节在武汉", "聚餐"], id: \.self) { example in
                Button(example) { text = example; submit() }.buttonStyle(.bordered)
              }
            } }
          }
        }
        if search.query.hasConditions || search.query.needsYear {
          VStack(alignment: .leading, spacing: 10) {
            Text(conditionText(search.query)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("search-conditions")
            let actionsLayout = typeSize.isAccessibilitySize
              ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout())
            actionsLayout {
              Button("修改条件") { editing = search.query; showConditions = true }
              Button("撤回") { search.undo(store) }.disabled(search.history.isEmpty)
              if !typeSize.isAccessibilitySize { Spacer() }
              Button("重置") { search.reset(store); selection = [] }
            }.font(.footnote)
            if search.query.needsYear { Text("春节是哪一年？请在修改条件中选择。").foregroundStyle(.orange) }
            if !search.query.unresolved.isEmpty { Text("还有条件需要理解：\(search.query.unresolved)").font(.caption).foregroundStyle(ArchiveStyle.secondary) }
          }.padding().background(ArchiveStyle.tint, in: .rect(cornerRadius: 16))
        }
        if let proposed = search.draftCloudQuery {
          VStack(alignment: .leading, spacing: 8) {
            Text("请确认理解的条件").font(.headline)
            Text(conditionText(proposed))
            let actionsLayout = typeSize.isAccessibilitySize
              ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout())
            actionsLayout {
              Button("采用条件") { search.update(proposed, store: store) }
              Button("修改") { editing = proposed; showConditions = true }
              Button("取消") { search.draftCloudQuery = nil }
            }
          }.padding().background(ArchiveStyle.surface, in: .rect(cornerRadius: 16))
        }
        if search.loading { ProgressView("正在准备搜索索引，可随时切换页面") }
        Button { showSettings = true } label: {
          HStack(alignment: .top) {
            if search.busy { ProgressView().controlSize(.small) }
            Label(search.busy ? search.progress : search.preferences.localAnalysisPaused == true ? "本地分析已暂停" : "本地准备 · 待分析 \(search.pendingCount) 张", systemImage: "sparkle.magnifyingglass")
              .font(.caption).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
          }
        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("search-preparation-settings")
        if let message = search.message {
          Text(message).font(.footnote).foregroundStyle(ArchiveStyle.secondary)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("search-message")
        }
        if !search.preferences.albums.isEmpty && search.selectedAlbumID == nil {
          Menu {
            ForEach(search.preferences.albums) { album in
              Button(album.name) { search.openAlbum(album, store: store); selection = [] }
            }
          } label: { Label("保存的搜索（\(search.preferences.albums.count)）", systemImage: "rectangle.stack") }
            .accessibilityIdentifier("saved-search-menu")
        }
        if search.selectedAlbumID != nil {
          Text(search.preferences.albums.first { $0.id == search.selectedAlbumID }?.name ?? "搜索相册").font(.title2.bold())
          Text("本机动态匹配 · 选择照片后可从此相册排除").font(.caption).foregroundStyle(ArchiveStyle.secondary)
          Button("恢复手动排除的照片") {
            if let i = search.preferences.albums.firstIndex(where: { $0.id == search.selectedAlbumID }) { search.preferences.albums[i].excluded = []; search.persistPreferences(); search.refresh(store) }
          }.font(.footnote)
        }
        if search.query.hasConditions {
          if typeSize.isAccessibilitySize {
            Picker("结果类型", selection: $showPossible) {
              Text("符合条件 · \(search.matchCount)").tag(false)
              Text("可能相关 · \(search.possibleCount)").tag(true)
            }.pickerStyle(.menu).labelsHidden().font(.subheadline)
              .accessibilityLabel("结果类型").accessibilityIdentifier("search-result-kind")
          } else {
          Picker("结果类型", selection: $showPossible) {
            Text("符合条件 · \(search.matchCount)").tag(false)
            Text("可能相关 · \(search.possibleCount)").tag(true)
          }.pickerStyle(.segmented)
          }
          if showPossible { Text("缺少日期、地区或足够的画面证据的照片仍会保留在这里。")
            .font(.caption).foregroundStyle(.secondary) }
        }
        if !search.query.hasConditions {
          Text("仅搜索允许访问的照片；不分析视频内容。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.padding(.horizontal, 16).padding(.vertical, 12)
      if typeSize.isAccessibilitySize {
        // Only controls scroll here; the UIKit result grid remains a sibling with
        // its own viewport and reuse/prefetch lifecycle.
        ScrollView { controls }
          .accessibilityIdentifier("search-controls-scroll")
          .frame(height: search.query.hasConditions ? geometry.size.height * 0.45 : geometry.size.height)
          .onScrollPhaseChange { _, phase in search.setScrolling(phase != .idle) }
      } else { controls }
      if search.query.hasConditions && !(showPossible ? search.possible : search.matches).isEmpty {
        MediaGrid(items: showPossible ? search.possible : search.matches, effectiveDays: search.effectiveDays,
          selection: $selection, selecting: selecting, library: store.live?.photos,
          remoteURL: { id in try await store.live?.cloudMediaURL(for: id, preview: true) },
          onOpen: { detail = $0 }, onLoadMore: { search.loadMore(possible: showPossible) },
          onInteraction: { search.userDidInteract() }, onScrolling: { search.setScrolling($0) })
      } else if search.query.hasConditions && !search.loading {
        ScrollView {
          ContentUnavailableView(showPossible ? "没有待确认的照片" : "暂未找到符合条件的照片", systemImage: "magnifyingglass", description: Text("试着放宽条件，或查看另一组搜索结果。"))
        }
      } else {
        Spacer(minLength: 0)
      }
    }
    }
    .scrollDismissesKeyboard(.interactively)
    .background(ArchiveStyle.background).navigationTitle("找照片")
    .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) { Button(selecting ? "完成" : "选择") { selecting.toggle() } }
      ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("搜索设置") }
    }
    .safeAreaInset(edge: .bottom) {
      if search.query.hasConditions || !selection.isEmpty {
      let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
      layout {
        if !selection.isEmpty {
        Button("创建故事（\(selection.count)）") {
          let items = store.media, selected = selection, identity = search.owner, searchID = search.searchID
          Task {
            let ids = await Task.detached(priority: .userInitiated) { items.filter { selected.contains($0.id) }.map(\.id) }.value
            guard search.owner == identity, search.searchID == searchID, !Task.isCancelled else { return }
            draft = Story(title: "", mediaIDs: ids, coverID: ids.first)
          }
        }.buttonStyle(.borderedProminent).disabled(selection.isEmpty)
        }
        if search.selectedAlbumID != nil && !selection.isEmpty {
          Button("排除所选") {
            search.exclude(selection, store: store); selection = []
          }.buttonStyle(.bordered)
        }
        if search.query.hasConditions {
          Button("保存搜索") { albumName = search.preferences.albums.first { $0.id == search.selectedAlbumID }?.name ?? ""; saveAlbum = true }
          .buttonStyle(.bordered).disabled(!search.query.hasConditions || search.query.needsYear)
        }
      }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
      }
    }
    .onChange(of: search.owner) { _, _ in
      text = ""; selection = []; detail = nil; draft = nil; editing = nil
      showConditions = false; showSettings = false; saveAlbum = false; albumName = ""
      showPossible = false; selecting = false; searchFocused = false
    }
    .onChange(of: text) { _, _ in search.userDidInteract() }
    .onChange(of: detail) { _, value in search.setDetailPresented(value != nil) }
    .onDisappear { search.setScrolling(false) }
    .navigationDestination(item: $detail) { item in
      PhotoDetailView(initialID: item.id, mediaIDs: search.resultIDs(possible: showPossible))
    }
    .sheet(item: $draft) { StoryEditor(story: $0) }
    .sheet(isPresented: $showConditions) { SearchConditionEditor(query: editing ?? search.query) { search.update($0, store: store) } }
    .sheet(isPresented: $showSettings) { NavigationStack { SearchTaskSettingsView() } }

    .alert("保存搜索相册", isPresented: $saveAlbum) {
      TextField("相册名称", text: $albumName)
      Button("保存") { search.saveAlbum(name: albumName) }
      Button("取消", role: .cancel) { }
    } message: { Text("保存在本机，新照片自动参与本地匹配，不会自动产生模型费用。") }
  }
  private func submit() { searchFocused = false; search.submit(text, store: store); text = ""; selection = [] }
}

struct SearchTaskSettingsView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(PhotoSearchController.self) private var search
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var download = false
  @State private var showUsage = false
  @State private var retryBilling = false
  private var analysisControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      if search.busy {
        if search.processingTotal > 0 {
          ProgressView(search.progress, value: Double(search.processedCount), total: Double(search.processingTotal))
        } else { ProgressView(search.progress) }
        Button("停止后续处理") { search.stop() }
      } else {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
        layout {
          Button("本地分析／继续") { search.index(store, download: download) }.disabled(store.isDemo || search.loading)
          Spacer()
          Button("云端补充（最多 50 张）") { search.supplement(store, download: download) }
            .disabled(search.loading || !search.preferences.ai || store.live?.account.userID == nil || search.query.needsYear || !search.query.hasConditions)
        }.font(.subheadline)
      }
      if !search.busy && search.preferences.geo {
        Button("单独查询城市") { search.locate(store) }.disabled(search.loading || store.isDemo)
        Text("本地分析只识别画面；按城市搜索前，可单独查询城市。联网查询失败不会阻塞识图。").font(.caption).foregroundStyle(ArchiveStyle.secondary)
      }
      let waiting = search.waitingCount
      let pending = search.pendingCount
      Text("待本地分析 \(pending) 张 · 待下载或重试 \(waiting) 张").font(.caption).foregroundStyle(ArchiveStyle.secondary)
      if waiting > 0 && !search.busy {
        Button("下载待分析照片并继续（最多50张）") { download = true; search.index(store, download: true) }.disabled(search.loading)
        Text("从你的 iCloud 按需读取图片后在本机识别，会使用网络流量。").font(.caption).foregroundStyle(ArchiveStyle.secondary)
      }
      if !search.preferences.ai { Text("云端默认关闭，可在搜索设置中开启。日期和地区筛选不调用模型。").font(.caption).foregroundStyle(ArchiveStyle.secondary) }
      if !search.usage.filter({ $0.search_id == search.searchID }).isEmpty {
        Text("本次：" + SearchUsageView.summary(search.usage.filter { $0.search_id == search.searchID })).font(.caption)
      }
    }
  }
  var body: some View {
    @Bindable var search = search
    return Form {
        Section("本地分析") {
          Toggle("空闲时自动准备", isOn: Binding(get: { search.preferences.localAnalysisPaused != true }, set: { search.setAnalysisPaused(!$0) }))
          Text("只在前台停止操作 2 秒后分析本机照片。浏览、查看大图、低电量或设备发热时暂停；不会自动下载或调用云端 AI。")
            .font(.footnote)
          analysisControls
        }
        Section("用量与费用") {
          Button("AI 用量与费用") { showUsage = true; Task { await search.loadUsage(store) } }
        }
        Section("保存的搜索") {
          ForEach(search.preferences.albums) { album in
            HStack {
              Text(album.name)
              Spacer()
              Button(role: .destructive) { search.deleteAlbum(album.id) } label: { Image(systemName: "trash") }
                .accessibilityLabel("删除搜索相册 \(album.name)")
            }
          }
        }
        Section("地区查询") {
          Toggle("联网查询城市名称", isOn: $search.preferences.geo).onChange(of: search.preferences.geo) { _, _ in search.cancelCurrentWork(); search.persistPreferences() }
          Text("仅发送照片坐标给 Apple 地址解析服务，不发送照片。已缓存城市可以离线使用。").font(.footnote)
        }
        Section("云端 AI") {
          Toggle("允许云端补充", isOn: $search.preferences.ai).onChange(of: search.preferences.ai) { _, _ in search.cancelCurrentWork(); search.persistPreferences() }
          Text("仅点击补充时发送候选缩略图给 MiniMax；搜索条件和照片描述发送给 OpenRouter / TypeSafe Jev。独立于故事同步，不设消费上限。").font(.footnote)
          Button("已核对费用，允许重试失败请求") { retryBilling = true }
          Text("服务端不存储图片；模型供应商可能按其政策留存数据。费用页区分实际返回与估算金额。").font(.footnote)
          Link("MiniMax 隐私政策", destination: URL(string: "https://www.minimax.io/privacy-policy")!)
          Link("OpenRouter 数据政策", destination: URL(string: "https://openrouter.ai/docs/features/privacy-and-logging")!)
          if store.live?.account.userID == nil {
            Text("云端调用需要登录。")
            if let live = store.live { NavigationLink("前往账号设置") { LiveSettingsView(live: live) } }
          }
        }
        Section("iCloud 照片") {
          Toggle("本次分析允许下载缺失照片", isOn: $download)
          Text("默认只处理本机可用图片。此选项只在当前页面会话有效。").font(.footnote)
        }
      }.onChange(of: search.owner) { _, _ in download = false; showUsage = false; retryBilling = false }
        .navigationTitle("任务与搜索设置").toolbar { Button("完成") { dismiss() } }
        .sheet(isPresented: $showUsage) { SearchUsageView(records: search.usage, searchID: search.searchID) }
        .alert("允许重新请求？", isPresented: $retryBilling) {
          Button("已核对，允许重新请求", role: .destructive) { search.preferences.pending = [:]; search.persistPreferences() }
          Button("取消", role: .cancel) { }
        } message: { Text("这会清除失败或过期请求的本机去重凭据。之前未确认的调用可能已计费，重新分析可能再次产生费用。已保存的识别结果仍会复用。") }
  }
}
private func conditionText(_ q: PhotoSearchQuery) -> String {
  ([q.start.map { "\($0) — \(q.end ?? $0)" } ?? "全部日期", q.city.isEmpty ? "全部地区" : q.city] + q.include + q.exclude.map { "排除\($0)" } + (q.night ? ["18:00—次日 06:00"] : [])).joined(separator: " · ")
}
struct SearchConditionEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var query: PhotoSearchQuery
  var apply: (PhotoSearchQuery) -> Void
  @State private var year = SearchCalendar.calendar.component(.year, from: Date())
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("日期（留空表示不限）") {
          TextField("开始 YYYY-MM-DD", text: Binding(get: { query.start ?? "" }, set: { query.start = $0.isEmpty ? nil : $0 }))
          TextField("结束 YYYY-MM-DD", text: Binding(get: { query.end ?? "" }, set: { query.end = $0.isEmpty ? nil : $0 }))
          Picker("春节年份", selection: $year) { ForEach(1990...2100, id: \.self) { Text(String($0)).tag($0) } }
          Button("使用该年除夕至正月十五") { if let interval = SearchCalendar.springFestival(year) { query.start = interval.0; query.end = interval.1; query.needsYear = false } }
          Toggle("只看晚上拍摄", isOn: $query.night)
        }
        Section("地点与场景") {
          TextField("城市，例如武汉", text: $query.city)
          TextField("包含场景，以逗号分隔", text: Binding(get: { query.include.joined(separator: "，") }, set: { query.include = terms($0) }))
          TextField("排除场景，以逗号分隔", text: Binding(get: { query.exclude.joined(separator: "，") }, set: { query.exclude = terms($0) }))
          TextField("需要云端理解的补充要求", text: $query.unresolved, axis: .vertical)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("修改条件").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("应用") { do { try query.validate(); apply(query); dismiss() } catch { self.error = error.localizedDescription } } }
      }
    }
  }
  private func terms(_ value: String) -> [String] { value.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}
struct SearchUsageView: View {
  @Environment(\.dismiss) private var dismiss
  let records: [SearchUsage]
  let searchID: String
  static func summary(_ rows: [SearchUsage]) -> String {
    let groups = Dictionary(grouping: rows.filter { $0.cost != nil }, by: \.currency)
    let sums = groups.keys.sorted().map { currency in "\(currency) " + String(format: "%.6f", groups[currency]!.reduce(0) { $0 + ($1.cost ?? 0) }) }
    let subscription = rows.filter { $0.billing_mode == "subscription" && $0.input_tokens != nil && $0.status == "complete" }
    let unknown = rows.filter { row in row.cost == nil && !subscription.contains(where: { s in s.id == row.id }) }.count
    var parts = sums
    if !subscription.isEmpty { parts.append("订阅额度 \(subscription.reduce(0) { $0 + ($1.input_tokens ?? 0) + ($1.output_tokens ?? 0) }) token") }
    if unknown > 0 { parts.append("\(unknown) 笔待核对") }
    if rows.contains(where: { $0.estimated }) { parts.append("含估算") }
    return parts.isEmpty ? "暂无费用记录" : parts.joined(separator: " · ")
  }
  var body: some View {
    NavigationStack {
      List {
        Section("汇总") {
          LabeledContent("本次搜索", value: Self.summary(records.filter { $0.search_id == searchID }))
          LabeledContent("本月", value: Self.summary(records.filter { $0.created_at.hasPrefix(String(SearchCalendar.format(.now).prefix(7))) }))
          LabeledContent("累计", value: Self.summary(records))
          ForEach(Array(Set(records.map(\.provider))).sorted(), id: \.self) { p in LabeledContent(p, value: Self.summary(records.filter { $0.provider == p })) }
        }
        Section("调用明细") {
          if records.isEmpty { Text("暂无记录。未返回的费用不会记为零。") }
          ForEach(records) { row in
            VStack(alignment: .leading, spacing: 5) {
              Text(row.model).font(.headline)
              Text(Self.summary([row]))
              Text("\(row.status) · 输入 \(row.input_tokens.map(String.init) ?? "—") / 输出 \(row.output_tokens.map(String.init) ?? "—") token").font(.caption)
              if let rate = row.fx_rate, let cost = row.cost, row.currency != "CNY" { Text("约 ¥\(cost * rate, specifier: "%.6f") · 汇率 \(rate) · \(row.fx_date ?? "未提供日期")").font(.caption) }
              Text(row.created_at).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }.navigationTitle("AI 用量与费用").toolbar { Button("完成") { dismiss() } }
    }
  }
}
