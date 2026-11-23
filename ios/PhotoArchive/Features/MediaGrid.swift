import SwiftUI
import UIKit
import Observation

/// Shared by the grid and detail pager so opening photo 120 does not end browsing.
@MainActor @Observable final class LibraryNavigationContext {
  typealias PageLoader = @MainActor (LibraryQuery, LibraryCursor?, Int) async throws -> LibraryPage
  private(set) var items: [MediaItem] = []
  private(set) var effectiveDays: [String: ArchiveDay] = [:]
  private(set) var years: [Int] = []
  private(set) var totalCount = 0
  private(set) var nextCursor: LibraryCursor?
  private(set) var hasMore = true
  private(set) var loading = false
  private(set) var error: String?
  let query: LibraryQuery
  let owner: String
  @ObservationIgnored private let currentOwner: @MainActor () -> String
  @ObservationIgnored private let readPage: PageLoader
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var pageTask: Task<Void, Never>?
  var mediaIDs: [String] { items.map(\.id) }

  convenience init(store: ArchiveStore, query: LibraryQuery = LibraryQuery()) {
    self.init(query: query, currentOwner: { store.live?.owner ?? "demo" }, readPage: {
      try await store.libraryPage(query: $0, cursor: $1, limit: $2)
    })
  }
  init(query: LibraryQuery = LibraryQuery(), currentOwner: @escaping @MainActor () -> String,
       readPage: @escaping PageLoader) {
    self.query = query; self.owner = currentOwner()
    self.currentOwner = currentOwner; self.readPage = readPage
  }
  func item(_ id: String) -> MediaItem? { items.first { $0.id == id } }

  func loadNext() async {
    guard owner == currentOwner() else { clearStaleOwner(); return }
    // The context owns this task. A detail view's task changes with each swipe,
    // but cancelling one caller must not discard the shared next page.
    if let pageTask { await pageTask.value; return }
    guard hasMore else { return }
    let token = generation
    loading = true
    let task = Task { await self.appendNextPage(token: token) }
    pageTask = task
    await task.value
  }
  private func appendNextPage(token: UUID) async {
    defer { finish(token: token) }
    do {
      let page = try await readPage(query, nextCursor, 120)
      try Task.checkCancellation()
      guard accepts(token: token) else { return }
      let existing = Set(items.map(\.id))
      items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
      effectiveDays.merge(page.effectiveDays) { _, new in new }
      years = page.years; totalCount = page.totalCount
      nextCursor = page.nextCursor; hasMore = page.nextCursor != nil; error = nil
    } catch is CancellationError { }
    catch ArchiveStorageError.staleCursor {
      guard !Task.isCancelled, accepts(token: token) else { return }
      // Refresh inside the current shared task; public reload would replace it,
      // while calling loadNext here would wait for this same task forever.
      await refreshPages(token: token)
    }
    catch { if accepts(token: token) { self.error = error.localizedDescription } }
  }
  /// Keep the previous window visible until its replacement is ready. Stable IDs
  /// let UICollectionView preserve the visible anchor and selection.
  func reload() async {
    guard owner == currentOwner() else { clearStaleOwner(); return }
    pageTask?.cancel()
    let token = UUID(); generation = token; loading = true
    let task = Task {
      await self.refreshPages(token: token)
      self.finish(token: token)
    }
    pageTask = task
    await task.value
  }
  private func refreshPages(token: UUID) async {
    let targetCount = max(120, items.count)
    do {
      var refreshed: [MediaItem] = [], days: [String: ArchiveDay] = [:]
      var cursor: LibraryCursor?, availableYears: [Int] = [], count = 0
      repeat {
        let page = try await readPage(query, cursor, 120)
        try Task.checkCancellation()
        guard accepts(token: token) else { return }
        refreshed.append(contentsOf: page.items); days.merge(page.effectiveDays) { _, new in new }
        cursor = page.nextCursor; count = page.totalCount; availableYears = page.years
      } while cursor != nil && refreshed.count < targetCount
      items = refreshed; effectiveDays = days; nextCursor = cursor; hasMore = cursor != nil
      years = availableYears; totalCount = count; error = nil
    } catch is CancellationError { }
    catch { if accepts(token: token) { self.error = error.localizedDescription } }
  }
  private func accepts(token: UUID) -> Bool {
    guard generation == token else { return false }
    guard owner == currentOwner() else { clearStaleOwner(); return false }
    return true
  }
  private func finish(token: UUID) {
    guard generation == token else { return }
    pageTask = nil; loading = false
  }
  private func clearStaleOwner() {
    generation = UUID(); pageTask?.cancel(); pageTask = nil
    items = []; effectiveDays = [:]; nextCursor = nil; hasMore = false; loading = false; error = nil
  }
}

