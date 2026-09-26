import Foundation
import Observation
import Network
import Supabase

@MainActor @Observable final class LiveArchiveController {
  private(set) var document = LiveDocument()
  private(set) var owner = "guest"
  private(set) var loaded = false
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
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var mediaIndex: [String: MediaItem] = [:]
  private(set) var searchRevision = 0
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
    do {
      document = try repository.load(owner: owner)
      mediaUploadEnabled = UserDefaults.standard.bool(forKey: mediaUploadKey)
      loaded = true; rebuildIndex(); error = nil
      account.observe()
      await refreshPhotos()
    } catch { self.error = "档案读取失败，原数据已保留：\(error.localizedDescription)" }
  }
  private func identityChanged() {
    // Signing in alone never adopts guest content or enables network sync.
    let newOwner: String
    if let id = account.userID, (try? repository.exists(owner: id)) == true { newOwner = id }
    else if let id = account.userID, owner == id { newOwner = id }
    else { newOwner = "guest" }
    guard owner != newOwner else { requestSync(); return }
    syncID = nil; syncing = false; refreshID = nil
    do {
      let next = try repository.load(owner: newOwner)
      owner = newOwner; document = next; mediaUploadEnabled = UserDefaults.standard.bool(forKey: mediaUploadKey)
      mediaUploadErrors = [:]; rebuildIndex()
      status = document.syncEnabled ? "待同步" : "仅在本机整理"
      Task { await refreshPhotos(); requestSync() }
    } catch {
      owner = newOwner; document = LiveDocument(); loaded = false; mediaUploadEnabled = false; mediaUploadErrors = [:]; rebuildIndex()
      self.error = "账号档案读取失败，已隐藏之前账号的数据：\(error.localizedDescription)"
    }
  }
  private func persist(_ next: LiveDocument) throws {
    try repository.save(next, owner: owner)
    document = next
    revision += 1
    rebuildIndex()
  }
  private func rebuildIndex() {
    searchRevision &+= 1
    mediaIndex = document.media
    visibleMedia = document.media.values.filter { $0.accessible || (owner != "guest" && document.syncEnabled) }.sorted {
      let lhs = $0.originalDay ?? ArchiveDay(0, 0, 0), rhs = $1.originalDay ?? ArchiveDay(0, 0, 0)
      return lhs == rhs ? $0.id < $1.id : lhs > rhs
    }
  }
  func item(_ id: String) -> MediaItem? { mediaIndex[id] }
  func refreshPhotos() async {
    guard loaded else { return }
    let token = UUID(); refreshID = token
    let capturedOwner = owner
    let capturedRevision = revision
    let result = await photos.read(previous: document.media)
    guard refreshID == token, owner == capturedOwner else { return }
    if capturedRevision != revision { await refreshPhotos(); return }
    var next = document
    for id in next.media.keys { next.media[id]?.accessible = false }
    for item in result { next.media[item.id] = item }
    // Foreground and PhotoKit notifications often describe the same library.
    // Avoid rewriting the archive and invalidating every photo view in that case.
    guard next.media != document.media else { return }
    do { try persist(next) } catch { self.error = error.localizedDescription }
  }
  func authorize() async { await photos.requestAuthorization(); await refreshPhotos() }
  func foreground() async { guard loaded else { return }; await refreshPhotos(); requestSync() }

  private func ensureReference(_ id: String, in next: inout LiveDocument) {
    guard let media = next.media[id], next.versions["media:\(id)"] == nil,
      !next.outbox.contains(where: { $0.entity == "media" && $0.entityID == id }) else { return }
    next.enqueue(entity: "media", id: id, payload: WirePayload(kind: media.kind == .video ? "video" : "photo", cloudIdentifier: next.cloudIDs[id]))
  }
  func saveStory(_ story: Story) throws {
    guard !document.conflicts.contains(where: { $0.key == "story:\(story.id)" }) else {
      throw ArchiveServiceError(message: "这条故事有两个修改版本，请先处理同步冲突。")
    }
    var next = document
    var story = story; story.normalize()
    for id in story.mediaIDs { ensureReference(id, in: &next) }
    next.snapshot.stories.removeAll { $0.id == story.id }; next.snapshot.stories.append(story)
    next.enqueue(entity: "story", id: story.id, payload: .story(story))
    try persist(next); requestSync()
  }
  func deleteStory(_ id: String) throws {
    guard !document.conflicts.contains(where: { $0.key == "story:\(id)" }) else { throw ArchiveServiceError(message: "请先处理这条故事的同步冲突。") }
    var next = document
    next.snapshot.stories.removeAll { $0.id == id }
    next.enqueue(entity: "story", id: id, payload: WirePayload(), deleted: true)
    try persist(next); requestSync()
  }
  func saveCorrection(_ correction: MetadataCorrection?, id: String) throws {
    guard !document.conflicts.contains(where: { $0.key == "correction:\(id)" }) else {
      throw ArchiveServiceError(message: "这条照片信息有两个修改版本，请先处理同步冲突。")
    }
    var next = document
    ensureReference(id, in: &next)
    next.snapshot.corrections[id] = correction
    next.enqueue(entity: "correction", id: id, payload: correction.map(WirePayload.correction) ?? WirePayload(), deleted: correction == nil)
    try persist(next); requestSync()
  }
  func enableSync() async {
    guard let id = account.userID else { error = "请先登录邮箱账号。"; return }
    syncID = nil; syncing = false; refreshID = nil
    do {
      var next: LiveDocument
      if owner == id {
        next = document; next.syncEnabled = true; try repository.save(next, owner: id)
      } else { next = try repository.adoptGuest(into: id) }
      owner = id; document = next; mediaUploadEnabled = UserDefaults.standard.bool(forKey: mediaUploadKey); rebuildIndex(); error = nil
      await refreshPhotos(); requestSync()
    } catch { self.error = error.localizedDescription }
  }
  func disableSync() {
    disableMediaUpload()
    var next = document; next.syncEnabled = false
    do { try persist(next); status = "同步已暂停，修改继续保存在本机" }
    catch { self.error = error.localizedDescription }
  }
  private var mediaUploadKey: String { "photoarchive.original-upload.\(owner)" }
  func enableMediaUpload() {
    guard owner != "guest", document.syncEnabled, account.userID == owner else {
      error = "请先登录并开启整理信息同步。"; return
    }
    mediaUploadEnabled = true
    UserDefaults.standard.set(true, forKey: mediaUploadKey)
    mediaUploadErrors = [:]
    requestSync()
  }
  func disableMediaUpload() {
    mediaUploadEnabled = false
    UserDefaults.standard.removeObject(forKey: mediaUploadKey)
    mediaUploadProgress = ""
  }
  func cloudMediaURL(for id: String, preview: Bool = false) async throws -> URL? {
    guard let client = account.client, account.userID == owner else { return nil }
    return try await CloudMediaUploader(client: client, accountID: owner).url(for: id, preview: preview)
  }
  private func refreshCloudReferences(client: SupabaseClient, token: UUID, expected: String) async throws {
    var rows: [CloudAssetMetadata] = []
    var offset = 0
    while true {
      let page: [CloudAssetMetadata] = try await client.from("archive_media_assets")
        .select("media_id,display_name,captured_at,latitude,longitude,time_sources,status")
        .range(from: offset, to: offset + 499).execute().value
      guard valid(token, owner: expected) else { return }
      rows.append(contentsOf: page)
      if page.count < 500 { break }
      offset += 500
    }
    var next = document
    for row in rows where row.status == "ready" {
      guard let old = next.media[row.mediaID], !old.accessible else { continue }
      let rawDay = (row.timeSources.first?.value ?? row.capturedAt ?? "").prefix(10)
      let parts = rawDay.split(separator: "-").compactMap { Int($0) }
      let day = parts.count == 3 ? ArchiveDay(parts[0], parts[1], parts[2]) : nil
      let place: Place? = if let latitude = row.latitude, let longitude = row.longitude {
        Place(name: "原片坐标", latitude: latitude, longitude: longitude)
      } else { nil }
      next.media[row.mediaID] = MediaItem(id: old.id, assetName: old.assetName,
        title: row.displayName, kind: old.kind, originalDay: day, originalPlace: place,
        source: "云端原片", localIdentifier: old.localIdentifier, accessible: old.accessible,
        captureDate: old.captureDate)
    }
    if next.media != document.media { try persist(next) }
  }
  private func uploadCuratedMedia(client: SupabaseClient, token: UUID, expected: String) async {
    guard mediaUploadEnabled, valid(token, owner: expected) else { return }
    let candidates = Set(document.snapshot.stories.flatMap(\.mediaIDs)).union(document.snapshot.corrections.keys)
    let uploader = CloudMediaUploader(client: client, accountID: expected)
    let remote: [CloudAssetLookup]
    do {
      remote = try await client.from("archive_media_assets").select("media_id,object_path,preview_path,status").execute().value
    } catch { self.error = "原片状态读取失败：\(error.localizedDescription)"; return }
    let ready = Set(remote.filter { $0.status == "ready" }.map(\.mediaID))
    let pending = candidates.sorted().filter { !ready.contains($0) }
    mediaUploadErrors = [:]
    for (index, id) in pending.enumerated() {
      guard mediaUploadEnabled, valid(token, owner: expected) else { return }
      guard let item = document.media[id], item.accessible,
        let asset = photos.asset(item.localIdentifier) else {
        mediaUploadErrors[id] = "这台设备没有可读取的原片。"; continue
      }
      mediaUploadProgress = "正在上传原片 \(index + 1) / \(pending.count)"
      do {
        let canonical = try await uploader.upload(item: item, asset: asset)
        guard valid(token, owner: expected) else { return }
        if canonical != id {
          var next = document
          let changed = next.snapshot.stories.filter { $0.mediaIDs.contains(id) }.map(\.id)
          let correction = next.snapshot.corrections[id]
          next.remapMedia(from: id, to: canonical)
          for storyID in changed {
            if let story = next.snapshot.stories.first(where: { $0.id == storyID }) {
              next.enqueue(entity: "story", id: storyID, payload: .story(story))
            }
          }
          if let correction = next.snapshot.corrections[canonical] ?? correction {
            next.enqueue(entity: "correction", id: canonical, payload: .correction(correction))
          }
          try persist(next)
        }
      } catch { mediaUploadErrors[id] = error.localizedDescription }
    }
    mediaUploadProgress = ""
    status = mediaUploadErrors.isEmpty ? "同步完成（已上传选中原片）" : "整理已同步，部分原片未上传"
  }
  func signOut() async {
    do { try await account.signOut(); identityChanged() }
    catch { self.error = error.localizedDescription }
  }
  func deleteAccount() async {
    guard let id = account.userID else { return }
    syncID = nil; syncing = false
    do {
      try await account.deleteAccount()
      try repository.remove(owner: id)
      identityChanged()
    } catch { self.error = "账号删除未完成：\(error.localizedDescription)" }
  }
  func requestSync() {
    guard loaded, document.syncEnabled, account.userID == owner, !syncing else { return }
    Task { await synchronize() }
  }
  private func valid(_ token: UUID, owner expected: String) -> Bool {
    syncID == token && owner == expected && account.userID == expected
  }
  func synchronize() async {
    guard document.syncEnabled, let client = account.client, account.userID == owner, !syncing else { return }
    let token = UUID(), expected = owner
    syncID = token; syncing = true; status = "同步中"; error = nil
    var completed = false
    defer {
      if syncID == token {
        syncing = false; syncID = nil
        if completed && document.outbox.contains(where: { operation in
          operation.resolving != nil || !document.conflicts.contains(where: { $0.key == operation.key })
        }) { requestSync() }
      }
    }
    let transport = SupabaseArchiveTransport(client: client)
    do {
      // Server pages use a per-account committed sequence, never a device wall clock.
      var more = true
      while more {
        let page = try await transport.pull(after: document.cursor)
        guard valid(token, owner: expected) else { return }
        var next = document
        for change in page.changes { next.apply(change.record) }
        next.cursor = page.cursor
        next.conflicts = page.conflicts
        try persist(next)
        more = page.hasMore
        if !document.syncEnabled { return }
      }
      let locals = document.outbox.filter { $0.entity == "media" && !$0.attempted }
        .compactMap { document.media[$0.entityID]?.localIdentifier }
      let cloudMappings = await photos.cloudMappings(locals)
      guard valid(token, owner: expected) else { return }
      var prepared = document
      for index in prepared.outbox.indices where prepared.outbox[index].entity == "media" && !prepared.outbox[index].attempted {
        let id = prepared.outbox[index].entityID
        if let local = prepared.media[id]?.localIdentifier, let cloud = cloudMappings[local] {
          prepared.cloudIDs[id] = cloud; prepared.outbox[index].payload.cloudIdentifier = cloud
        }
      }
      try persist(prepared)
      var checkedMedia = Set(locals)
      while document.syncEnabled {
        let unmapped = document.outbox.filter { $0.entity == "media" && !$0.attempted }
          .compactMap { document.media[$0.entityID]?.localIdentifier }.filter { !checkedMedia.contains($0) }
        if !unmapped.isEmpty {
          let mappings = await photos.cloudMappings(unmapped)
          guard valid(token, owner: expected), document.syncEnabled else { return }
          checkedMedia.formUnion(unmapped)
          var mapped = document
          for i in mapped.outbox.indices where mapped.outbox[i].entity == "media" && !mapped.outbox[i].attempted {
            let id = mapped.outbox[i].entityID
            if let local = mapped.media[id]?.localIdentifier, let cloud = mappings[local] {
              mapped.cloudIDs[id] = cloud; mapped.outbox[i].payload.cloudIdentifier = cloud
            }
          }
          try persist(mapped)
        }
        let eligible = document.outbox.indices.filter { index in
          let operation = document.outbox[index]
          return operation.resolving != nil || !document.conflicts.contains(where: { $0.key == operation.key })
        }
        guard let index = eligible.first(where: { document.outbox[$0].entity == "media" }) ?? eligible.first else { break }
        var next = document
        next.outbox[index].attempted = true
        let operation = next.outbox[index]
        try persist(next)
        let result = try await transport.push(operation.wire)
        guard valid(token, owner: expected) else { return }
        next = document
        if operation.entity == "media", result.status == "canonical", result.record.id != operation.entityID {
          next.remapMedia(from: operation.entityID, to: result.record.id)
        }
        next.accept(result, operationID: operation.id)
        try persist(next)
      }
      guard document.syncEnabled else { return }
      let mappings = await photos.localMappings(Array(Set(document.cloudIDs.values)))
      guard valid(token, owner: expected) else { return }
      guard document.syncEnabled else { return }
      var next = document
      for (id, cloud) in next.cloudIDs {
        if let local = mappings[cloud], next.media[id]?.localIdentifier == nil {
          // Remove an unorganized local index alias, preserving the cloud archive identity.
          if let old = next.media.values.first(where: { $0.localIdentifier == local && $0.id != id }),
             !next.snapshot.stories.contains(where: { $0.mediaIDs.contains(old.id) }), next.snapshot.corrections[old.id] == nil {
            next.media.removeValue(forKey: old.id)
          }
          next.media[id]?.localIdentifier = local
        }
      }
      next.lastSync = .now
      try persist(next)
      status = next.conflicts.isEmpty ? (next.outbox.isEmpty ? "同步完成（不含照片备份）" : "待同步") : "有 \(next.conflicts.count) 项冲突待处理"
      await refreshPhotos()
      try await refreshCloudReferences(client: client, token: token, expected: expected)
      await uploadCuratedMedia(client: client, token: token, expected: expected)
      completed = true
    } catch {
      guard valid(token, owner: expected) else { return }
      status = "同步失败，修改已保存在本机"
      self.error = error.localizedDescription
    }
  }
  func resolve(_ conflict: SyncConflict, keepLocal: Bool) {
    var next = document
    let selected = keepLocal ? conflict.local : conflict.remote
    // Preserve edits queued while the conflicted operation was in flight.
    let latest = keepLocal ? next.outbox.last(where: { $0.key == conflict.key }) : nil
    next.outbox.removeAll { $0.key == conflict.key }
    next.enqueue(entity: selected.entity, id: selected.id, payload: latest?.payload ?? selected.payload,
      deleted: latest?.deleted ?? selected.deleted, resolving: conflict.id)
    next.outbox[next.outbox.count - 1].baseVersion = conflict.remote.version
    do { try persist(next); requestSync() } catch { self.error = error.localizedDescription }
  }
  func associate(id: String, with selected: MediaItem) {
    guard let local = selected.localIdentifier else { return }
    var next = document
    let alreadyOrganized = next.snapshot.stories.contains { $0.mediaIDs.contains(selected.id) } || next.snapshot.corrections[selected.id] != nil
    if selected.id != id && alreadyOrganized { error = "这张照片已关联其他档案，请选择另一张照片。"; return }
    next.media[id] = MediaItem(id: id, assetName: "", title: selected.title, kind: selected.kind,
      originalDay: selected.originalDay, originalPlace: selected.originalPlace, source: "手动关联系统照片",
      localIdentifier: local, accessible: true, captureDate: selected.captureDate)
    if selected.id != id { next.media.removeValue(forKey: selected.id) }
    do { try persist(next) } catch { self.error = error.localizedDescription }
  }
}

extension LiveDocument {
  mutating func remapMedia(from old: String, to canonical: String) {
    if let item = media.removeValue(forKey: old), media[canonical]?.localIdentifier == nil {
      media[canonical] = MediaItem(id: canonical, assetName: item.assetName, title: item.title, kind: item.kind,
        originalDay: item.originalDay, originalPlace: item.originalPlace, source: item.source,
        localIdentifier: item.localIdentifier, accessible: item.accessible, captureDate: item.captureDate)
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
    for index in outbox.indices {
      if outbox[index].entity == "story" {
        outbox[index].payload.mediaIDs = outbox[index].payload.mediaIDs?.map { $0 == old ? canonical : $0 }
        if outbox[index].payload.coverID == old { outbox[index].payload.coverID = canonical }
      } else if outbox[index].entity == "correction", outbox[index].entityID == old {
        outbox[index].entityID = canonical
      }
    }
  }
}
