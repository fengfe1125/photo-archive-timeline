import XCTest
@testable import PhotoArchive

final class SearchTests: XCTestCase {
  func testMapClusteringKeepsPhotosAndBoundsMarkers() {
    let points = (0..<240).map { PhotoMapPoint(id: String($0), latitude: Double($0 % 120) - 60, longitude: Double($0) - 120) }
    let groups = PhotoMapCluster.build(points, limit: 40)
    XCTAssertLessThanOrEqual(groups.count, 40)
    XCTAssertEqual(Set(groups.flatMap(\.mediaIDs)), Set(points.map(\.id)))
    XCTAssertEqual(groups.flatMap(\.mediaIDs).count, points.count)
    XCTAssertTrue(PhotoMapCluster.build([PhotoMapPoint(id: "invalid", latitude: .nan, longitude: 0)]).isEmpty)
    XCTAssertEqual(PhotoMapCluster.build([PhotoMapPoint(id: "edge", latitude: 90, longitude: 180)]).first?.mediaIDs, ["edge"])
  }
  func testSpringFestivalBoundaryAndLeapYear() throws {
    let dates = try XCTUnwrap(SearchCalendar.springFestival(2025))
    XCTAssertEqual(dates.0, "2025-01-28")
    XCTAssertEqual(dates.1, "2025-02-12")
    XCTAssertNil(SearchCalendar.parse("2025-02-29"))
    XCTAssertNotNil(SearchCalendar.parse("2024-02-29"))
  }
  func testChineseConditionsAndIncrementalExpansion() throws {
    let now = SearchCalendar.parse("2026-09-24")!
    let q = LocalSearchParser.parse("找去年春节在武汉拍的照片", current: .init(), now: now)
    XCTAssertEqual(q.city, "武汉"); XCTAssertEqual(q.start, "2025-01-28"); XCTAssertEqual(q.end, "2025-02-12")
    XCTAssertEqual(q.unresolved, "")
    let dinner = LocalSearchParser.parse("只看聚餐", current: q, now: now)
    XCTAssertEqual(dinner.include, ["聚餐"]); XCTAssertEqual(dinner.city, "武汉")
    let exclude = LocalSearchParser.parse("去掉截图", current: dinner, now: now)
    XCTAssertEqual(exclude.exclude, ["截图"])
    let expanded = LocalSearchParser.parse("再扩大前后两天", current: exclude, now: now)
    XCTAssertEqual(expanded.start, "2025-01-26"); XCTAssertEqual(expanded.end, "2025-02-14")
    XCTAssertEqual(q.start, "2025-01-28")
  }
  func testAmbiguousFestivalAndComplexActionAreNotSilentlyLost() {
    XCTAssertTrue(LocalSearchParser.parse("武汉过年", current: .init()).needsYear)
    XCTAssertFalse(LocalSearchParser.parse("聚餐时有人举杯", current: .init()).unresolved.isEmpty)
  }
  func testMissingMetadataCannotBecomeCertainEvenWithJev() {
    var q = PhotoSearchQuery(); q.city = "武汉"; q.start = "2025-01-28"; q.end = "2025-02-12"; q.include = ["聚餐"]
    var a = SearchAnalysis(version: "1"); a.decisions[q.key] = 0.99
    XCTAssertEqual(SearchMatcher.match(q, day: nil, place: "", hour: nil, analysis: a, screenshot: false), .possible)
    XCTAssertEqual(SearchMatcher.match(q, day: "2025-01-29", place: "青岛市", hour: nil, analysis: a, screenshot: false), .excluded)
    XCTAssertEqual(SearchMatcher.match(q, day: "2025-01-29", place: "武汉市", hour: nil, analysis: a, screenshot: false), .match)
    XCTAssertEqual(SearchMatcher.match(q, day: "2025-02-13", place: "武汉市", hour: nil, analysis: a, screenshot: false), .excluded)
  }
  func testWeakLabelsRetainCandidatesAndExcludeScreenshotsLocally() {
    var q = PhotoSearchQuery(); q.include = ["海边"]; q.exclude = ["江边", "截图"]
    var a = SearchAnalysis(version: "1"); a.state = "ready"; a.labels = ["river"]
    XCTAssertEqual(SearchMatcher.match(q, day: nil, place: "", hour: nil, analysis: a, screenshot: false), .possible)
    XCTAssertEqual(SearchMatcher.match(q, day: nil, place: "", hour: nil, analysis: a, screenshot: true), .excluded)
  }
  func testCacheChangesWithQueryAndUnknownNightIsPossible() {
    var q = PhotoSearchQuery(); q.night = true
    XCTAssertEqual(SearchMatcher.match(q, day: nil, place: "", hour: nil, analysis: nil, screenshot: false), .possible)
    XCTAssertEqual(SearchMatcher.match(q, day: nil, place: "", hour: 13, analysis: nil, screenshot: false), .excluded)
    let key = q.key; q.exclude = ["截图"]; XCTAssertNotEqual(key, q.key)
  }
  func testInvalidCloudConditionsRejected() {
    var q = PhotoSearchQuery(); q.start = "2025-02-30"; XCTAssertThrowsError(try q.validate())
    q.start = "2025-03-01"; q.end = "2025-02-01"; XCTAssertThrowsError(try q.validate())
  }
  func testIndependentIndexPersistenceAndOwnerIsolation() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let a = try SearchRepository(base: base, owner: "a"), b = try SearchRepository(base: base, owner: "b")
    var p = SearchPreferences(); p.albums = [SearchAlbum(name: "春节", query: .init())]
    try a.write(p, id: "preferences")
    try a.write(SearchAnalysis(version: "version-1"), id: "photo-1")
    XCTAssertEqual(try a.read(SearchPreferences.self, id: "preferences")?.albums.first?.name, "春节")
    XCTAssertNil(try b.read(SearchPreferences.self, id: "preferences"))
    XCTAssertEqual(try SearchRepository(base: base, owner: "a").read(SearchAnalysis.self, id: "photo-1")?.version, "version-1")
    XCTAssertFalse(p.ai); XCTAssertFalse(p.geo)
  }
}
