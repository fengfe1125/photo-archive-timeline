import XCTest
import SwiftData
@testable import PhotoArchive

final class ArchiveMigrationTests: XCTestCase {
  private func fixture(_ suffix: String = "a") -> LiveDocument {
    let media = MediaItem(id: "media-\(suffix)", assetName: "", title: "Local photo", kind: .photo,
      originalDay: ArchiveDay(2024, 2, 29), originalPlace: Place(name: "Private", latitude: 30, longitude: 110),
      source: "系统照片库", localIdentifier: "LOCAL-\(suffix)", accessible: true,
      captureDate: Date(timeIntervalSince1970: 1_709_164_800))
    var document = LiveDocument()
    document.media[media.id] = media
    let story = Story(id: "story-\(suffix)", title: "Saved", description: "Keep order and cover", mediaIDs: [media.id], coverID: media.id)
    document.snapshot.stories = [story]
    document.snapshot.corrections[media.id] = MetadataCorrection(mediaID: media.id, originalDay: media.originalDay,
      originalPlace: media.originalPlace, day: nil, place: nil, description: "A correction", dayMode: .clear, placeMode: .original)
    document.cloudIDs[media.id] = "CLOUD-\(suffix)"
    document.versions["story:\(story.id)"] = 7
    document.versions["story:deleted-\(suffix)"] = 12 // Deleted entity's version must not resurrect.
    document.enqueue(entity: "story", id: story.id, payload: .story(story))
    document.outbox[0].attempted = true
    var later = story; later.title = "Unsynced next edit"
    document.enqueue(entity: "story", id: story.id, payload: .story(later))
    let local = SyncRecord(entity: "correction", id: media.id, version: 2, deleted: false, payload: .correction(document.snapshot.corrections[media.id]!))
    let remote = SyncRecord(entity: "correction", id: media.id, version: 4, deleted: true, payload: WirePayload())
    document.conflicts = [SyncConflict(id: "conflict-\(suffix)", local: local, remote: remote)]
    document.cursor = 99; document.syncEnabled = suffix != "guest"
    document.lastSync = Date(timeIntervalSince1970: 1_709_170_000)
    return document
  }

  @MainActor private func seedLegacy(_ documents: [String: LiveDocument], at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = ModelConfiguration(url: directory.appendingPathComponent("archive.store"), cloudKitDatabase: .none)
    let container = try ModelContainer(for: StoredArchive.self, configurations: config)
    let context = ModelContext(container); context.autosaveEnabled = false
    for (owner, document) in documents { context.insert(StoredArchive(owner: owner, data: try JSONEncoder().encode(document))) }
    try context.save()
  }

