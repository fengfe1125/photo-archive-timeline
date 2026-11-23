import XCTest
@testable import PhotoArchive

final class LibraryNavigationTests: XCTestCase {
  @MainActor func testCancelledDetailTaskKeepsSharedNextPageAndBrowsingCanContinue() async throws {
    let source = ControlledLibraryPages()
    let context = LibraryNavigationContext(currentOwner: { "guest" }, readPage: source.read)
    let initial = Task { await context.loadNext() }
    try await waitUntil { source.count == 1 }
    try source.finish(0, with: .success(page(1...120, more: true)))
    await initial.value

    // Swiping 118 -> 119 -> 120 replaces SwiftUI's task while storage is busy.
    let firstDetailTask = Task { await context.loadNext() }
    try await waitUntil { source.count == 2 }
    firstDetailTask.cancel()
    var secondStarted = false
    let nextDetailTask = Task { secondStarted = true; await context.loadNext() }
    try await waitUntil { secondStarted }
    nextDetailTask.cancel()
    var thirdStarted = false
    let finalDetailTask = Task { thirdStarted = true; await context.loadNext() }
    try await waitUntil { thirdStarted }
    XCTAssertEqual(source.count, 2, "All detail tasks must join the same page request")
    XCTAssertTrue(context.loading)
    XCTAssertEqual(source.cursor(at: 1)?.mediaID, "120")
    try source.finish(1, with: .success(page(121...240, more: true)))
    await firstDetailTask.value; await nextDetailTask.value; await finalDetailTask.value
    XCTAssertEqual(context.mediaIDs, (1...240).map(String.init))
    XCTAssertFalse(context.loading)
    XCTAssertTrue(context.hasMore)
    XCTAssertNil(context.error)

    let followingPage = Task { await context.loadNext() }
    try await waitUntil { source.count == 3 }
    XCTAssertEqual(source.cursor(at: 2)?.mediaID, "240")
    try source.finish(2, with: .success(page(241...243, more: false)))
    await followingPage.value
    XCTAssertEqual(context.mediaIDs, (1...243).map(String.init))
    XCTAssertFalse(context.hasMore)
  }

  @MainActor func testReloadInvalidatesSlowPageWithoutAllowingLateResultsToReplaceNewWindow() async throws {
    let source = ControlledLibraryPages()
    let context = LibraryNavigationContext(currentOwner: { "guest" }, readPage: source.read)
    let obsolete = Task { await context.loadNext() }
    try await waitUntil { source.count == 1 }
    let refresh = Task { await context.reload() }
    try await waitUntil { source.count == 2 }
    XCTAssertNil(source.cursor(at: 1))
    try source.finish(1, with: .success(page(201...203, more: false)))
    await refresh.value
    XCTAssertEqual(context.mediaIDs, ["201", "202", "203"])
    // The source deliberately ignores cancellation until its continuation ends.
    try source.finish(0, with: .success(page(1...120, more: true)))
    await obsolete.value
    XCTAssertEqual(context.mediaIDs, ["201", "202", "203"])
    XCTAssertFalse(context.loading)
    XCTAssertFalse(context.hasMore)
  }

  @MainActor func testOwnerChangeInvalidatesSharedPageAndDiscardsLatePreviousOwnerResult() async throws {
    let source = ControlledLibraryPages()
    var owner = "guest"
    let context = LibraryNavigationContext(currentOwner: { owner }, readPage: source.read)
    let pending = Task { await context.loadNext() }
    try await waitUntil { source.count == 1 }
    owner = "account-b"
    await context.loadNext()
    XCTAssertTrue(context.items.isEmpty)
    XCTAssertFalse(context.loading)
    try source.finish(0, with: .success(page(1...120, more: true)))
    await pending.value
    XCTAssertTrue(context.items.isEmpty)
    XCTAssertNil(context.nextCursor)
    XCTAssertFalse(context.hasMore)
    XCTAssertEqual(source.count, 1)
  }

  @MainActor func testStaleCursorRefreshesInsideSharedTaskWithoutSelfWaiting() async throws {
    let source = ControlledLibraryPages()
    let context = LibraryNavigationContext(currentOwner: { "guest" }, readPage: source.read)
    let initial = Task { await context.loadNext() }
    try await waitUntil { source.count == 1 }
    try source.finish(0, with: .success(page(1...120, more: true)))
    await initial.value
    let append = Task { await context.loadNext() }
    try await waitUntil { source.count == 2 }
    try source.finish(1, with: .failure(ArchiveStorageError.staleCursor))
    try await waitUntil { source.count == 3 }
    XCTAssertNil(source.cursor(at: 2), "A stale cursor must restart from the first page")
    try source.finish(2, with: .success(page(201...203, more: false)))
    await append.value
    XCTAssertEqual(context.mediaIDs, ["201", "202", "203"])
    XCTAssertFalse(context.loading)
    XCTAssertFalse(context.hasMore)
    XCTAssertNil(context.error)
  }

  private func page(_ range: ClosedRange<Int>, more: Bool) -> LibraryPage {
    let items = range.map { value in
      MediaItem(id: String(value), assetName: "", title: String(value), kind: .photo,
        originalDay: nil, originalPlace: nil, source: "test")
    }
    let cursor = more ? LibraryCursor(owner: "guest", revision: 1, query: LibraryQuery(), dayKey: 0,
      mediaID: String(range.upperBound)) : nil
    return LibraryPage(items: items, nextCursor: cursor, totalCount: 243, years: [], effectiveDays: [:])
  }

  @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard condition() else {
      XCTFail("The controlled page request did not reach the expected state", file: file, line: line)
      throw CancellationError()
    }
  }
}

@MainActor private final class ControlledLibraryPages {
  private struct Request {
    let cursor: LibraryCursor?
    var completion: CheckedContinuation<LibraryPage, Error>?
  }
  private var requests: [Request] = []
  var count: Int { requests.count }
  func cursor(at index: Int) -> LibraryCursor? { requests[index].cursor }
  func read(_ query: LibraryQuery, _ cursor: LibraryCursor?, _ limit: Int) async throws -> LibraryPage {
    XCTAssertEqual(limit, 120)
    return try await withCheckedThrowingContinuation { requests.append(Request(cursor: cursor, completion: $0)) }
  }
  func finish(_ index: Int, with result: Result<LibraryPage, Error>) throws {
    let completion = try XCTUnwrap(requests[index].completion)
    requests[index].completion = nil
    completion.resume(with: result)
  }
}
