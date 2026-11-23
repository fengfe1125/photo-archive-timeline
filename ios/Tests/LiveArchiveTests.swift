import XCTest
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import PhotoArchive

final class LiveArchiveTests: XCTestCase {
  private let mediaID = "10000000-0000-0000-0000-000000000001"
  private let storyID = "20000000-0000-0000-0000-000000000001"
  private func fixture() -> LiveDocument {
    var document = LiveDocument()
    document.media[mediaID] = MediaItem(id: mediaID, assetName: "", title: "Private filename",
      kind: .photo, originalDay: ArchiveDay(2020, 2, 29),
      originalPlace: Place(name: "Private GPS", latitude: 31, longitude: 121), source: "/private/Photos",
      localIdentifier: "LOCAL-ONLY", accessible: true)
    return document
  }
  func testTransportAllowlistNeverContainsOriginalMetadata() throws {
    let correction = MetadataCorrection(mediaID: mediaID, originalDay: ArchiveDay(2020, 2, 29),
      originalPlace: Place(name: "Private GPS", latitude: 31, longitude: 121),
      day: nil, place: nil, description: "Caption", dayMode: .original, placeMode: .original)
    let op = SyncOperation(entity: "correction", entityID: mediaID, baseVersion: 0, payload: .correction(correction))
    let bytes = try JSONEncoder().encode(op.wire)
    let text = String(decoding: bytes, as: UTF8.self)
    for prohibited in ["originalDay", "originalPlace", "localIdentifier", "LOCAL-ONLY", "Private GPS", "assetName", "attempted"] {
      XCTAssertFalse(text.contains(prohibited), prohibited)
    }
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let payload = try XCTUnwrap(root["payload"] as? [String: Any])
    XCTAssertEqual(Set(payload.keys), ["description", "dayMode", "placeMode"])
  }
  func testOfflineEditsCoalesceButInflightOperationIsImmutable() {
    var document = fixture()
    let first = Story(id: storyID, title: "First", mediaIDs: [mediaID], coverID: mediaID)
    document.enqueue(entity: "story", id: storyID, payload: .story(first))
    let operationID = document.outbox[0].id
    var edit = first; edit.title = "Second"
    document.enqueue(entity: "story", id: storyID, payload: .story(edit))
    XCTAssertEqual(document.outbox.count, 1)
    document.outbox[0].attempted = true
    edit.title = "Third"
    document.enqueue(entity: "story", id: storyID, payload: .story(edit))
    XCTAssertEqual(document.outbox.count, 2)
    XCTAssertEqual(document.outbox[0].id, operationID)
    XCTAssertEqual(document.outbox[0].payload.title, "Second")
    document.accept(PushResult(status: "accepted", record: SyncRecord(entity: "story", id: storyID, version: 1, deleted: false, payload: document.outbox[0].payload)), operationID: operationID)
    XCTAssertEqual(document.outbox.count, 1)
    XCTAssertEqual(document.outbox[0].baseVersion, 1)
    XCTAssertEqual(document.outbox[0].payload.title, "Third")
  }
  func testPullDoesNotOverwritePendingLocalEdits() {
    var document = fixture()
    let local = Story(id: storyID, title: "Local", mediaIDs: [mediaID], coverID: mediaID)
    document.snapshot.stories = [local]
    document.enqueue(entity: "story", id: storyID, payload: .story(local))
    document.apply(SyncRecord(entity: "story", id: storyID, version: 2, deleted: true, payload: WirePayload()))
    XCTAssertEqual(document.snapshot.stories.first?.title, "Local")
    XCTAssertEqual(document.versions["story:\(storyID)"], 2)
    XCTAssertEqual(document.outbox[0].baseVersion, 0, "Must produce a conflict, not silently rebase an offline edit")
  }
  func testConflictSurvivesReloadAndResolutionRaceReplacesOldConflict() throws {
    var document = fixture()
    let local = SyncRecord(entity: "story", id: storyID, version: 1, deleted: false,
      payload: .story(Story(id: storyID, title: "Local", mediaIDs: [mediaID], coverID: mediaID)))
    let remote = SyncRecord(entity: "story", id: storyID, version: 2, deleted: true, payload: WirePayload())
    let conflict = SyncConflict(id: UUID().uuidString.lowercased(), local: local, remote: remote)
    document.conflicts = [conflict]
    document.enqueue(entity: "story", id: storyID, payload: local.payload, resolving: conflict.id)
    let operation = document.outbox[0]
    let newer = SyncConflict(id: operation.id, local: local,
      remote: SyncRecord(entity: "story", id: storyID, version: 3, deleted: true, payload: WirePayload()))
    document.accept(PushResult(status: "conflict", record: newer.remote, conflict: newer), operationID: operation.id)
    let reloaded = try JSONDecoder().decode(LiveDocument.self, from: JSONEncoder().encode(document))
    XCTAssertEqual(reloaded.conflicts, [newer])
    XCTAssertTrue(reloaded.outbox.isEmpty)
  }
  func testCanonicalMediaRemapsStoryCoverCorrectionAndQueue() {
    var document = fixture()
    let canonical = UUID().uuidString.lowercased()
    let story = Story(id: storyID, title: "Trip", mediaIDs: [mediaID], coverID: mediaID)
    document.snapshot.stories = [story]
    document.enqueue(entity: "story", id: storyID, payload: .story(story))
    document.remapMedia(from: mediaID, to: canonical)
    XCTAssertNil(document.media[mediaID])
    XCTAssertEqual(document.media[canonical]?.localIdentifier, "LOCAL-ONLY")
    XCTAssertEqual(document.snapshot.stories[0].coverID, canonical)
    XCTAssertEqual(document.outbox[0].payload.mediaIDs, [canonical])
    XCTAssertEqual(document.outbox[0].payload.coverID, canonical)
  }
  @MainActor func testSwiftDataAtomicSaveQueueAndAccountIsolation() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try LiveArchiveRepository(directory: directory)
    var doc = fixture()
    let story = Story(id: storyID, title: "Saved offline", mediaIDs: [mediaID], coverID: mediaID)
    doc.snapshot.stories = [story]
    doc.enqueue(entity: "story", id: storyID, payload: .story(story))
    try await repo.save(doc, owner: "guest")
    let reopened = try LiveArchiveRepository(directory: directory)
    let restored = try await reopened.load(owner: "guest")
    XCTAssertEqual(restored, doc)
    var invalid = doc; invalid.snapshot.stories[0].coverID = "missing"
    do { try await repo.save(invalid, owner: "guest"); XCTFail("Invalid transaction must fail") } catch {}
    let unchanged = try await repo.load(owner: "guest")
    XCTAssertEqual(unchanged, doc)
    let account = try await repo.adoptGuest(into: "account-a")
    XCTAssertTrue(account.syncEnabled)
    XCTAssertEqual(account.outbox, doc.outbox)
    let guest = try await repo.load(owner: "guest")
    let other = try await repo.load(owner: "account-b")
    let saved = try await repo.load(owner: "account-a")
    XCTAssertTrue(guest.snapshot.stories.isEmpty)
    XCTAssertTrue(other.outbox.isEmpty)
    XCTAssertEqual(saved.snapshot, doc.snapshot)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("guest-backup-") })
  }
  @MainActor func testUnifiedSaveGateRejectsConcurrentCommandsAndReopensAfterFailure() async throws {
    let repository = SuspendedArchiveSaveRepository()
    let store = ArchiveStore(repository: repository)
    await store.load()
    var story = store.snapshot.stories[0]; story.title = "First submission"
    let first = Task { await store.saveStory(story) }
    await repository.waitUntilSaving()
    XCTAssertTrue(store.saving)
    let duplicate = await store.saveStory(story)
    let correction = await store.saveCorrection(nil, for: "sample-10")
    let removal = await store.deleteStory(story.id)
    XCTAssertFalse(duplicate); XCTAssertFalse(correction); XCTAssertFalse(removal)
    let count = await repository.calls
    XCTAssertEqual(count, 1, "Only the admitted submission may reach storage")
    await repository.finish(failing: false)
    let firstResult = await first.value
    XCTAssertTrue(firstResult); XCTAssertFalse(store.saving)
    XCTAssertEqual(store.snapshot.stories[0].title, "First submission")
    let failed = Task { await store.deleteStory(story.id) }
    await repository.waitUntilSaving()
    XCTAssertTrue(store.saving)
    await repository.finish(failing: true)
    let failedResult = await failed.value
    XCTAssertFalse(failedResult); XCTAssertFalse(store.saving)
    XCTAssertEqual(store.snapshot.stories.count, 1, "A failure must preserve the saved document")
    let retry = Task { await store.saveCorrection(nil, for: "sample-10") }
    await repository.waitUntilSaving()
    await repository.finish(failing: false)
    let retried = await retry.value
    XCTAssertTrue(retried); XCTAssertFalse(store.saving)
  }

  @MainActor func testShareBitmapStripsPrivateMetadataAndCanBeCleaned() throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
      UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
    let original = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil))
    let metadata: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 121.4, kCGImagePropertyGPSLongitudeRef: "E"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:02:29 12:34:56", kCGImagePropertyExifUserComment: "private-note"],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private-owner"]
    ]
    CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), metadata as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let sourceImage = try XCTUnwrap(UIImage(data: original as Data))
    let url = try PrivacyShare.make(image: sourceImage)
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal as String])
    XCTAssertNil(exif[kCGImagePropertyExifUserComment as String])
    XCTAssertNil(tiff[kCGImagePropertyTIFFArtist as String])
    // ImageIO may add pixel dimensions / color space to the new encoding.
    XCTAssertTrue(Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]))
  }
  @MainActor func testOriginalClearAndValueHaveDistinctDisplayBehavior() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ArchiveStore(repository: JSONArchiveRepository(directory: directory))
    await store.load()
    let item = store.media[0]
    var correction = MetadataCorrection(mediaID: item.id, originalDay: item.originalDay, originalPlace: item.originalPlace,
      day: nil, place: nil, description: "Caption", dayMode: .original, placeMode: .original)
    _ = await store.saveCorrection(correction, for: item.id)
    XCTAssertEqual(store.day(item), item.originalDay)
    XCTAssertEqual(store.place(item), item.originalPlace)
    correction.dayMode = .clear; correction.placeMode = .clear
    _ = await store.saveCorrection(correction, for: item.id)
    XCTAssertNil(store.day(item)); XCTAssertNil(store.place(item))
    correction.dayMode = .value; correction.day = ArchiveDay(2020, 2, 29)
    _ = await store.saveCorrection(correction, for: item.id)
    XCTAssertEqual(store.day(item), ArchiveDay(2020, 2, 29))
  }
}

private actor SuspendedArchiveSaveRepository: ArchiveRepository {
  private var snapshot = SampleLibrary.seed
  private var pending: CheckedContinuation<Void, Error>?
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private(set) var calls = 0
  func load() async throws -> ArchiveSnapshot { snapshot }
  func reset() async throws -> ArchiveSnapshot { snapshot }
  func save(_ value: ArchiveSnapshot) async throws {
    calls += 1
    try await withCheckedThrowingContinuation { continuation in
      pending = continuation
      let ready = waiting; waiting = []
      for waiter in ready { waiter.resume() }
    }
    snapshot = value
  }
  func waitUntilSaving() async {
    guard pending == nil else { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func finish(failing: Bool) {
    let continuation = pending; pending = nil
    if failing { continuation?.resume(throwing: ArchiveError.invalidData) }
    else { continuation?.resume() }
  }
}
