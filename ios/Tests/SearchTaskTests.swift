import XCTest
@testable import PhotoArchive

final class SearchTaskTests: XCTestCase {
  private func legacyWrite<T: Encodable>(_ value: T, base: URL, owner: String, id: String) throws -> URL {
    let directory = base.appendingPathComponent(SearchDigest.of(Data(owner.utf8)))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(SearchDigest.of(Data(id.utf8)) + ".json")
    try JSONEncoder.sorted.encode(value).write(to: file)
    return file
  }
  func testLegacyMigrationPreservesEveryOwnerAndNeverRestoresStalePreferences() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    var preferences = SearchPreferences()
    preferences.ai = true; preferences.geo = true; preferences.localAnalysisPaused = true
    preferences.pending = ["vision:photo:v1": "paid-request-id"]
    preferences.albums = [SearchAlbum(name: "海边", query: .init(include: ["海边"]), excluded: ["private-photo"])]
    preferences.modelVersion = "model-v9"
    var analysis = SearchAnalysis(version: "original-version")
    analysis.state = "waiting"; analysis.failureReason = "iCloud"; analysis.decisions = ["query": 0.95]
    let source = try legacyWrite(preferences, base: base, owner: "owner-a", id: "preferences")
    let original = try Data(contentsOf: source)
    _ = try legacyWrite(analysis, base: base, owner: "owner-a", id: "photo")
    _ = try legacyWrite(SearchPreferences(), base: base, owner: "guest", id: "preferences")
    _ = try legacyWrite(analysis, base: base, owner: "signed-out-owner", id: "photo")
    try await SearchRepository.migrateExistingOwners(base: base)
    let repository = SearchRepository(base: base, owner: "owner-a")
    let loaded = try await repository.read(SearchPreferences.self, id: "preferences")
    XCTAssertEqual(loaded?.pending, preferences.pending)
    XCTAssertEqual(loaded?.albums.first?.excluded, ["private-photo"])
    XCTAssertEqual(loaded?.localAnalysisPaused, true)
    XCTAssertEqual(loaded?.modelVersion, "model-v9")
    let signedOut = try await SearchRepository(base: base, owner: "signed-out-owner").read(SearchAnalysis.self, id: "photo")
    XCTAssertEqual(signedOut?.version, "original-version")
    XCTAssertEqual(signedOut?.decisions, ["query": 0.95])
    preferences.pending["new-request"] = "new-paid-id"
    try await repository.write(preferences, id: "preferences")
    try await SearchRepository.migrateExistingOwners(base: base)
    let reopened = try await SearchRepository(base: base, owner: "owner-a").read(SearchPreferences.self, id: "preferences")
    XCTAssertEqual(reopened?.pending["new-request"], "new-paid-id", "An old backup must never replace newer paid-request credentials")
    XCTAssertEqual(try Data(contentsOf: source), original)
  }
  func testCorruptMigrationKeepsSourceAndCanRetryAfterRepair() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = try legacyWrite(SearchAnalysis(version: "v1"), base: base, owner: "a", id: "photo")
    try Data("invalid-json".utf8).write(to: file)
    do { try await SearchRepository(base: base, owner: "a").prepare(); XCTFail("Must fail instead of silently dropping the index") }
    catch { XCTAssertEqual(try Data(contentsOf: file), Data("invalid-json".utf8)) }
    try JSONEncoder.sorted.encode(SearchAnalysis(version: "repaired")).write(to: file)
    let loaded = try await SearchRepository(base: base, owner: "a").read(SearchAnalysis.self, id: "photo")
    XCTAssertEqual(loaded?.version, "repaired")
  }
  func testOldPreferencesDecodeWithoutOptingIntoCloudOrLosingPendingIDs() throws {
    let legacy = Data(#"{"geo":false,"ai":false,"albums":[],"pending":{"key":"billable-id"}}"#.utf8)
    let preferences = try JSONDecoder().decode(SearchPreferences.self, from: legacy)
    XCTAssertNil(preferences.localAnalysisPaused)
    XCTAssertFalse(preferences.ai); XCTAssertFalse(preferences.geo)
    XCTAssertEqual(preferences.pending["key"], "billable-id")
  }
  private enum CommitFailure: Error { case interrupted }
  private func seededModelRepository(base: URL) async throws -> SearchRepository {
    let repository = SearchRepository(base: base, owner: "account")
    var preferences = SearchPreferences()
    preferences.modelVersion = "old-model"; preferences.ai = true; preferences.geo = true
    preferences.pending = ["pending-paid-call": "same-request-id"]
    preferences.albums = [SearchAlbum(name: "保留相册", query: .init(city: "武汉"), excluded: ["excluded-photo"])]
    try await repository.write(preferences, id: "preferences")
    var analysis = SearchAnalysis(version: "photo-version")
    analysis.labels = ["beach"]; analysis.state = "ready"; analysis.city = "武汉"
    analysis.description = "旧模型描述"; analysis.visualModel = "old-vision"
    analysis.cloudModelVersion = "old-model"; analysis.decisions = ["query": 0.96]
    try await repository.write(analysis, id: "visible-photo")
    try await repository.write(analysis, id: "unloaded-photo")
    return repository
  }
  func testInterruptedModelTransitionReopensWithWholeOldEpoch() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = try await seededModelRepository(base: base)
    do {
      try await repository.transitionCloudModel(to: "new-model", beforeCommit: { throw CommitFailure.interrupted })
      XCTFail("Injected commit failure must propagate")
    } catch { XCTAssertTrue(error is CommitFailure) }
    let reopened = SearchRepository(base: base, owner: "account")
    let preferences = try await reopened.read(SearchPreferences.self, id: "preferences")
    XCTAssertEqual(preferences?.modelVersion, "old-model")
    XCTAssertEqual(preferences?.pending["pending-paid-call"], "same-request-id")
    for id in ["visible-photo", "unloaded-photo"] {
      let analysis = try await reopened.read(SearchAnalysis.self, id: id)
      XCTAssertEqual(analysis?.description, "旧模型描述")
      XCTAssertEqual(analysis?.decisions["query"], 0.96)
      XCTAssertEqual(analysis?.cloudModelVersion, "old-model")
    }
  }
  func testCancellationAtModelCommitPreservesOldEpochAndRetryClearsEveryRecord() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = try await seededModelRepository(base: base)
    let cancelled = Task {
      try await repository.transitionCloudModel(to: "new-model", beforeCommit: {
        withUnsafeCurrentTask { $0?.cancel() }
      })
    }
    do { try await cancelled.value; XCTFail("Cancellation before commit must roll back") }
    catch { XCTAssertTrue(error is CancellationError) }
    let reopened = SearchRepository(base: base, owner: "account")
    let before = try await reopened.read(SearchPreferences.self, id: "preferences")
    let oldAnalysis = try await reopened.read(SearchAnalysis.self, id: "unloaded-photo")
    XCTAssertEqual(before?.modelVersion, "old-model")
    XCTAssertEqual(oldAnalysis?.description, "旧模型描述")
    try await reopened.transitionCloudModel(to: "new-model")
    let afterReopen = SearchRepository(base: base, owner: "account")
    let after = try await afterReopen.read(SearchPreferences.self, id: "preferences")
    XCTAssertEqual(after?.modelVersion, "new-model")
    XCTAssertEqual(after?.pending, before?.pending)
    XCTAssertEqual(after?.albums.first?.excluded, ["excluded-photo"])
    XCTAssertEqual(after?.ai, true); XCTAssertEqual(after?.geo, true)
    for id in ["visible-photo", "unloaded-photo"] {
      let analysis = try await afterReopen.read(SearchAnalysis.self, id: id)
      XCTAssertEqual(analysis?.cloudModelVersion, "new-model")
      XCTAssertEqual(analysis?.description, ""); XCTAssertEqual(analysis?.visualModel, "")
      XCTAssertTrue(analysis?.decisions.isEmpty == true)
      XCTAssertEqual(analysis?.labels, ["beach"]); XCTAssertEqual(analysis?.state, "ready")
      XCTAssertEqual(analysis?.city, "武汉"); XCTAssertEqual(analysis?.version, "photo-version")
    }
    // Callbacks/preference saves captured before the transaction must not resurrect old evidence.
    try await afterReopen.write(before!, id: "preferences")
    let saved = try await afterReopen.saveAnalysis(oldAnalysis!, id: "visible-photo")
    XCTAssertEqual(saved.description, ""); XCTAssertTrue(saved.decisions.isEmpty)
    let final = try await SearchRepository(base: base, owner: "account").read(SearchPreferences.self, id: "preferences")
    XCTAssertEqual(final?.modelVersion, "new-model")
  }
  @MainActor func testLoginWithoutArchiveSyncImmediatelyClearsGuestSearchAndLateResults() async throws {
    let store = ArchiveStore(repository: JSONArchiveRepository(directory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)), library: TestLibrary(media: (0..<1_000).map(Self.item)))
    let search = PhotoSearchController()
    search.prepareIdentity("guest")
    search.update(.init(city: "武汉"), store: store)
    await search.waitForResults()
    XCTAssertEqual(search.matchCount, 1_000)
    search.preferences.albums = [SearchAlbum(name: "游客相册", query: search.query)]
    search.preferences.pending = ["guest-call": "guest-request"]
    search.selectedAlbumID = search.preferences.albums[0].id
    search.draftCloudQuery = search.query
    search.update(.init(city: "武汉"), store: store)
    // The login identity changes independently of the still-guest archive owner.
    search.prepareIdentity("signed-in-without-archive-sync")
    XCTAssertEqual(search.owner, "signed-in-without-archive-sync")
    XCTAssertTrue(search.matches.isEmpty); XCTAssertTrue(search.possible.isEmpty)
    XCTAssertFalse(search.query.hasConditions); XCTAssertTrue(search.history.isEmpty)
    XCTAssertNil(search.selectedAlbumID); XCTAssertNil(search.draftCloudQuery)
    XCTAssertTrue(search.preferences.albums.isEmpty); XCTAssertTrue(search.preferences.pending.isEmpty)
    await search.waitForResults()
    XCTAssertEqual(search.matchCount, 0); XCTAssertTrue(search.resultIDs(possible: false).isEmpty)
  }
  @MainActor func testReturningOwnerWaitsForEveryQueuedPreferenceSave() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let repositoryA = SearchRepository(base: base, owner: "a"), repositoryB = SearchRepository(base: base, owner: "b")
    let writes = SearchPreferenceWrites(), search = PhotoSearchController(preferenceWrites: writes)
    let firstGate = PreferenceWriteGate(), secondGate = PreferenceWriteGate()
    var first = SearchPreferences()
    first.albums = [SearchAlbum(name: "first", query: .init(city: "武汉"))]
    var newest = first
    newest.albums[0].name = "saved before switching"
    newest.albums[0].excluded = ["excluded-photo"]
    newest.pending = ["previously-paid-call": "preserved-request-id"]
    let firstSnapshot = first, newestSnapshot = newest
    search.prepareIdentity("a"); search.preferences = first
    _ = writes.enqueue(owner: "a") {
      await firstGate.wait()
      try await repositoryA.write(firstSnapshot, id: "preferences")
    }
    _ = writes.enqueue(owner: "a") {
      await secondGate.wait()
      try await repositoryA.write(newestSnapshot, id: "preferences")
    }
    await firstGate.waitUntilEntered()
    search.prepareIdentity("b")
    XCTAssertTrue(search.preferences.albums.isEmpty, "Identity changes must still clear UI immediately")
    var b = SearchPreferences(); b.geo = true
    let bSnapshot = b
    try await writes.enqueue(owner: "b") { try await repositoryB.write(bSnapshot, id: "preferences") }.value
    let loadedB = try await writes.read(owner: "b", repository: repositoryB)
    XCTAssertTrue(loadedB.geo, "B must not wait behind A's disk writes")
    search.prepareIdentity("a")
    XCTAssertTrue(search.preferences.albums.isEmpty)
    var finishedRead = false
    let returning = Task {
      let result = try await writes.read(owner: "a", repository: repositoryA)
      finishedRead = true
      return result
    }
    await firstGate.release()
    await secondGate.waitUntilEntered()
    await Task.yield()
    XCTAssertFalse(finishedRead, "The returning owner must wait for T2, even after T1 committed")
    await secondGate.release()
    search.preferences = try await returning.value
    XCTAssertEqual(search.preferences.albums.first?.name, "saved before switching")
    XCTAssertEqual(search.preferences.albums.first?.excluded, ["excluded-photo"])
    XCTAssertEqual(search.preferences.pending, newest.pending)
    // A subsequent toggle must not overwrite the last pre-switch album/exclusion snapshot.
    search.preferences.localAnalysisPaused = true
    let afterReturn = search.preferences
    try await writes.enqueue(owner: "a") { try await repositoryA.write(afterReturn, id: "preferences") }.value
    let reopened = try await SearchRepository(base: base, owner: "a").read(SearchPreferences.self, id: "preferences")
    XCTAssertEqual(reopened?.albums.first?.excluded, ["excluded-photo"])
    XCTAssertEqual(reopened?.pending, newest.pending)
    XCTAssertEqual(reopened?.localAnalysisPaused, true)
  }
  @MainActor func testFailedPreferenceSaveDoesNotPreventReturningToCommittedState() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = SearchRepository(base: base, owner: "a"), writes = SearchPreferenceWrites()
    var committed = SearchPreferences(); committed.pending = ["paid-call": "original-id"]
    try await repository.write(committed, id: "preferences")
    let failed = writes.enqueue(owner: "a") { throw CommitFailure.interrupted }
    do { try await failed.value; XCTFail("Injected failure must be observable by its caller") } catch { }
    let restored = try await writes.read(owner: "a", repository: repository)
    XCTAssertEqual(restored.pending, committed.pending)
  }
  private actor PreferenceWriteGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func wait() async {
      entered = true
      for waiter in entryWaiters { waiter.resume() }; entryWaiters = []
      if !released { await withCheckedContinuation { blocked = $0 } }
    }
    func waitUntilEntered() async {
      if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
  }
  @MainActor func testForegroundIdleAndInteractionCancellation() async throws {
    let scheduler = LibraryWorkScheduler(idleDelay: .milliseconds(40), observeSystem: false)
    var started = 0, interrupted = 0
    scheduler.configure(work: {
      started += 1
      do { try await Task.sleep(for: .seconds(1)); return true }
      catch { interrupted += 1; return false }
    }, cancel: {})
    scheduler.update { $0.foreground = true }
    try await Task.sleep(for: .milliseconds(15))
    XCTAssertEqual(started, 0)
    scheduler.userDidInteract()
    try await Task.sleep(for: .milliseconds(15))
    XCTAssertEqual(started, 0, "Interaction must reset the idle delay")
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(started, 1)
    scheduler.update { $0.scrolling = true }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(interrupted, 1)
    try await Task.sleep(for: .milliseconds(70))
    XCTAssertEqual(started, 1, "No work may restart during scrolling")
    scheduler.update { $0.scrolling = false; $0.foreground = false }
  }
  @MainActor func testPausedDetailsPowerAndHeatPreventWork() async throws {
    let scheduler = LibraryWorkScheduler(idleDelay: .milliseconds(5), observeSystem: false)
    var started = 0
    scheduler.configure(work: { started += 1; return false }, cancel: {})
    scheduler.update { $0.foreground = true; $0.paused = true }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(started, 0)
    scheduler.update { $0.paused = false; $0.detailPresented = true }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(started, 0)
    scheduler.update { $0.detailPresented = false; $0.lowPower = true }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(started, 0)
    scheduler.update { $0.lowPower = false; $0.batteryLevel = 0.15 }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(started, 0)
    scheduler.update { $0.charging = true; $0.thermalAllowed = false }
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(started, 0)
    scheduler.update { $0.thermalAllowed = true }
    try await Task.sleep(for: .milliseconds(30)); XCTAssertEqual(started, 1)
    scheduler.invalidate()
  }
  func testCancelledSearchDoesNotReturnAWholeLibraryResult() async throws {
    let task = Task.detached {
      try Task.checkCancellation()
      return try SearchResultMatcher.results(query: .init(include: ["海边"]), items: (0..<50_000).map(Self.item), corrections: [:], analyses: [:], screenshots: [], excluded: [])
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled queries must not publish results") }
    catch { XCTAssertTrue(error is CancellationError) }
  }
  @MainActor func testNewQuerySupersedesOlderWorkAndResultsArePaged() async throws {
    let store = ArchiveStore(repository: JSONArchiveRepository(directory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)), library: TestLibrary(media: (0..<1_000).map(Self.item)))
    let search = PhotoSearchController()
    search.update(.init(city: "上海"), store: store)
    search.update(.init(city: "武汉"), store: store)
    await search.waitForResults()
    XCTAssertEqual(search.matchCount, 1_000)
    XCTAssertEqual(search.matches.count, 120)
    XCTAssertEqual(search.possible.count, 0)
    search.loadMore(possible: false)
    XCTAssertEqual(search.matches.count, 240)
    search.reset(store)
    await search.waitForResults()
    XCTAssertTrue(search.matches.isEmpty)
    XCTAssertEqual(search.matchCount, 0)
  }
  private static func item(_ n: Int) -> MediaItem {
    MediaItem(id: String(n), assetName: "", title: String(n), kind: .photo, originalDay: ArchiveDay(2025, 1, 1), originalPlace: Place(name: "武汉", latitude: nil, longitude: nil), source: "test", accessible: true)
  }
  private struct TestLibrary: PhotoLibraryProviding { let media: [MediaItem] }
}
