import Foundation
import Observation
import Network
import Supabase

@MainActor @Observable final class LiveArchiveController {
  private(set) var document = LiveDocument()
  private(set) var owner = "guest"
  private(set) var loaded = false
  var archiveReady: Bool { session.ready }
  private(set) var syncing = false
  private(set) var mediaUploadEnabled = false
  private(set) var mediaUploadErrors: [String: String] = [:]
  private(set) var mediaUploadProgress = ""
  private(set) var status = "仅在本机整理"
  var error: String?
  let photos = PhotoKitLibrary()
  let account = SupabaseAccount()
  @ObservationIgnored private let repository: LiveArchiveRepository
  @ObservationIgnored private let monitor = NWPathMonitor()
  @ObservationIgnored private var syncID: UUID?
  @ObservationIgnored private var refreshID: UUID?
  @ObservationIgnored private let session = ArchiveSessionGate()
  private var generation: UUID { session.generation }
  @ObservationIgnored private var bootstrapPage: LibraryPage?
  @ObservationIgnored private var publishedRevision = -1
  @ObservationIgnored private var mediaIndex: [String: MediaItem] = [:]
  private(set) var searchRevision = 0
  private(set) var libraryRevision = 0
  @ObservationIgnored private var publishedLibraryRevision = -1
  @ObservationIgnored private var publishedSearchRevision = -1
  private(set) var visibleMedia: [MediaItem] = []

