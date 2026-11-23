import XCTest
import UIKit
@testable import PhotoArchive

final class MediaPipelineTests: XCTestCase {
  private func item(accessible: Bool = false) -> MediaItem {
    MediaItem(id: "photo-1", assetName: "", title: "Photo", kind: .photo, originalDay: ArchiveDay(2020, 1, 1), originalPlace: nil,
              source: "test", localIdentifier: "local-1", accessible: accessible)
  }
  func testRepresentationKeySeparatesOwnerSizeAndPhotoContentEdits() {
    let item = item()
    let key = MediaImageKey(item: item, pixels: CGSize(width: 360, height: 360), namespace: "a")
    XCTAssertNotEqual(key, MediaImageKey(item: item, pixels: CGSize(width: 240, height: 240), namespace: "a"))
    XCTAssertNotEqual(key, MediaImageKey(item: item, pixels: CGSize(width: 360, height: 360), namespace: "b"))
    var edited = item; edited.modificationDate = Date(timeIntervalSince1970: 5)
    XCTAssertNotEqual(key, MediaImageKey(item: edited, pixels: CGSize(width: 360, height: 360), namespace: "a"))
    var local = item; local.accessible = true
    XCTAssertNotEqual(key, MediaImageKey(item: local, pixels: CGSize(width: 360, height: 360), namespace: "a"))
  }
  func testOldArchiveWithoutPhotoVersionStillDecodes() throws {
    let bytes = try JSONEncoder().encode(item())
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    json.removeValue(forKey: "modificationDate")
    let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(decoded.modificationDate)
    XCTAssertEqual(decoded.id, "photo-1")
    XCTAssertEqual(decoded.localIdentifier, "local-1")
  }
  @MainActor func testRemoteDownsampleBoundsDecodedPixels() throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
      UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    }
    let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    let thumbnail = try XCTUnwrap(MediaPipeline.downsample(bytes, maximumPixelSize: 160))
    XCTAssertLessThanOrEqual(max(thumbnail.cgImage!.width, thumbnail.cgImage!.height), 160)
    XCTAssertLessThanOrEqual(MediaPipeline.byteCost(thumbnail), 160 * 160 * 8)
  }
  @MainActor func testSharedRequestSurvivesOneSubscriberCancellationAndCachesFinalImage() async throws {
    let gate = RemoteImageGate()
    let pipeline = MediaPipeline(remoteLoader: { _ in try await gate.load() })
    let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
      UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    let data = try XCTUnwrap(image.pngData())
    var cancelledReceived = false
    var delivered: UIImage?
    let first = pipeline.thumbnail(item: item(), pixels: CGSize(width: 30, height: 30), namespace: "a", remoteURL: { _ in URL(string: "https://example.invalid/test") }) { _ in cancelledReceived = true }
    pipeline.thumbnail(item: item(), pixels: CGSize(width: 30, height: 30), namespace: "a", remoteURL: { _ in XCTFail("duplicate URL resolution"); return nil }) { delivered = $0 }
    XCTAssertEqual(pipeline.activeRequestCount, 1)
    pipeline.cancel(first)
    await gate.finish(data)
    for _ in 0..<200 where delivered == nil { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertNotNil(delivered)
    XCTAssertFalse(cancelledReceived)
    let requests = await gate.count
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(pipeline.activeRequestCount, 0)
    var cacheHit = false
    pipeline.thumbnail(item: item(), pixels: CGSize(width: 30, height: 30), namespace: "a", remoteURL: { _ in XCTFail("cached image resolved URL again"); return nil }) { cacheHit = $0 != nil }
    XCTAssertTrue(cacheHit)
    pipeline.clear()
  }
  @MainActor func testCancelledLastSubscriberCannotPublishLateImage() async throws {
    let gate = RemoteImageGate()
    let pipeline = MediaPipeline(remoteLoader: { _ in try await gate.load() })
    var published = false
    let ticket = pipeline.thumbnail(item: item(), pixels: CGSize(width: 30, height: 30), namespace: "a", remoteURL: { _ in URL(string: "https://example.invalid/test") }) { _ in published = true }
    pipeline.cancel(ticket)
    XCTAssertEqual(pipeline.activeRequestCount, 0)
    await gate.finish(Data())
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(published)
    pipeline.clear()
  }
}

private actor RemoteImageGate {
  private var completion: CheckedContinuation<Data, Error>?
  private var result: Data?
  private(set) var count = 0
  func load() async throws -> Data {
    count += 1
    if let result { return result }
    return try await withCheckedThrowingContinuation { completion = $0 }
  }
  func finish(_ data: Data) { result = data; completion?.resume(returning: data); completion = nil }
}
