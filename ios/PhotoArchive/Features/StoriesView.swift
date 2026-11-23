import SwiftUI

struct StoriesView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(PhotoSearchController.self) private var search
  @State private var draft: Story?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 28) {
        if !store.archiveReady {
          ProgressView("正在准备故事").frame(maxWidth: .infinity)
        } else if store.snapshot.stories.isEmpty {
          ContentUnavailableView(
            "还没有故事", systemImage: "book.closed", description: Text("点右上角加号，选几张照片开始。"))
        }
        ForEach(store.snapshot.stories) { story in
          NavigationLink {
            StoryDetailView(id: story.id)
          } label: {
            VStack(alignment: .leading, spacing: 12) {
              if let id = story.coverID, let item = store.item(id) {
                SampleImage(item: item).frame(height: 210).clipped().clipShape(
                  .rect(cornerRadius: 16))
              }
              Text(story.title).font(.title3.weight(.semibold))
              Text("\(story.count) 张照片").font(.subheadline).foregroundStyle(.secondary)
              if !story.description.isEmpty {
                Text(story.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
              }
            }
          }.buttonStyle(.plain).accessibilityIdentifier("story-\(story.id)")
        }
      }.padding(20)
    }.background(ArchiveStyle.background).navigationTitle("故事")
      .onScrollPhaseChange { _, phase in search.setScrolling(phase != .idle) }
      .onDisappear { search.setScrolling(false) }
      .toolbar {
        Button("新建故事", systemImage: "plus") { draft = Story(title: "", mediaIDs: [], coverID: nil) }.disabled(!store.archiveReady)
      }
      .sheet(item: $draft) { StoryEditor(story: $0) }
  }
}

struct StoryDetailView: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(PhotoSearchController.self) private var search
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var editing: Story?
  @State private var deleting = false
  @State private var readingDescription = false
  @State private var opened: MediaItem?
  @Environment(\.dismiss) private var dismiss
  let id: String
  var body: some View {
    if let story = store.snapshot.stories.first(where: { $0.id == id }) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 16) {
          if let cover = story.coverID, let item = store.item(cover) {
            SampleImage(item: item).frame(width: 72, height: 72).clipped().clipShape(.rect(cornerRadius: 8)).id(cover)
              .accessibilityIdentifier("story-cover-\(cover)")
          }
          VStack(alignment: .leading, spacing: 6) {
            Text(story.title).font(.title2.weight(.semibold))
            Text("\(story.count) 张照片").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("story-count")
            if !story.description.isEmpty {
              Text(story.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
              Button("阅读完整说明") { readingDescription = true }.font(.subheadline)
            }
          }
          Spacer(minLength: 0)
        }.padding(20)
        MediaGrid(items: story.mediaIDs.compactMap { store.item($0) },
          library: store.live?.photos,
          remoteURL: { id in try await store.live?.cloudMediaURL(for: id, preview: true) },
          groupByDate: false,
          onOpen: { opened = $0 }, onInteraction: { search.userDidInteract() },
          onScrolling: { search.setScrolling($0) })
      }.background(ArchiveStyle.background).navigationTitle("故事").navigationBarTitleDisplayMode(
        .inline
      )
      .toolbar {
        Button("编辑") { editing = story }.accessibilityIdentifier("edit-story")
        Button("删除故事", systemImage: "trash", role: .destructive) { deleting = true }
      }
      .confirmationDialog("删除故事？系统照片不会删除。", isPresented: $deleting) {
        Button("删除故事", role: .destructive) { Task { if await store.deleteStory(id) { dismiss() } } }
      }
      .sheet(item: $editing) { StoryEditor(story: $0) }
      .sheet(isPresented: $readingDescription) {
        NavigationStack {
          ScrollView { Text(story.description).frame(maxWidth: .infinity, alignment: .leading).padding(20).textSelection(.enabled) }
            .navigationTitle("故事说明").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { readingDescription = false } }
        }
      }
      .navigationDestination(item: $opened) { item in
        PhotoDetailView(initialID: item.id, mediaIDs: story.mediaIDs)
      }
    } else {
      ContentUnavailableView("故事不存在", systemImage: "book.closed")
    }
  }
}