/// A reusable, independently scrolling photo surface. Callers own navigation and selection.
struct MediaGrid: UIViewRepresentable {
  var items: [MediaItem]
  var effectiveDays: [String: ArchiveDay]? = nil
  @Binding var selection: Set<String>
  var selecting = false
  var library: PhotoKitLibrary?
  var remoteURL: ((String) async throws -> URL?)?
  var groupByDate = true
  var sectionTitle: String? = nil
  var onOpen: (MediaItem) -> Void
  var onLoadMore: () -> Void = {}
  var onInteraction: () -> Void = {}
  var onScrolling: (Bool) -> Void = { _ in }
  @Environment(\.dynamicTypeSize) private var typeSize
  init(items: [MediaItem], effectiveDays: [String: ArchiveDay]? = nil, selection: Binding<Set<String>> = .constant([]), selecting: Bool = false,
       library: PhotoKitLibrary? = nil, remoteURL: ((String) async throws -> URL?)? = nil,
       groupByDate: Bool = true, sectionTitle: String? = nil,
       onOpen: @escaping (MediaItem) -> Void, onLoadMore: @escaping () -> Void = {},
       onInteraction: @escaping () -> Void = {}, onScrolling: @escaping (Bool) -> Void = { _ in }) {
    self.items = items; self.effectiveDays = effectiveDays; _selection = selection; self.selecting = selecting
    self.library = library; self.remoteURL = remoteURL; self.groupByDate = groupByDate; self.sectionTitle = sectionTitle
    self.onOpen = onOpen; self.onLoadMore = onLoadMore; self.onInteraction = onInteraction; self.onScrolling = onScrolling
  }
  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
  func makeUIView(context: Context) -> UICollectionView {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 2; layout.minimumLineSpacing = 2
    let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collection.accessibilityIdentifier = "media-grid"
    collection.backgroundColor = .systemBackground
    collection.alwaysBounceVertical = true
    collection.contentInset.bottom = 12
    collection.register(MediaCell.self, forCellWithReuseIdentifier: "media")
    collection.register(MediaHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
    collection.delegate = context.coordinator; collection.prefetchDataSource = context.coordinator
    context.coordinator.connect(collection)
    return collection
  }
  func updateUIView(_ collection: UICollectionView, context: Context) {
    context.coordinator.update(self, columns: typeSize.isAccessibilitySize ? 2 : 3)
  }
  static func dismantleUIView(_ collection: UICollectionView, coordinator: Coordinator) {
    coordinator.releaseImages()
    coordinator.parent.onScrolling(false)
    collection.delegate = nil; collection.prefetchDataSource = nil
  }
  @MainActor final class Coordinator: NSObject, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
    var parent: MediaGrid
    weak var collection: UICollectionView?
    private var source: UICollectionViewDiffableDataSource<String, String>!
    private var indexed: [String: MediaItem] = [:]
    private var previousItems: [MediaItem] = []
    private var previousDays: [String: ArchiveDay]?
    private var previousSelection = Set<String>()
    private var previousSelecting = false
    private var previousGrouping = true
    private var previousTitle: String?
    private var previousNamespace = ""
    private var headerTitles: [String: String] = [:]
    private var orderedIDs: [String] = []
    private var indexByID: [String: Int] = [:]
    private var columns = 3
    private var contentSizeCategory: UIContentSizeCategory?
    private let preheatID = UUID()
    private var previousPreheatIDs: [String] = []
    private var previousPixels = CGSize.zero
    init(parent: MediaGrid) { self.parent = parent }
    func connect(_ collection: UICollectionView) {
      self.collection = collection
      source = UICollectionViewDiffableDataSource<String, String>(collectionView: collection) { [weak self] collection, indexPath, id in
        guard let self, let item = self.indexed[id], let cell = collection.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as? MediaCell else { return nil }
        self.configure(cell, item: item)
        return cell
      }
      source.supplementaryViewProvider = { [weak self] collection, kind, indexPath in
        guard let self, let header = collection.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as? MediaHeader,
              let section = self.source.snapshot().sectionIdentifiers[safe: indexPath.section] else { return nil }
        header.label.text = self.headerTitles[section]
        header.label.accessibilityIdentifier = "media-date-" + section
        return header
      }
    }
    private var pixels: CGSize {
      let width = max(1, ((collection?.bounds.width ?? 390) - CGFloat(columns - 1) * 2) / CGFloat(columns))
      let scale = collection?.traitCollection.displayScale ?? 1
      return CGSize(width: ceil(width * max(1, scale)), height: ceil(width * max(1, scale)))
    }
    private func configure(_ cell: MediaCell, item: MediaItem) {
      cell.configure(item: item, selected: parent.selection.contains(item.id), selecting: parent.selecting,
                     pixels: pixels, namespace: parent.library?.cacheNamespace ?? "demo", demo: parent.library == nil, remoteURL: parent.remoteURL)
    }
    func update(_ parent: MediaGrid, columns: Int) {
      self.parent = parent
      guard let collection else { return }
      let category = collection.traitCollection.preferredContentSizeCategory
      let layoutChanged = self.columns != columns || contentSizeCategory != category
      if layoutChanged { self.columns = columns; contentSizeCategory = category; collection.collectionViewLayout.invalidateLayout() }
      let namespace = parent.library?.cacheNamespace ?? "demo"
      let changed = previousItems != parent.items || previousDays != parent.effectiveDays || previousGrouping != parent.groupByDate || previousTitle != parent.sectionTitle || previousNamespace != namespace
      if changed {
        let anchor = collection.indexPathsForVisibleItems.sorted().first.flatMap { source.itemIdentifier(for: $0) }
        let anchorY = anchor.flatMap { source.indexPath(for: $0) }.flatMap { collection.layoutAttributesForItem(at: $0)?.frame.minY }
        let offset = anchorY.map { collection.contentOffset.y - $0 }
        let oldIDs = Set(orderedIDs)
        if orderedIDs.isEmpty && parent.library != nil { MediaPipeline.shared.prepareAssets(Array(parent.items.prefix(columns * 18))) }
        indexed = Dictionary(parent.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        orderedIDs = parent.items.map(\.id)
        indexByID = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        headerTitles = [:]
        var sections: [String] = [], groups: [String: [String]] = [:]
        for item in parent.items {
          let day = parent.effectiveDays == nil ? item.originalDay : parent.effectiveDays?[item.id]
          let section = parent.groupByDate ? day.map { "\($0.year)-\($0.month)-\($0.day)" } ?? "undated" : "all"
          if groups[section] == nil { sections.append(section); groups[section] = [] }
          groups[section, default: []].append(item.id)
          headerTitles[section] = parent.groupByDate ? day?.label ?? "日期待确认" : parent.sectionTitle
        }
        for section in sections { snapshot.appendSections([section]); snapshot.appendItems(groups[section] ?? [], toSection: section) }
        // Only changed existing values require reconfiguration. Appended pages do not reload old images.
        let before = Dictionary(previousItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let updates = parent.items.filter { oldIDs.contains($0.id) && (before[$0.id] != $0 || previousNamespace != namespace) }.map(\.id)
        if !updates.isEmpty { snapshot.reconfigureItems(updates) }
        previousItems = parent.items; previousDays = parent.effectiveDays
        previousGrouping = parent.groupByDate; previousTitle = parent.sectionTitle; previousNamespace = namespace
        source.apply(snapshot, animatingDifferences: false) { [weak self, weak collection] in
          guard let self, let collection else { return }
          if let anchor, let offset, let path = self.source.indexPath(for: anchor), let frame = collection.layoutAttributesForItem(at: path)?.frame {
            collection.setContentOffset(CGPoint(x: 0, y: max(-collection.adjustedContentInset.top, frame.minY + offset)), animated: false)
          }
          self.updatePreheat()
        }
      }
      if previousSelection != parent.selection || previousSelecting != parent.selecting || layoutChanged {
        let updateAll = previousSelecting != parent.selecting || layoutChanged
        let changedSelection = previousSelection.symmetricDifference(parent.selection)
        for cell in collection.visibleCells.compactMap({ $0 as? MediaCell }) {
          if let id = cell.mediaID, updateAll || changedSelection.contains(id), let item = indexed[id] {
            configure(cell, item: item)
          }
        }
      }
      previousSelection = parent.selection; previousSelecting = parent.selecting
    }
    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
      let width = floor((collectionView.bounds.width - CGFloat(columns - 1) * 2) / CGFloat(columns))
      return CGSize(width: width, height: width)
    }
    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
      guard parent.groupByDate || parent.sectionTitle != nil,
        let key = source.snapshot().sectionIdentifiers[safe: section] else { return .zero }
      let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: collectionView.traitCollection)
      let text = headerTitles[key] ?? ""
      let bounds = (text as NSString).boundingRect(with: CGSize(width: max(1, collectionView.bounds.width - 32), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
      return CGSize(width: collectionView.bounds.width, height: max(42, ceil(bounds.height) + 16))
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
      if let id = source.itemIdentifier(for: indexPath), let item = indexed[id], let cell = cell as? MediaCell { configure(cell, item: item) }
      if let id = source.itemIdentifier(for: indexPath), let index = indexByID[id], index >= orderedIDs.count - 24 { parent.onLoadMore() }
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? MediaCell)?.releaseImage() }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      guard let id = source.itemIdentifier(for: indexPath), let item = indexed[id] else { return }
      parent.onInteraction()
      if parent.selecting {
        var selection = parent.selection
        if !selection.insert(id).inserted { selection.remove(id) }
        parent.selection = selection
      } else { parent.onOpen(item) }
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) { updatePreheat() }
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) { updatePreheat() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.onInteraction(); parent.onScrolling(true) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updatePreheat() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { parent.onScrolling(false) } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { parent.onScrolling(false) }
    func releaseImages() {
      collection?.visibleCells.compactMap { $0 as? MediaCell }.forEach { $0.releaseImage() }
      MediaPipeline.shared.stopPreheating(preheatID); previousPreheatIDs = []
    }
    private func updatePreheat() {
      guard let collection, !orderedIDs.isEmpty else { return }
      let visible = collection.indexPathsForVisibleItems.compactMap { source.itemIdentifier(for: $0) }.compactMap { indexByID[$0] }
      guard let first = visible.min(), let last = visible.max() else { return }
      let screen = max(columns * 4, last - first + 1)
      let ids = Array(orderedIDs[max(0, first - screen)...min(orderedIDs.count - 1, last + screen)])
      let size = pixels
      guard ids != previousPreheatIDs || size != previousPixels else { return }
      previousPreheatIDs = ids; previousPixels = size
      if parent.library != nil {
        MediaPipeline.shared.preheat(items: ids.compactMap { indexed[$0] }, pixels: size, namespace: parent.library?.cacheNamespace ?? "guest", consumer: preheatID)
      }
    }
  }
}

