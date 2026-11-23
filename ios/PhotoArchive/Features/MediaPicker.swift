import SwiftUI

/// Shared multi-page selection for stories and one-photo association.
struct MediaPicker: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(PhotoSearchController.self) private var search
  @Environment(\.dismiss) private var dismiss
  var title = "添加照片"
  @Binding var selection: Set<String>
  var query = LibraryQuery()
  var maximumItems: Int? = nil
  var onDone: ([String]) -> Void
  @State private var context: LibraryNavigationContext?
  @State private var limitMessage: String?
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let context {
          ZStack {
            MediaGrid(items: context.items, effectiveDays: context.effectiveDays, selection: boundedSelection, selecting: true,
                      library: store.live?.photos,
                      remoteURL: store.live.map { live in { try await live.cloudMediaURL(for: $0, preview: true) } },
                      onOpen: { _ in }, onLoadMore: { Task { await context.loadNext() } },
                      onInteraction: { search.userDidInteract() }, onScrolling: { search.setScrolling($0) })
            if context.loading && context.items.isEmpty { ProgressView() }
            if !context.loading && context.items.isEmpty {
              ContentUnavailableView("没有可选照片", systemImage: "photo", description: Text("请检查照片访问范围或媒体类型。"))
            }
          }
          if let error = context.error {
            VStack(spacing: 8) {
              Text(error).font(.footnote).foregroundStyle(.secondary)
              Button("重试") { search.userDidInteract(); Task { await context.reload() } }
            }.padding()
          }
        } else { ProgressView(); Spacer() }
        if let limitMessage { Text(limitMessage).font(.footnote).foregroundStyle(.secondary).padding() }
      }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成（\(selection.count)）") {
              let loaded = context?.mediaIDs ?? []
              let result = loaded.filter { selection.contains($0) } + selection.subtracting(loaded).sorted()
              onDone(result); dismiss()
            }.disabled(selection.isEmpty)
          }
        }
        .task(id: "\(store.live?.owner ?? "demo"):\(store.libraryRevision)") {
          if context?.query != query || context?.owner != (store.live?.owner ?? "demo") { context = LibraryNavigationContext(store: store, query: query) }
          await context?.reload()
        }
    }.onAppear { search.userDidInteract() }
      .onDisappear { search.setScrolling(false) }
      .onChange(of: store.live?.owner) { _, _ in selection = []; dismiss() }
  }
  private var boundedSelection: Binding<Set<String>> {
    Binding(get: { selection }, set: { next in
      if maximumItems == 1, let newest = next.subtracting(selection).first { selection = [newest]; limitMessage = nil }
      else if let maximumItems, next.count > maximumItems { limitMessage = "最多选择 \(maximumItems) 张照片。" }
      else { selection = next; limitMessage = nil }
    })
  }
}
