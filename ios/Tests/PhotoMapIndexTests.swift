import XCTest
@testable import PhotoArchive

final class PhotoMapIndexTests: XCTestCase {
  func testEditsRebuildAffectedRegionsAndOwnerSwitchClearsOldPhotos() async throws {
    let index = PhotoMapIndex()
    var items = [photo("a", 30, 120), photo("b", 31, 121), photo("c", 31.001, 121.001)]
    let before = try await index.update(owner: "first", items: items, corrections: [:])
    let untouched = try XCTUnwrap(before.first { $0.mediaIDs.contains("b") })
    items[0] = photo("a", 32, 122)
    let after = try await index.update(owner: "first", items: items, corrections: [:])
    let unchanged = try XCTUnwrap(after.first { $0.id == untouched.id })
    XCTAssertEqual(unchanged.mediaIDs, untouched.mediaIDs)
    XCTAssertEqual(unchanged.latitude, untouched.latitude)
    XCTAssertEqual(unchanged.longitude, untouched.longitude)
    XCTAssertEqual(Set(after.flatMap(\.mediaIDs)), ["a", "b", "c"])
    let nextOwner = try await index.update(owner: "second", items: [photo("d", 0, 0)], corrections: [:])
    XCTAssertEqual(nextOwner.flatMap(\.mediaIDs), ["d"])
  }

  func testCorrectionsDeletionAndMarkerBudgetPreserveAllReferences() async throws {
    let index = PhotoMapIndex()
    let items = (0..<1_000).map { photo("\($0)", Double($0 % 170) - 85, Double($0 % 350) - 175) }
    let original = try await index.update(owner: "owner", items: items, corrections: [:], limit: 20)
    XCTAssertLessThanOrEqual(original.count, 20)
    XCTAssertEqual(Set(original.flatMap(\.mediaIDs)), Set(items.map(\.id)))
    let first = items[0]
    let cleared = MetadataCorrection(mediaID: first.id, originalDay: nil, originalPlace: first.originalPlace,
      day: nil, place: nil, description: "", dayMode: .original, placeMode: .clear)
    let updated = try await index.update(owner: "owner", items: Array(items.dropLast()), corrections: [first.id: cleared], limit: 20)
    XCTAssertEqual(Set(updated.flatMap(\.mediaIDs)), Set(items.dropFirst().dropLast().map(\.id)))
  }

  private func photo(_ id: String, _ latitude: Double, _ longitude: Double) -> MediaItem {
    MediaItem(id: id, assetName: "", title: id, kind: .photo, originalDay: nil,
      originalPlace: Place(name: id, latitude: latitude, longitude: longitude), source: "test")
  }
}
