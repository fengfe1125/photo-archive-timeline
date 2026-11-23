import XCTest
import UIKit
@testable import PhotoArchive

final class SearchVisionTests: XCTestCase {
  @MainActor func testProductionClassifierEvidenceSurvivesRestart() async throws {
    let image = try XCTUnwrap(UIImage(named: "Sample10", in: Bundle.main, compatibleWith: nil))
    let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    let input = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.jpeg")
    input.name = "Vision classifier public fixture"; input.lifetime = .keepAlways; add(input)
    let labels = try await SearchVisionWorker.shared.classify(bytes)
    XCTAssertFalse(labels.isEmpty)
    // Apple ships the classifier model with the OS. Missing lake evidence must
    // remain possible, rather than inventing certainty for this lake fixture.
    var analysis = SearchAnalysis(version: "fixture")
    analysis.labels = labels; analysis.state = "ready"
    let query = LocalSearchParser.parse("湖边", current: .init())
    let expected: SearchMatch = labels.contains(where: { $0.contains("lake") }) ? .match : .possible
    let originalMatch = SearchMatcher.match(query, day: nil, place: "", hour: nil, analysis: analysis, screenshot: false)
    XCTAssertEqual(originalMatch, expected, "Only actual lake evidence can establish a certain match: \(labels)")
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = SearchRepository(base: base, owner: "fixture-user")
    try await repository.write(analysis, id: "sample10")
    let stored = try await SearchRepository(base: base, owner: "fixture-user").read(SearchAnalysis.self, id: "sample10")
    let restored = try XCTUnwrap(stored)
    XCTAssertEqual(restored.labels, labels)
    XCTAssertFalse(restored.needsLocalVision, "A persisted result must not require another classification")
    XCTAssertEqual(SearchMatcher.match(query, day: nil, place: "", hour: nil, analysis: restored, screenshot: false), originalMatch, "Persisted evidence must remain usable before city lookup completes")
    var cityQuery = query; cityQuery.city = "武汉"
    XCTAssertEqual(SearchMatcher.match(cityQuery, day: nil, place: "", hour: nil, analysis: restored, screenshot: false), .possible, "Missing city evidence must not become a confirmed location match")

  }
  func testFailedPhotoReasonSurvivesRestart() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    var analysis = SearchAnalysis(version: "fixture")
    analysis.state = "waiting"; analysis.failureReason = "读取图片超时，可稍后重试"
    try await SearchRepository(base: base, owner: "fixture-user").write(analysis, id: "unavailable")
    let stored = try await SearchRepository(base: base, owner: "fixture-user").read(SearchAnalysis.self, id: "unavailable")
    let restored = try XCTUnwrap(stored)
    XCTAssertEqual(restored.failureReason, analysis.failureReason)
    XCTAssertTrue(restored.needsLocalVision)
  }

}