  init(directory: URL) throws {
    repository = try LiveArchiveRepository(directory: directory)
    photos.onChange = { [weak self] in Task { await self?.refreshPhotos() } }
    account.onIdentityChange = { [weak self] in self?.identityChanged() }
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor in self?.requestSync() }
    }
    monitor.start(queue: DispatchQueue(label: "PhotoArchive.network"))
  }

  func load() async {
    PrivacyShare.cleanExpired()
    let identity = account.userID, token = session.beginTransition(identity: account.userID)
    hidePreviousOwner(for: identity)
    syncID = nil; syncing = false; refreshID = nil
    do {
      await session.waitForWrites()
      guard generation == token, account.userID == identity else { return }
      let expected = try await session.resolveOwner { [repository] in try await repository.exists(owner: $0) }
      guard generation == token, account.userID == identity else { return }
      try await prepare(owner: expected, token: token)
      guard generation == token, owner == expected else { return }
      mediaUploadEnabled = UserDefaults.standard.bool(forKey: mediaUploadKey)
      account.observe()
      await refreshPhotos()
    } catch {
      guard generation == token else { return }
      clearPublished()
      self.error = "档案读取失败，原数据已保留：\(error.localizedDescription)"
    }
  }

  /// Publish a bounded first page before decoding the full compatibility model. The
  /// partial document can never enter a write/sync path until session.complete.
  private func prepare(owner expected: String, token: UUID) async throws {
    let initial = try await repository.bootstrap(owner: expected)
    guard generation == token else { return }
    if owner != expected { clearPublished(); owner = expected; photos.cacheNamespace = expected; photos.invalidateSnapshot() }
    document = initial.document; visibleMedia = initial.firstPage.items; mediaIndex = initial.document.media
    bootstrapPage = initial.firstPage
    publishedRevision = -1; publishedLibraryRevision = -1; publishedSearchRevision = -1
    libraryRevision &+= 1; loaded = true; error = nil
    // No gallery query waits behind the full read: libraryPage serves this first
    // page directly while the database hydrates the remaining compatibility data.
    let model = try await repository.read(owner: expected)
    guard generation == token, owner == expected else { return }
    publish(model); _ = session.complete(token)
  }

  private func identityChanged() {
    let identity = account.userID, token = session.beginTransition(identity: account.userID)
    syncID = nil; syncing = false; refreshID = nil
    // Hide the old account immediately; a delayed database response must not reveal it.
    hidePreviousOwner(for: identity)
    Task {
      do {
        await session.waitForWrites()
        guard generation == token, account.userID == identity else { return }
        let target = try await session.resolveOwner { [repository] in try await repository.exists(owner: $0) }
        guard generation == token, account.userID == identity else { return }
        try await prepare(owner: target, token: token)
        guard generation == token, account.userID == identity else { return }
        mediaUploadEnabled = UserDefaults.standard.bool(forKey: mediaUploadKey)
        mediaUploadErrors = [:]; error = nil
        status = document.syncEnabled ? "待同步" : "仅在本机整理"
        await refreshPhotos(); requestSync()
      } catch {
        guard generation == token else { return }
        clearPublished()
        self.error = "账号档案读取失败，已隐藏之前账号的数据：\(error.localizedDescription)"
      }
    }
  }

  private func hidePreviousOwner(for identity: String?) {
    guard owner != "guest", owner != identity else { return }
    clearPublished(); owner = "guest"
    photos.cacheNamespace = "guest"; photos.invalidateSnapshot()
  }

  private func clearPublished() {
    session.close(); bootstrapPage = nil
    loaded = false; document = LiveDocument(); visibleMedia = []; mediaIndex = [:]
    publishedRevision = -1; publishedLibraryRevision = -1; publishedSearchRevision = -1
    libraryRevision &+= 1; searchRevision &+= 1
    mediaUploadEnabled = false; mediaUploadErrors = [:]; mediaUploadProgress = ""
  }
  private func publish(_ model: ArchiveReadModel) {
    // Actor replies may resume UI tasks in a different order than the transactions committed.
    guard model.revision >= publishedRevision else { return }
    bootstrapPage = nil
    document = model.document; publishedRevision = model.revision
    if model.libraryRevision != publishedLibraryRevision {
      visibleMedia = model.visibleMedia; mediaIndex = model.document.media
      publishedLibraryRevision = model.libraryRevision; libraryRevision &+= 1
    }
    if model.searchRevision != publishedSearchRevision {
      publishedSearchRevision = model.searchRevision; searchRevision &+= 1
    }
  }

  /// The repository serializes the synchronous command against its latest state. No UI
  /// snapshot is ever saved after an await. Owner/generation checks isolate delayed replies.
  @discardableResult private func transaction(impact: ArchiveMutationImpact = .library,
      syncToken: UUID? = nil, _ mutation: @escaping @Sendable (inout LiveDocument) throws -> Void) async throws -> ArchiveReadModel {
    let expected = owner, token = try session.enterWrite()
    defer { session.leaveWrite() }
    if let syncToken, !valid(syncToken, owner: expected) { throw CancellationError() }
    let model = try await repository.update(owner: expected, impact: impact, mutation)
    guard token == generation, owner == expected else { throw ArchiveStorageError.identityChanged }
    publish(model)
    return model
  }

  func item(_ id: String) -> MediaItem? { mediaIndex[id] }
  func libraryPage(query: LibraryQuery, cursor: LibraryCursor?, limit: Int = 120) async throws -> LibraryPage {
    let expected = owner, token = generation
    guard loaded else { throw ArchiveStorageError.identityChanged }
    if cursor == nil, query == LibraryQuery(), limit == 120, let bootstrapPage { return bootstrapPage }
    let page = try await repository.page(owner: expected, query: query, cursor: cursor, limit: limit)
    guard token == generation, owner == expected else { throw ArchiveStorageError.identityChanged }
    return page
  }
  func exportCompatibilitySnapshot() async throws -> URL { try await repository.exportCompatibilitySnapshot() }

  func refreshPhotos() async {
    guard archiveReady else { return }
    let token = UUID(), epoch = generation, expected = owner
    refreshID = token
    let previous = document.media
    do {
      let delta = try await photos.readChanges(previous: previous)
      guard refreshID == token, generation == epoch, owner == expected else { photos.invalidateSnapshot(); return }
      guard !delta.upserts.isEmpty || !delta.inaccessibleIDs.isEmpty else { return }
      try await transaction { next in
        // Canonical IDs may have changed while PhotoKit was reading. Resolve by local ID
        // against the latest archive rather than restoring the now-obsolete alias.
        let byLocal = Dictionary(next.media.values.compactMap { item in item.localIdentifier.map { ($0, item.id) } }, uniquingKeysWith: { first, _ in first })
        for id in delta.inaccessibleIDs {
          let current = previous[id]?.localIdentifier.flatMap { byLocal[$0] } ?? id
          next.media[current]?.accessible = false
        }
        for item in delta.upserts {
          let current = item.localIdentifier.flatMap { byLocal[$0] } ?? item.id
          next.media[current] = item.withArchiveID(current)
        }
      }
    } catch is CancellationError { photos.invalidateSnapshot() }
    catch {
      photos.invalidateSnapshot()
      guard refreshID == token, generation == epoch else { return }
      self.error = error.localizedDescription
    }
  }
  func authorize() async { await photos.requestAuthorization(); await refreshPhotos() }
  func foreground() async { guard loaded else { return }; await refreshPhotos(); requestSync() }

  private nonisolated static func ensureReference(_ id: String, in next: inout LiveDocument) {
    guard let media = next.media[id], next.versions["media:\(id)"] == nil,
      !next.outbox.contains(where: { $0.entity == "media" && $0.entityID == id }) else { return }
    next.enqueue(entity: "media", id: id, payload: WirePayload(kind: media.kind == .video ? "video" : "photo", cloudIdentifier: next.cloudIDs[id]))
  }
  func saveStory(_ story: Story) async throws {
    try await transaction(impact: .organization) { next in
      guard !next.conflicts.contains(where: { $0.key == "story:\(story.id)" }) else { throw ArchiveServiceError(message: "这条故事有两个修改版本，请先处理同步冲突。") }
      var story = story; story.normalize()
      for id in story.mediaIDs { Self.ensureReference(id, in: &next) }
      next.snapshot.stories.removeAll { $0.id == story.id }; next.snapshot.stories.append(story)
      next.enqueue(entity: "story", id: story.id, payload: .story(story))
    }
    requestSync()
  }
  func deleteStory(_ id: String) async throws {
    try await transaction(impact: .organization) { next in
      guard !next.conflicts.contains(where: { $0.key == "story:\(id)" }) else { throw ArchiveServiceError(message: "请先处理这条故事的同步冲突。") }
      next.snapshot.stories.removeAll { $0.id == id }
      next.enqueue(entity: "story", id: id, payload: WirePayload(), deleted: true)
    }
    requestSync()
  }
  func saveCorrection(_ correction: MetadataCorrection?, id: String) async throws {
    try await transaction(impact: .organization) { next in
      guard !next.conflicts.contains(where: { $0.key == "correction:\(id)" }) else { throw ArchiveServiceError(message: "这条照片信息有两个修改版本，请先处理同步冲突。") }
      Self.ensureReference(id, in: &next)
      next.snapshot.corrections[id] = correction
      next.enqueue(entity: "correction", id: id, payload: correction.map(WirePayload.correction) ?? WirePayload(), deleted: correction == nil)
    }
    requestSync()
  }

  func enableSync() async {
    guard let id = account.userID else { error = "请先登录邮箱账号。"; return }
    guard archiveReady else { return }
    // Invalidate any previously suspended identity lookup before adopting guest
    // data, then let earlier commands finish before the atomic owner move.
    let token = session.beginTransition(identity: id)
    syncID = nil; syncing = false; refreshID = nil
    await session.waitForWrites()
    guard generation == token, account.userID == id else { return }
    do {
      let model = try await session.withTransitionWrite(token: token) {
        if owner == id { return try await repository.update(owner: id, impact: .metadata) { $0.syncEnabled = true } }
        return try await repository.adoptGuestReadModel(into: id)
      }
      guard generation == token, account.userID == id else { return }
      if owner != id { clearPublished(); owner = id; photos.cacheNamespace = id; photos.invalidateSnapshot() }
      publish(model); loaded = true; _ = session.complete(token)
      mediaUploadEnabled = UserDefaults.standard.bool(forKey: mediaUploadKey); error = nil
      await refreshPhotos(); requestSync()
    } catch {
      guard generation == token else { return }
      _ = session.complete(token)
      self.error = error.localizedDescription
    }
  }
  func disableSync() async {
    disableMediaUpload(); syncID = nil; syncing = false
    do {
      try await transaction(impact: .metadata) { $0.syncEnabled = false }
      status = "同步已暂停，修改继续保存在本机"
    } catch { self.error = error.localizedDescription }
  }
  private var mediaUploadKey: String { "photoarchive.original-upload.\(owner)" }
  func enableMediaUpload() {
    guard archiveReady, owner != "guest", document.syncEnabled, account.userID == owner else { error = "请先登录并开启整理信息同步。"; return }
    mediaUploadEnabled = true; UserDefaults.standard.set(true, forKey: mediaUploadKey)
    mediaUploadErrors = [:]; requestSync()
  }
  func disableMediaUpload() {
    mediaUploadEnabled = false; UserDefaults.standard.removeObject(forKey: mediaUploadKey); mediaUploadProgress = ""
  }
  func cloudMediaURL(for id: String, preview: Bool = false) async throws -> URL? {
    guard let client = account.client, account.userID == owner else { return nil }
    let token = generation, expected = owner
    let url = try await CloudMediaUploader(client: client, accountID: expected).url(for: id, preview: preview)
    guard token == generation, expected == owner else { throw ArchiveStorageError.identityChanged }
    return url
  }

  private func refreshCloudReferences(client: SupabaseClient, token: UUID, expected: String) async throws {
    var rows: [CloudAssetMetadata] = [], offset = 0
    while true {
      let page: [CloudAssetMetadata] = try await client.from("archive_media_assets")
        .select("media_id,display_name,captured_at,latitude,longitude,time_sources,status")
        .range(from: offset, to: offset + 499).execute().value
      guard valid(token, owner: expected) else { return }
      rows.append(contentsOf: page)
      if page.count < 500 { break }; offset += 500
    }
    let received = rows
    try await transaction(syncToken: token) { next in
      for row in received where row.status == "ready" {
        guard let old = next.media[row.mediaID], !old.accessible else { continue }
        let parts = (row.timeSources.first?.value ?? row.capturedAt ?? "").prefix(10).split(separator: "-").compactMap { Int($0) }
        let day = parts.count == 3 ? ArchiveDay(parts[0], parts[1], parts[2]) : nil
        let place: Place? = if let latitude = row.latitude, let longitude = row.longitude { Place(name: "原片坐标", latitude: latitude, longitude: longitude) } else { nil }
        next.media[row.mediaID] = MediaItem(id: old.id, assetName: old.assetName, title: row.displayName,
          kind: old.kind, originalDay: day, originalPlace: place, source: "云端原片",
          localIdentifier: old.localIdentifier, accessible: old.accessible, captureDate: old.captureDate,
          modificationDate: old.modificationDate)
      }
    }
  }

  private func uploadCuratedMedia(client: SupabaseClient, token: UUID, expected: String) async {
    guard mediaUploadEnabled, valid(token, owner: expected) else { return }
    let candidates = Set(document.snapshot.stories.flatMap(\.mediaIDs)).union(document.snapshot.corrections.keys)
    let uploader = CloudMediaUploader(client: client, accountID: expected)
    do {
      var ready = Set<String>(), offset = 0
      while true {
        let page: [CloudAssetLookup] = try await client.from("archive_media_assets").select("media_id,object_path,preview_path,status")
          .range(from: offset, to: offset + 499).execute().value
        guard mediaUploadEnabled, valid(token, owner: expected) else { return }
        ready.formUnion(page.filter { $0.status == "ready" }.map(\.mediaID))
        if page.count < 500 { break }; offset += 500
      }
      let pending = candidates.sorted().filter { !ready.contains($0) }
      mediaUploadErrors = [:]
      for (index, id) in pending.enumerated() {
        guard mediaUploadEnabled, valid(token, owner: expected) else { return }
        guard let item = document.media[id], item.accessible, let asset = photos.asset(item.localIdentifier) else { mediaUploadErrors[id] = "这台设备没有可读取的原片。"; continue }
        mediaUploadProgress = "正在上传原片 \(index + 1) / \(pending.count)"
        do {
          let canonical = try await uploader.upload(item: item, asset: asset)
          guard valid(token, owner: expected) else { return }
          if canonical != id {
            try await transaction(syncToken: token) { next in
              let changed = next.snapshot.stories.filter { $0.mediaIDs.contains(id) }.map(\.id)
              next.remapMedia(from: id, to: canonical)
              for storyID in changed {
                if let story = next.snapshot.stories.first(where: { $0.id == storyID }) { next.enqueue(entity: "story", id: storyID, payload: .story(story)) }
              }
              if let correction = next.snapshot.corrections[canonical] { next.enqueue(entity: "correction", id: canonical, payload: .correction(correction)) }
            }
          }
        } catch {
          guard valid(token, owner: expected) else { return }
          mediaUploadErrors[id] = error.localizedDescription
        }
      }
      guard valid(token, owner: expected) else { return }
      mediaUploadProgress = ""
      status = mediaUploadErrors.isEmpty ? "同步完成（已上传选中原片）" : "整理已同步，部分原片未上传"
    } catch {
      guard valid(token, owner: expected) else { return }
      self.error = "原片状态读取失败：\(error.localizedDescription)"
    }
  }
  func signOut() async {
    do { try await account.signOut() } catch { self.error = error.localizedDescription }
  }
  func deleteAccount() async {
    guard let id = account.userID else { return }
    syncID = nil; syncing = false
    do {
      try await account.deleteAccount()
      try await repository.remove(owner: id)
    } catch { self.error = "账号删除未完成：\(error.localizedDescription)" }
  }
  func requestSync() {
    guard archiveReady, document.syncEnabled, account.userID == owner, !syncing else { return }
    Task { await synchronize() }
  }
  private func valid(_ token: UUID, owner expected: String) -> Bool {
    syncID == token && owner == expected && account.userID == expected
  }
  func synchronize() async {
    guard archiveReady, document.syncEnabled, let client = account.client, account.userID == owner, !syncing else { return }
    let token = UUID(), expected = owner
    syncID = token; syncing = true; status = "同步中"; error = nil
    var completed = false
    defer {
      if syncID == token {
        syncing = false; syncID = nil
        if completed && document.outbox.contains(where: { operation in operation.resolving != nil || !document.conflicts.contains(where: { $0.key == operation.key }) }) { requestSync() }
      }
    }
    let transport = SupabaseArchiveTransport(client: client)
    do {
      var more = true
      while more {
        let page = try await transport.pull(after: document.cursor)
        guard valid(token, owner: expected), document.syncEnabled else { return }
        try await transaction(syncToken: token) { next in
          for change in page.changes { next.apply(change.record) }
          next.cursor = page.cursor; next.conflicts = page.conflicts
        }
        more = page.hasMore
      }
      var checkedMedia = Set<String>()
      while document.syncEnabled {
        guard valid(token, owner: expected) else { return }
        let unmapped = document.outbox.filter { $0.entity == "media" && !$0.attempted }
          .compactMap { document.media[$0.entityID]?.localIdentifier }.filter { !checkedMedia.contains($0) }
        if !unmapped.isEmpty {
          let mappings = await photos.cloudMappings(unmapped)
          guard valid(token, owner: expected), document.syncEnabled else { return }
          checkedMedia.formUnion(unmapped)
          try await transaction(impact: .metadata, syncToken: token) { next in
            for i in next.outbox.indices where next.outbox[i].entity == "media" && !next.outbox[i].attempted {
              let id = next.outbox[i].entityID
              if let local = next.media[id]?.localIdentifier, let cloud = mappings[local] {
                next.cloudIDs[id] = cloud; next.outbox[i].payload.cloudIdentifier = cloud
              }
            }
          }
        }
        let eligible = document.outbox.filter { operation in operation.resolving != nil || !document.conflicts.contains(where: { $0.key == operation.key }) }
        guard let selected = eligible.first(where: { $0.entity == "media" }) ?? eligible.first else { break }
        let operationID = selected.id
        let marked = try await transaction(impact: .metadata, syncToken: token) { next in
          guard let i = next.outbox.firstIndex(where: { $0.id == operationID }) else { throw CancellationError() }
          next.outbox[i].attempted = true
        }
        guard valid(token, owner: expected), let operation = marked.document.outbox.first(where: { $0.id == operationID }) else { return }
        let result = try await transport.push(operation.wire)
        guard valid(token, owner: expected) else { return }
        try await transaction(syncToken: token) { next in
          if operation.entity == "media", result.status == "canonical", result.record.id != operation.entityID { next.remapMedia(from: operation.entityID, to: result.record.id) }
          next.accept(result, operationID: operation.id)
        }
      }
      guard document.syncEnabled, valid(token, owner: expected) else { return }
      let cloudIDs = document.cloudIDs
      let identifiers = await Task.detached(priority: .utility) { Array(Set(cloudIDs.values)) }.value
      let mappings = await photos.localMappings(identifiers)
      guard valid(token, owner: expected), document.syncEnabled else { return }
      try await transaction(syncToken: token) { next in
        var localIndex = Dictionary(next.media.values.compactMap { item in item.localIdentifier.map { ($0, item.id) } }, uniquingKeysWith: { first, _ in first })
        let organized = Set(next.snapshot.stories.flatMap(\.mediaIDs)).union(next.snapshot.corrections.keys)
        for (id, cloud) in next.cloudIDs {
          if let local = mappings[cloud], next.media[id]?.localIdentifier == nil {
            if let old = localIndex[local], old != id, !organized.contains(old) { next.media.removeValue(forKey: old) }
            next.media[id]?.localIdentifier = local; localIndex[local] = id
          }
        }
        next.lastSync = .now
      }
      status = document.conflicts.isEmpty ? (document.outbox.isEmpty ? "同步完成（不含照片备份）" : "待同步") : "有 \(document.conflicts.count) 项冲突待处理"
      await refreshPhotos()
      try await refreshCloudReferences(client: client, token: token, expected: expected)
      await uploadCuratedMedia(client: client, token: token, expected: expected)
      completed = true
    } catch {
      guard valid(token, owner: expected) else { return }
      status = "同步失败，修改已保存在本机"; self.error = error.localizedDescription
    }
  }
  func resolve(_ conflict: SyncConflict, keepLocal: Bool) async {
    do {
      try await transaction(impact: .metadata) { next in
        guard next.conflicts.contains(where: { $0.id == conflict.id }) else { return }
        let selected = keepLocal ? conflict.local : conflict.remote
        let latest = keepLocal ? next.outbox.last(where: { $0.key == conflict.key }) : nil
        next.outbox.removeAll { $0.key == conflict.key }
        next.enqueue(entity: selected.entity, id: selected.id, payload: latest?.payload ?? selected.payload,
          deleted: latest?.deleted ?? selected.deleted, resolving: conflict.id)
        next.outbox[next.outbox.count - 1].baseVersion = conflict.remote.version
      }
      requestSync()
    } catch { self.error = error.localizedDescription }
  }
  func associate(id: String, with selected: MediaItem) async {
    guard let local = selected.localIdentifier else { return }
    do {
      try await transaction { next in
        let organized = next.snapshot.stories.contains { $0.mediaIDs.contains(selected.id) } || next.snapshot.corrections[selected.id] != nil
        guard selected.id == id || !organized else { throw ArchiveServiceError(message: "这张照片已关联其他档案，请选择另一张照片。") }
        next.media[id] = MediaItem(id: id, assetName: "", title: selected.title, kind: selected.kind,
          originalDay: selected.originalDay, originalPlace: selected.originalPlace, source: "手动关联系统照片",
          localIdentifier: local, accessible: true, captureDate: selected.captureDate, modificationDate: selected.modificationDate)
        if selected.id != id { next.media.removeValue(forKey: selected.id) }
      }
    } catch { self.error = error.localizedDescription }
  }
}