struct StoryEditor: View {
  @Environment(ArchiveStore.self) private var store
  @Environment(PhotoSearchController.self) private var search
  @Environment(\.dismiss) private var dismiss
  let original: Story
  @State private var draft: Story
  @State private var discard = false
  @State private var undo: Story?
  @State private var addingPhotos = false
  @State private var additions = Set<String>()
  init(story: Story) {
    original = story
    _draft = State(initialValue: story)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("故事") {
          TextField("故事标题", text: $draft.title, axis: .vertical).accessibilityIdentifier(
            "story-title")
          TextField("写一点说明", text: $draft.description, axis: .vertical)
        }
        Section("\(draft.count) 张照片 · 拖动右侧手柄排序") {
          ForEach(draft.mediaIDs, id: \.self) { id in
            if let item = store.item(id) {
              HStack(spacing: 12) {
                SampleImage(item: item).frame(width: 54, height: 54).clipped().clipShape(
                  .rect(cornerRadius: 8))
                VStack(alignment: .leading) {
                  Text(item.title)
                  if draft.coverID == id {
                    Text("封面").font(.caption).foregroundStyle(Color.accentColor)
                  }
                }
                Spacer()
                Menu("操作", systemImage: "ellipsis.circle") {
                  Button("设为封面") { draft.coverID = id }
                  Button("前移") { move(id, delta: -1) }.disabled(draft.mediaIDs.first == id)
                  Button("后移") { move(id, delta: 1) }.disabled(draft.mediaIDs.last == id)
                  Button("移出故事", role: .destructive) {
                    undo = draft
                    draft.remove(id)
                  }
                }.accessibilityIdentifier("actions-\(id)")
              }
            }
          }.onMove { from, to in draft.mediaIDs.move(fromOffsets: from, toOffset: to) }
          if let previous = undo {
            Button("撤销移出照片") {
              draft = previous
              undo = nil
            }
          }
        }
        Section("添加照片") {
          Button("从图库选择", systemImage: "photo.badge.plus") {
            additions = []; addingPhotos = true
          }.disabled(draft.count >= 5_000).accessibilityIdentifier("story-add-photos")
        }
        Text("移出故事只取消关联，不删除媒体。取消编辑不会改变已保存的故事。").font(.footnote)
        if let error = store.error { Text(error).foregroundStyle(.red) }
      }.environment(\.editMode, .constant(.active))
        .disabled(store.saving)
        .onScrollPhaseChange { _, phase in search.setScrolling(phase != .idle) }
        .onDisappear { search.setScrolling(false) }
        .navigationTitle(original.title.isEmpty ? "新建故事" : "编辑故事").navigationBarTitleDisplayMode(
          .inline
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { if draft != original { discard = true } else { dismiss() } }.disabled(
              store.saving)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(store.saving ? "保存中…" : "保存") {
              Task { if await store.saveStory(draft) { dismiss() } }
            }.disabled(
              store.saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ).accessibilityIdentifier("save-story")
          }
        }
        .interactiveDismissDisabled(draft != original || store.saving)
        .onChange(of: draft) { search.userDidInteract() }
        .sheet(isPresented: $addingPhotos) {
          MediaPicker(selection: $additions,
            query: LibraryQuery(excludedIDs: Set(draft.mediaIDs)), maximumItems: 5_000 - draft.count) { ids in
              let existing = Set(draft.mediaIDs)
              draft.mediaIDs.append(contentsOf: ids.filter { !existing.contains($0) })
              draft.normalize(); addingPhotos = false
            }
        }
        .confirmationDialog("放弃未保存的故事修改？", isPresented: $discard, titleVisibility: .visible) {
          Button("放弃修改", role: .destructive) { dismiss() }
        }
    }
  }
  private func move(_ id: String, delta: Int) {
    guard let index = draft.mediaIDs.firstIndex(of: id),
      draft.mediaIDs.indices.contains(index + delta)
    else { return }
    draft.mediaIDs.swapAt(index, index + delta)
  }
}