@MainActor private final class MediaCell: UICollectionViewCell {
  private let imageView = UIImageView()
  private let marker = UIImageView()
  private let video = UIImageView(image: UIImage(systemName: "video.fill"))
  private var ticket: MediaPipeline.Ticket?
  private var representation: MediaImageKey?
  private(set) var mediaID: String?
  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = .secondarySystemBackground
    imageView.contentMode = .scaleAspectFill; imageView.clipsToBounds = true
    marker.tintColor = .systemBlue; marker.contentMode = .scaleAspectFit
    marker.layer.shadowColor = UIColor.black.cgColor; marker.layer.shadowOpacity = 0.3; marker.layer.shadowRadius = 2
    video.tintColor = .white; video.contentMode = .scaleAspectFit
    for view in [imageView, marker, video] { contentView.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor), imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      marker.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7), marker.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
      marker.widthAnchor.constraint(equalToConstant: 26), marker.heightAnchor.constraint(equalToConstant: 26),
      video.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), video.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
      video.widthAnchor.constraint(equalToConstant: 18), video.heightAnchor.constraint(equalToConstant: 18)
    ])
    isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func prepareForReuse() { super.prepareForReuse(); releaseImage(); mediaID = nil }
  func configure(item: MediaItem, selected: Bool, selecting: Bool, pixels: CGSize, namespace: String, demo: Bool, remoteURL: ((String) async throws -> URL?)?) {
    mediaID = item.id
    marker.isHidden = !selecting
    marker.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
    marker.tintColor = selected ? .systemBlue : .white
    video.isHidden = item.kind != .video
    accessibilityIdentifier = (selecting ? "select-" : "photo-") + item.id
    accessibilityLabel = item.title + (selecting ? selected ? "，已选择" : "，未选择" : "")
    accessibilityTraits = selected ? [.button, .selected] : [.button]
    let key = MediaImageKey(item: item, pixels: pixels, namespace: namespace)
    guard representation != key else { return }
    releaseImage(); representation = key
    if demo { imageView.image = UIImage(named: item.assetName); return }
    ticket = MediaPipeline.shared.thumbnail(item: item, pixels: pixels, namespace: namespace, remoteURL: remoteURL) { [weak self] image in
      guard let self, self.representation == key else { return }
      if let image { self.imageView.image = image }
    }
  }
  func releaseImage() { MediaPipeline.shared.cancel(ticket); ticket = nil; representation = nil; imageView.image = nil }
}

@MainActor private final class MediaHeader: UICollectionReusableView {
  let label = UILabel()
  override init(frame: CGRect) {
    super.init(frame: frame)
    label.font = .preferredFont(forTextStyle: .subheadline); label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.textColor = .secondaryLabel; label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    label.accessibilityTraits = .header
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