private extension MediaItem {
  func withArchiveID(_ id: String) -> MediaItem {
    MediaItem(id: id, assetName: assetName, title: title, kind: kind, originalDay: originalDay,
      originalPlace: originalPlace, source: source, localIdentifier: localIdentifier, accessible: accessible,
      captureDate: captureDate, modificationDate: modificationDate)
  }
}
extension LiveDocument {
  mutating func remapMedia(from old: String, to canonical: String) {
    if let item = media.removeValue(forKey: old), media[canonical]?.localIdentifier == nil {
      media[canonical] = MediaItem(id: canonical, assetName: item.assetName, title: item.title, kind: item.kind,
        originalDay: item.originalDay, originalPlace: item.originalPlace, source: item.source,
        localIdentifier: item.localIdentifier, accessible: item.accessible, captureDate: item.captureDate, modificationDate: item.modificationDate)
    }
    cloudIDs[canonical] = cloudIDs.removeValue(forKey: old) ?? cloudIDs[canonical]
    for index in snapshot.stories.indices {
      snapshot.stories[index].mediaIDs = snapshot.stories[index].mediaIDs.map { $0 == old ? canonical : $0 }
      if snapshot.stories[index].coverID == old { snapshot.stories[index].coverID = canonical }
      snapshot.stories[index].normalize()
    }
    if let correction = snapshot.corrections.removeValue(forKey: old) {
      snapshot.corrections[canonical] = MetadataCorrection(mediaID: canonical, originalDay: correction.originalDay,
        originalPlace: correction.originalPlace, day: correction.day, place: correction.place,
        description: correction.description, dayMode: correction.dayMode, placeMode: correction.placeMode)
    }
    for index in outbox.indices where !outbox[index].attempted {
      if outbox[index].entity == "story" {
        outbox[index].payload.mediaIDs = outbox[index].payload.mediaIDs?.map { $0 == old ? canonical : $0 }
        if outbox[index].payload.coverID == old { outbox[index].payload.coverID = canonical }
      } else if outbox[index].entity == "correction", outbox[index].entityID == old {
        outbox[index].entityID = canonical
      }
    }
  }
}
