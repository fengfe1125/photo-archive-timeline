import XCTest

@testable import PhotoArchive

final class ArchiveTests: XCTestCase {
  func testStoryNormalizesCoverDuplicatesAndCount() {
    var story = Story(
      title: "测试", mediaIDs: ["sample-10", "sample-10", "sample-11"], coverID: "missing")
    story.normalize()
    XCTAssertEqual(story.count, 2)
    XCTAssertEqual(story.coverID, "sample-10")
    story.remove("sample-10")
    XCTAssertEqual(story.coverID, "sample-11")
    XCTAssertEqual(SampleLibrary().media.count, 7)
    story.remove("sample-11")
    XCTAssertNil(story.coverID)
  }
  func testDraftCancellationDoesNotMutateOriginal() {
    let original = SampleLibrary.seed.stories[0]
    var draft = original
    draft.title = "不保存"
    draft.remove("sample-10")
    XCTAssertEqual(original.count, 6)
    XCTAssertEqual(original.title, "风吹过河谷")
  }
  func testAnniversaryExcludesCurrentYearAndMatchesLeapDayExactly() {
    XCTAssertTrue(ArchiveDay(2020, 2, 29).isAnniversary(of: ArchiveDay(2024, 2, 29)))
    XCTAssertFalse(ArchiveDay(2020, 2, 29).isAnniversary(of: ArchiveDay(2024, 2, 28)))
    XCTAssertFalse(ArchiveDay(2024, 2, 29).isAnniversary(of: ArchiveDay(2024, 2, 29)))
    XCTAssertFalse(ArchiveDay(2028, 2, 29).isAnniversary(of: ArchiveDay(2024, 2, 29)))
  }
  func testPersistenceReloadAndResetBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repo = JSONArchiveRepository(directory: directory)
    var data = try await repo.load()
    data.stories[0].title = "跨重启保留"
    data.stories[0].mediaIDs.reverse()
    data.stories[0].coverID = "sample-10"
    try await repo.save(data)
    let reloaded = try await JSONArchiveRepository(directory: directory).load()
    XCTAssertEqual(reloaded, data)
    let reset = try await repo.reset()
    XCTAssertEqual(reset, SampleLibrary.seed)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("backup-")
      })
  }
  func testCorruptionIsNotSilentlyOverwritten() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("archive-v1.json")
    let corrupt = Data("broken".utf8)
    try corrupt.write(to: file)
    do {
      _ = try await JSONArchiveRepository(directory: directory).load()
      XCTFail("Should reject")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }
  func testRejectsInvalidVersionAndCover() throws {
    var data = SampleLibrary.seed
    data.version = 2
    XCTAssertThrowsError(try data.validate(mediaIDs: Set(SampleLibrary().media.map(\.id))))
    data.version = 1
    data.stories[0].coverID = "missing"
    XCTAssertThrowsError(try data.validate(mediaIDs: Set(SampleLibrary().media.map(\.id))))
  }
  func testInvalidCalendarDateAndCoordinatesAreRejected() {
    XCTAssertFalse(ArchiveDay(2023, 2, 29).isValid)
    XCTAssertTrue(ArchiveDay(2024, 2, 29).isValid)
    var data = SampleLibrary.seed
    data.corrections["sample-10"] = MetadataCorrection(
      mediaID: "sample-10", originalDay: nil, originalPlace: nil, day: ArchiveDay(2023, 2, 29),
      place: nil, description: "")
    XCTAssertThrowsError(try data.validate(mediaIDs: Set(SampleLibrary().media.map(\.id))))
    data.corrections["sample-10"]?.day = nil
    data.corrections["sample-10"]?.place = Place(name: "坏坐标", latitude: 180, longitude: 0)
    XCTAssertThrowsError(try data.validate(mediaIDs: Set(SampleLibrary().media.map(\.id))))
  }
  @MainActor func testCorrectionRestoreAndUnknownDate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ArchiveStore(repository: JSONArchiveRepository(directory: directory))
    await store.load()
    let item = store.media[0]
    let correction = MetadataCorrection(
      mediaID: item.id, originalDay: item.originalDay, originalPlace: item.originalPlace,
      day: ArchiveDay(2020, 2, 29), place: nil, description: "已修正")
    let saved = await store.saveCorrection(correction, for: item.id)
    XCTAssertTrue(saved)
    XCTAssertEqual(store.day(item), ArchiveDay(2020, 2, 29))
    XCTAssertNil(store.place(item), "Cleared place must not silently fall back to original GPS")
    XCTAssertFalse(store.memories(on: ArchiveDay(2026, 9, 21)).contains { $0.id == "sample-15" })
    let restored = await store.saveCorrection(nil, for: item.id)
    XCTAssertTrue(restored)
    XCTAssertEqual(store.day(item), item.originalDay)
    XCTAssertEqual(store.place(item), item.originalPlace)
  }
  @MainActor func testFailedSavePreservesSavedStateAndDraft() async {
    let store = ArchiveStore(repository: FailingRepository())
    await store.load()
    var draft = store.snapshot.stories[0]
    draft.title = "保留草稿"
    let result = await store.saveStory(draft)
    XCTAssertFalse(result)
    XCTAssertEqual(draft.title, "保留草稿")
    XCTAssertEqual(store.snapshot, SampleLibrary.seed)
    XCTAssertNotNil(store.error)
  }
  func testUnconnectedServicesNeverReportSuccess() async {
    do {
      try await UnconnectedServices().synchronize()
      XCTFail("No backend")
    } catch {}
    do {
      try await UnconnectedServices().signIn(email: "test@example.com")
      XCTFail("No backend")
    } catch {}
  }
  @MainActor func testDemoSyncIsSharedAndExplicitlyLabeled() async {
    let store = ArchiveStore(repository: FailingRepository())
    store.demoSync = .ready
    await store.runDemoSync(fail: true)
    XCTAssertEqual(store.demoSync, .failed)
    await store.runDemoSync(fail: false)
    XCTAssertEqual(store.demoSync, .complete)
    XCTAssertTrue(store.demoSync.rawValue.contains("未连接云端"))
  }
}

private actor FailingRepository: ArchiveRepository {
  func load() -> ArchiveSnapshot { SampleLibrary.seed }
  func save(_ snapshot: ArchiveSnapshot) throws { throw CocoaError(.fileWriteNoPermission) }
  func reset() -> ArchiveSnapshot { SampleLibrary.seed }
}
