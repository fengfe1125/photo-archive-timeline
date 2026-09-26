import XCTest
import UIKit
@testable import PhotoArchive

final class SearchVisionTests: XCTestCase {
  @MainActor func testProductionClassifierFeedsLakeSearch() async throws {
    let image = try XCTUnwrap(UIImage(named: "Sample10", in: Bundle.main, compatibleWith: nil))
    let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    let labels = try await Task.detached { try SearchVisionClassifier.classify(bytes) }.value
    XCTAssertFalse(labels.isEmpty)
    // Visually verified fixture: a lake behind vegetation, with distant hills.
    var analysis = SearchAnalysis(version: "fixture")
    analysis.labels = labels; analysis.state = "ready"
    let query = LocalSearchParser.parse("湖边", current: .init())
    XCTAssertEqual(SearchMatcher.match(query, day: nil, place: "", hour: nil, analysis: analysis, screenshot: false), .match, "The production Vision output must reach the actual scene matcher: \(labels)")
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = try SearchRepository(base: base, owner: "fixture-user")
    try repository.write(analysis, id: "sample10")
    let restored = try XCTUnwrap(SearchRepository(base: base, owner: "fixture-user").read(SearchAnalysis.self, id: "sample10"))
    XCTAssertEqual(restored.labels, labels)
    XCTAssertFalse(restored.needsLocalVision, "A persisted result must not require another classification")
    XCTAssertEqual(SearchMatcher.match(query, day: nil, place: "", hour: nil, analysis: restored, screenshot: false), .match, "Scene results must remain usable before city lookup completes")
    var cityQuery = query; cityQuery.city = "武汉"
    XCTAssertEqual(SearchMatcher.match(cityQuery, day: nil, place: "", hour: nil, analysis: restored, screenshot: false), .possible, "Missing city evidence must not become a confirmed location match")

  }
  func testFailedPhotoReasonSurvivesRestart() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    var analysis = SearchAnalysis(version: "fixture")
    analysis.state = "waiting"; analysis.failureReason = "读取图片超时，可稍后重试"
    try SearchRepository(base: base, owner: "fixture-user").write(analysis, id: "unavailable")
    let restored = try XCTUnwrap(SearchRepository(base: base, owner: "fixture-user").read(SearchAnalysis.self, id: "unavailable"))
    XCTAssertEqual(restored.failureReason, analysis.failureReason)
    XCTAssertTrue(restored.needsLocalVision)
  }

}