  @MainActor func testAllOwnersMigrateExactUnsentAttemptedConflictAndTombstoneState() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let expected = ["guest": fixture("guest"), "account-a": fixture("a"), "account-b": fixture("b")]
    try seedLegacy(expected, at: directory)
    let repository = try LiveArchiveRepository(directory: directory)
    for (owner, document) in expected {
      let result = try await repository.load(owner: owner)
      XCTAssertEqual(result, document)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("archive.store").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ArchiveMigration.markerName).path))
    let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("migration-backups"), includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    let snapshot = try JSONDecoder().decode(ArchiveCompatibilitySnapshot.self, from: Data(contentsOf: XCTUnwrap(backups.first)))
    XCTAssertEqual(snapshot.owners, expected)
    let reopened = try LiveArchiveRepository(directory: directory)
    for (owner, document) in expected {
      let result = try await reopened.load(owner: owner)
      XCTAssertEqual(result, document)
    }
  }

  @MainActor func testCorruptLegacyNeverPublishesSwitchOrOverwritesSource() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var invalid = fixture(); invalid.snapshot.stories[0].coverID = "missing"
    try seedLegacy(["account-a": invalid], at: directory)
    let file = directory.appendingPathComponent("archive.store")
    let before = try Data(contentsOf: file)
    let repository = try LiveArchiveRepository(directory: directory)
    do { _ = try await repository.load(owner: "account-a"); XCTFail("Invalid legacy must block migration") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ArchiveMigration.markerName).path))
    XCTAssertEqual(try Data(contentsOf: file), before)
  }

  @MainActor func testMigrationCancellationBeforePublishPreservesSourceAndRetriesAllOwners() async throws {
    try await assertPrePublishFailureRecovery(outOfSpace: false)
  }

  @MainActor func testMigrationOutOfSpaceBeforePublishPreservesSourceAndRetriesAllOwners() async throws {
    try await assertPrePublishFailureRecovery(outOfSpace: true)
  }

  @MainActor private func assertPrePublishFailureRecovery(outOfSpace: Bool) async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let expected = ["guest": fixture("guest"), "account-a": fixture("a"), "account-b": fixture("b")]
    try seedLegacy(expected, at: directory)
    let files = FileManager.default
    let source = directory.appendingPathComponent("archive.store")
    let before = try Data(contentsOf: source)
    let marker = directory.appendingPathComponent(ArchiveMigration.markerName)
    do {
      _ = try await ArchiveMigration.open(directory: directory, inMemory: false, beforePublish: {
        if outOfSpace { throw CocoaError(.fileWriteOutOfSpace) }
        throw CancellationError()
      })
      XCTFail("A pre-publication failure must escape without publishing the new store")
    } catch let error as CocoaError {
      XCTAssertTrue(outOfSpace)
      XCTAssertEqual(error.code, .fileWriteOutOfSpace)
    } catch is CancellationError {
      XCTAssertFalse(outOfSpace)
    } catch {
      XCTFail("Unexpected migration failure: \(error)")
    }
    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertFalse(files.fileExists(atPath: marker.path))
    let staged = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("archive-v2-") }
    XCTAssertEqual(staged.count, 1, "Keep the validated staging directory for recovery")
    let stagedStore = try XCTUnwrap(staged.first).appendingPathComponent("archive.store")
    XCTAssertTrue(files.fileExists(atPath: stagedStore.path))
    let stagedReader = try ArchiveDatabase(modelContainer: ArchiveDatabase.container(at: stagedStore))
    let stagedDocuments = try await stagedReader.allDocuments()
    XCTAssertEqual(stagedDocuments, expected)
    let backupDirectory = directory.appendingPathComponent("migration-backups")
    let backups = try files.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    let backup = try XCTUnwrap(backups.first)
    let snapshot = try JSONDecoder().decode(ArchiveCompatibilitySnapshot.self, from: Data(contentsOf: backup))
    XCTAssertEqual(snapshot.owners, expected)

    let retry = try await ArchiveMigration.open(directory: directory, inMemory: false)
    let restored = try await retry.allDocuments()
    XCTAssertEqual(restored, expected)
    XCTAssertTrue(files.fileExists(atPath: marker.path))
    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertTrue(files.fileExists(atPath: stagedStore.path))
    XCTAssertTrue(files.fileExists(atPath: backup.path), "Retry must preserve earlier recovery material")
    let reopened = try await ArchiveMigration.open(directory: directory, inMemory: false)
    let afterRestart = try await reopened.allDocuments()
    XCTAssertEqual(afterRestart, expected)
  }

  @MainActor func testActiveStoreKeepsPostMigrationEditsAndExportsCurrentCompatibilitySnapshot() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedLegacy(["account-a": fixture()], at: directory)
    let repository = try LiveArchiveRepository(directory: directory)
    let result = try await repository.update(owner: "account-a", impact: .organization) { document in
      document.snapshot.stories[0].title = "After upgrade"
    }
    let reopened = try LiveArchiveRepository(directory: directory)
    let current = try await reopened.load(owner: "account-a")
    XCTAssertEqual(current, result.document)
    let url = try await reopened.exportCompatibilitySnapshot()
    let snapshot = try JSONDecoder().decode(ArchiveCompatibilitySnapshot.self, from: Data(contentsOf: url))
    XCTAssertEqual(snapshot.owners["account-a"]?.snapshot.stories[0].title, "After upgrade")
    try await reopened.remove(owner: "account-a")
    let afterDelete = try await reopened.exportCompatibilitySnapshot()
    let deleted = try JSONDecoder().decode(ArchiveCompatibilitySnapshot.self, from: Data(contentsOf: afterDelete))
    XCTAssertNil(deleted.owners["account-a"])
    let afterRestart = try LiveArchiveRepository(directory: directory)
    let absent = try await afterRestart.load(owner: "account-a")
    let exists = try await afterRestart.exists(owner: "account-a")
    XCTAssertFalse(exists, "Active marker prevents reimporting a deleted owner from legacy")
    XCTAssertTrue(absent.media.isEmpty)
  }

  func testConcurrentCommandsUseLatestDocumentWithoutLosingEdits() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try LiveArchiveRepository(directory: directory)
    var source = fixture(); source.snapshot.stories = []; source.outbox = []; source.conflicts = []
    try await repository.save(source, owner: "account-a")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for number in 0..<32 {
        group.addTask {
          _ = try await repository.update(owner: "account-a", impact: .organization) { document in
            let story = Story(id: "concurrent-\(number)", title: "Edit \(number)", mediaIDs: ["media-a"], coverID: "media-a")
            document.snapshot.stories.append(story)
            document.enqueue(entity: "story", id: story.id, payload: .story(story))
          }
        }
      }
      try await group.waitForAll()
    }
    let result = try await repository.load(owner: "account-a")
    XCTAssertEqual(result.snapshot.stories.count, 32)
    XCTAssertEqual(Set(result.snapshot.stories.map(\.id)).count, 32)
    XCTAssertEqual(result.outbox.count, 32)
    let other = try await repository.load(owner: "account-b")
    XCTAssertTrue(other.snapshot.stories.isEmpty)
  }

  func testSyncMetadataAndStoryEditsDoNotInvalidateLibraryOrSearch() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try LiveArchiveRepository(directory: directory)
    try await repository.save(fixture(), owner: "account-a")
    let before = try await repository.read(owner: "account-a")
    let after = try await repository.update(owner: "account-a", impact: .metadata) { document in
      document.cursor += 1; document.lastSync = Date(); document.outbox[1].attempted = true
    }
    XCTAssertGreaterThan(after.revision, before.revision)
    XCTAssertEqual(after.libraryRevision, before.libraryRevision)
    XCTAssertEqual(after.searchRevision, before.searchRevision)
    let edited = try await repository.update(owner: "account-a", impact: .organization) { $0.snapshot.stories[0].title = "Another title" }
    XCTAssertEqual(edited.libraryRevision, before.libraryRevision)
    XCTAssertEqual(edited.searchRevision, before.searchRevision)
    let corrected = try await repository.update(owner: "account-a", impact: .organization) { $0.snapshot.corrections["media-a"]?.dayMode = .original }
    XCTAssertGreaterThan(corrected.libraryRevision, before.libraryRevision)
  }

  func testDatabasePagesHaveStableOrderNoDuplicatesAndCorrectedDates() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try LiveArchiveRepository(directory: directory)
    var source = LiveDocument()
    for n in 0..<301 {
      let id = String(format: "media-%04d", n)
      source.media[id] = MediaItem(id: id, assetName: "", title: id, kind: n % 2 == 0 ? .photo : .video,
        originalDay: n < 250 ? ArchiveDay(2024, 2, 29) : nil, originalPlace: nil, source: "fixture", accessible: true)
    }
    source.snapshot.corrections["media-0300"] = MetadataCorrection(mediaID: "media-0300", originalDay: nil,
      originalPlace: nil, day: ArchiveDay(2025, 1, 1), place: nil, description: "", dayMode: .value, placeMode: .original)
    try await repository.save(source, owner: "guest")
    var cursor: LibraryCursor?, ids: [String] = []
    repeat {
      let page = try await repository.page(owner: "guest", query: LibraryQuery(), cursor: cursor, limit: 120)
      XCTAssertEqual(page.totalCount, 301); XCTAssertLessThanOrEqual(page.items.count, 120)
      if cursor == nil {
        XCTAssertEqual(page.items.first?.id, "media-0300")
        XCTAssertEqual(page.effectiveDays["media-0300"], ArchiveDay(2025, 1, 1))
        XCTAssertEqual(page.years, [2025, 2024])
      }
      ids.append(contentsOf: page.items.map(\.id)); cursor = page.nextCursor
    } while cursor != nil
    XCTAssertEqual(ids.count, 301); XCTAssertEqual(Set(ids).count, 301)
    XCTAssertEqual(ids.last, "media-0299")
    let query = LibraryQuery(kind: .photo, year: 2024, month: 2, excludedIDs: ["media-0000"])
    let filtered = try await repository.page(owner: "guest", query: query, cursor: nil, limit: 120)
    XCTAssertEqual(filtered.totalCount, 124)
    XCTAssertFalse(filtered.items.contains(where: { $0.id == "media-0000" }))
    XCTAssertTrue(filtered.items.allSatisfy { $0.kind == .photo })
    let first = try await repository.page(owner: "guest", query: LibraryQuery(), cursor: nil, limit: 120)
    _ = try await repository.update(owner: "guest", impact: .organization) { $0.snapshot.corrections.removeValue(forKey: "media-0300") }
    do { _ = try await repository.page(owner: "guest", query: LibraryQuery(), cursor: first.nextCursor, limit: 120); XCTFail("Old cursor must not silently skip changed rows") }
    catch ArchiveStorageError.staleCursor { }
  }

  func testLimitedAccessAndCloudVisibilityNeverDeleteOrganizedMedia() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try LiveArchiveRepository(directory: directory)
    try await repository.save(fixture(), owner: "account-a")
    _ = try await repository.update(owner: "account-a") { $0.media["media-a"]?.accessible = false }
    let visible = try await repository.page(owner: "account-a", query: LibraryQuery(), cursor: nil)
    XCTAssertEqual(visible.totalCount, 1)
    let local = try await repository.page(owner: "account-a", query: LibraryQuery(accessibleOnly: true), cursor: nil)
    XCTAssertEqual(local.totalCount, 0)
    _ = try await repository.update(owner: "account-a", impact: .metadata) { $0.syncEnabled = false }
    let hidden = try await repository.page(owner: "account-a", query: LibraryQuery(), cursor: nil)
    XCTAssertEqual(hidden.totalCount, 0)
    let document = try await repository.load(owner: "account-a")
    XCTAssertNotNil(document.media["media-a"])
    XCTAssertEqual(document.snapshot.stories.first?.mediaIDs, ["media-a"])
  }
  @MainActor func testFailedIdentityTargetRetryNeverReopensPreviousAccount() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try LiveArchiveRepository(directory: directory)
    for (owner, document) in ["account-a": fixture("a"), "account-b": fixture("b"), "guest": fixture("guest")] {
      try await writer.save(document, owner: owner)
    }
    let marker = try Data(contentsOf: directory.appendingPathComponent(ArchiveMigration.markerName))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: marker) as? [String: Any])
    let folder = try XCTUnwrap(object["folder"] as? String)
    let container = try ArchiveDatabase.container(at: directory.appendingPathComponent(folder).appendingPathComponent("archive.store"))
    let context = ModelContext(container); context.autosaveEnabled = false
    let rows = try context.fetch(FetchDescriptor<ArchiveMediaRow>())
    for row in rows where row.owner != "account-a" { row.payload = Data("unreadable target".utf8) }
    try context.save()
    let repository = try LiveArchiveRepository(directory: directory)
    let session = ArchiveSessionGate()
    _ = session.beginTransition(identity: "account-a")
    let originalOwner = try await session.resolveOwner { try await repository.exists(owner: $0) }
    XCTAssertEqual(originalOwner, "account-a")
    let original = try await repository.bootstrap(owner: originalOwner)
    XCTAssertNotNil(original.document.media["media-a"])
    for identity: String? in ["account-b", nil] {
      // A failed target load followed by retry uses the same current identity;
      // the formerly successful account remains readable, but must never be chosen.
      for _ in 0..<2 {
        _ = session.beginTransition(identity: identity)
        let target = try await session.resolveOwner { try await repository.exists(owner: $0) }
        XCTAssertEqual(target, identity ?? "guest")
        XCTAssertNotEqual(target, originalOwner)
        do {
          _ = try await repository.bootstrap(owner: target)
          XCTFail("The unreadable current target must fail closed, never reopen account A")
        } catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertFalse(session.ready)
      }
    }
  }

  @MainActor func testNewIdentityWaitsForInFlightAdoptionBeforeReadingGuest() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try LiveArchiveRepository(directory: directory)
    try await repository.save(fixture("guest"), owner: "guest")
    let session = ArchiveSessionGate()
    let adoptionToken = session.beginTransition(identity: "account-a")
    var continuation: CheckedContinuation<Void, Never>?
    var adoptionStarted = false, lookupStarted = false, lookupFinished = false
    let adoption = Task {
      try await session.withTransitionWrite(token: adoptionToken) {
        adoptionStarted = true
        await withCheckedContinuation { continuation = $0 }
        return try await repository.adoptGuestReadModel(into: "account-a")
      }
    }
    while !adoptionStarted { await Task.yield() }
    _ = session.beginTransition(identity: nil)
    let lookup = Task {
      lookupStarted = true
      await session.waitForWrites()
      let target = try await session.resolveOwner { try await repository.exists(owner: $0) }
      let model = try await repository.read(owner: target)
      lookupFinished = true
      return model
    }
    while !lookupStarted { await Task.yield() }
    XCTAssertFalse(lookupFinished, "A later identity must not read guest before the pending owner move")
    continuation?.resume()
    let adopted = try await adoption.value
    let guest = try await lookup.value
    XCTAssertFalse(adopted.document.snapshot.stories.isEmpty)
    XCTAssertTrue(guest.document.snapshot.stories.isEmpty)
    XCTAssertFalse(session.complete(adoptionToken), "The old adoption callback must not reopen the prior account")
  }

  @MainActor func testIdentityTransitionDrainsAcceptedWritesAndRejectsStaleLookup() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try LiveArchiveRepository(directory: directory)
    try await repository.save(fixture("guest"), owner: "guest")
    let session = ArchiveSessionGate()
    XCTAssertTrue(session.complete(session.generation))
    let priorWrite = try session.enterWrite()
    let identityLookup = session.beginTransition()
    let adoptionToken = session.beginTransition()
    XCTAssertThrowsError(try session.enterWrite(), "New edits must not enter the guest archive during adoption")
    XCTAssertFalse(session.complete(identityLookup), "A delayed lookup must not reopen its old guest target")
    var adoptionStarted = false
    var adopted = false
    let move = Task {
      adoptionStarted = true
      await session.waitForWrites()
      let model = try await repository.adoptGuestReadModel(into: "account-a")
      adopted = true
      XCTAssertTrue(session.complete(adoptionToken))
      return model
    }
    while !adoptionStarted { await Task.yield() }
    XCTAssertFalse(adopted, "An accepted guest edit must finish before the owner move")
    _ = try await repository.update(owner: "guest", impact: .organization) { document in
      document.snapshot.stories.append(Story(id: "late-edit", title: "Accepted before move", mediaIDs: [], coverID: nil))
    }
    session.leaveWrite()
    let account = try await move.value
    XCTAssertTrue(account.document.snapshot.stories.contains { $0.id == "late-edit" })
    let guest = try await repository.load(owner: "guest")
    XCTAssertTrue(guest.snapshot.stories.isEmpty)
    XCTAssertFalse(session.complete(priorWrite))
    XCTAssertTrue(session.ready)
    let afterMove = try session.enterWrite()
    XCTAssertEqual(afterMove, adoptionToken)
    session.leaveWrite()
  }

  @MainActor func testLegacyV2StoryPayloadUpgradesToOrderedRelationsWithoutLosingCover() async throws {
    let container = try ArchiveDatabase.container(at: nil, inMemory: true)
    let context = ModelContext(container); context.autosaveEnabled = false
    context.insert(ArchiveOwnerRow(owner: "guest"))
    var document = fixture("guest")
    let second = fixture("second").media["media-second"]!
    document.media[second.id] = second
    var legacy = document.snapshot.stories[0]
    legacy.mediaIDs = ["media-guest", "media-second"]; legacy.coverID = "media-second"
    for item in document.media.values {
      context.insert(ArchiveMediaRow(owner: "guest", item: item,
        payload: try JSONEncoder().encode(item), effectiveDay: item.originalDay))
    }
    context.insert(ArchiveEntityRow(owner: "guest", namespace: "story", id: legacy.id,
      position: 0, payload: try JSONEncoder().encode(legacy)))
    try context.save()
    let database = ArchiveDatabase(modelContainer: container)
    let old = try await database.read(owner: "guest")
    XCTAssertEqual(old.document.snapshot.stories, [legacy])
    var changed = legacy; changed.title = "Edited metadata only"
    let expected = changed
    _ = try await database.update(owner: "guest", impact: .organization) { $0.snapshot.stories = [expected] }
    let inspection = ModelContext(container)
    let rows = try inspection.fetch(FetchDescriptor<ArchiveEntityRow>())
    let metadata = try XCTUnwrap(rows.first { $0.namespace == "story" })
    XCTAssertTrue(try JSONDecoder().decode(Story.self, from: metadata.payload).mediaIDs.isEmpty)
    XCTAssertEqual(rows.filter { $0.namespace == "story-media:" + legacy.id }.sorted { $0.position < $1.position }.map(\.entityID), legacy.mediaIDs)
    let reopened = ArchiveDatabase(modelContainer: container)
    let restored = try await reopened.read(owner: "guest")
    XCTAssertEqual(restored.document.snapshot.stories, [expected])
    _ = try await reopened.update(owner: "guest", impact: .organization) { $0.snapshot.stories[0].mediaIDs.reverse() }
    let reordered = try await ArchiveDatabase(modelContainer: container).read(owner: "guest")
    XCTAssertEqual(reordered.document.snapshot.stories[0].mediaIDs, ["media-second", "media-guest"])
    XCTAssertEqual(reordered.document.snapshot.stories[0].coverID, "media-second")
    _ = try await reopened.update(owner: "guest", impact: .organization) {
      $0.snapshot.stories[0].mediaIDs = []; $0.snapshot.stories[0].coverID = nil
    }
    let emptied = try await ArchiveDatabase(modelContainer: container).read(owner: "guest")
    XCTAssertTrue(emptied.document.snapshot.stories[0].mediaIDs.isEmpty, "Legacy media IDs must not reappear after removing all relations")
    XCTAssertNil(emptied.document.snapshot.stories[0].coverID)
  }

  func testBootstrapIsBoundedAndDoesNotReplaceTheCompleteArchive() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var document = LiveDocument()
    for index in 0..<301 {
      let id = String(format: "boot-%04d", index)
      document.media[id] = MediaItem(id: id, assetName: "", title: "Fixture", kind: .photo,
        originalDay: ArchiveDay(2024, 1, 1), originalPlace: nil, source: "fixture", localIdentifier: id, accessible: true)
    }
    let story = Story(id: "later-story", title: "Outside first page", mediaIDs: ["boot-0300", "boot-0000"], coverID: "boot-0300")
    document.snapshot.stories = [story]
    for id in ["boot-0000", "boot-0300"] {
      document.snapshot.corrections[id] = MetadataCorrection(mediaID: id, originalDay: ArchiveDay(2024, 1, 1),
        originalPlace: nil, day: nil, place: nil, description: "Preserve", dayMode: .original, placeMode: .original)
    }
    document.enqueue(entity: "story", id: story.id, payload: .story(story))
    let writer = try LiveArchiveRepository(directory: directory)
    try await writer.save(document, owner: "guest")
    let reader = try LiveArchiveRepository(directory: directory)
    let boot = try await reader.bootstrap(owner: "guest")
    XCTAssertEqual(boot.firstPage.items.count, 120)
    XCTAssertEqual(boot.firstPage.totalCount, 301)
    XCTAssertEqual(boot.document.media.count, 120)
    XCTAssertEqual(boot.document.snapshot.corrections["boot-0000"], document.snapshot.corrections["boot-0000"])
    XCTAssertNil(boot.document.snapshot.corrections["boot-0300"])
    XCTAssertTrue(boot.document.snapshot.stories.isEmpty)
    let full = try await reader.load(owner: "guest")
    XCTAssertEqual(full, document, "A bootstrap must not populate the full-document cache with its partial data")
    XCTAssertEqual(full.snapshot.stories[0].mediaIDs, ["boot-0300", "boot-0000"])
  }

  func testLargeLibraryStorageBenchmark() async throws {
    for count in [1_000, 10_000, 50_000] {
      let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      var document = LiveDocument()
      for index in 0..<count {
        let id = String(format: "large-%06d", index)
        document.media[id] = MediaItem(id: id, assetName: "", title: "Fixture", kind: .photo,
          originalDay: ArchiveDay(2000 + index % 25, 1 + index % 12, 1 + index % 28),
          originalPlace: nil, source: "fixture", localIdentifier: id, accessible: true)
      }
      let repository = try LiveArchiveRepository(directory: directory)
      let start = ProcessInfo.processInfo.systemUptime
      try await repository.save(document, owner: "guest")
      let written = ProcessInfo.processInfo.systemUptime
      let page = try await repository.page(owner: "guest", query: LibraryQuery(), cursor: nil)
      let paged = ProcessInfo.processInfo.systemUptime
      let metadata = try await repository.update(owner: "guest", impact: .metadata) { $0.cursor += 1 }
      let changed = ProcessInfo.processInfo.systemUptime
      XCTAssertEqual(page.totalCount, count)
      XCTAssertEqual(page.items.count, 120)
      XCTAssertEqual(metadata.libraryRevision, 1)
      let reopened = try LiveArchiveRepository(directory: directory)
      let bootstrap = try await reopened.bootstrap(owner: "guest")
      let cold = bootstrap.firstPage
      let loaded = ProcessInfo.processInfo.systemUptime
      XCTAssertEqual(cold.items.map(\.id), page.items.map(\.id))
      XCTAssertEqual(cold.totalCount, count)
      var filterMilliseconds: [Double] = []
      for sample in 0..<20 {
        let filterStart = ProcessInfo.processInfo.systemUptime
        let filtered = try await reopened.page(owner: "guest", query: LibraryQuery(kind: .photo, year: 2000 + sample), cursor: nil)
        filterMilliseconds.append((ProcessInfo.processInfo.systemUptime - filterStart) * 1_000)
        XCTAssertEqual(filtered.totalCount, count / 25)
      }
      filterMilliseconds.sort()
      let p95 = filterMilliseconds[Int(ceil(Double(filterMilliseconds.count) * 0.95)) - 1]
      print("StorageFilterBenchmark rows=\(count) samples=20 p95Ms=\(String(format: "%.2f", p95)) environment=synthetic-host-not-device")
      print("StorageBenchmark rows=\(count) writeMs=\(Int((written-start)*1000)) warmPageMs=\(Int((paged-written)*1000)) metadataMs=\(Int((changed-paged)*1000)) coldBootstrapMs=\(Int((loaded-changed)*1000))")
    }
  }

}
