import XCTest

/// Exercises UIKit reuse and real 120-item cursors with an isolated, deterministic library.
@MainActor final class LibraryPagingUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = [
        "-ui-testing", "-paging-test-library", "-reset-test-data",
        "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      ]
      app.launch()
      XCTAssertTrue(app.cells["photo-paging-0000"].waitForExistence(timeout: 15))
    }
  }

  func testCrossPageSelectionSaveReturnAndAppendPersist() {
    app.buttons["select-mode"].tap()
    app.cells["select-paging-0000"].tap()
    let second = reveal(130, selecting: true)
    second.tap()
    XCTAssertTrue(second.isSelected)
    XCTAssertTrue(app.buttons["用 2 张照片创建故事"].isEnabled)
    let anchorY = second.frame.midY
    screenshot("paging-selected-across-120")

    app.buttons["用 2 张照片创建故事"].tap()
    let title = app.textFields["story-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("分页验收故事")
    app.buttons["save-story"].tap()
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 5))
    XCTAssertTrue(second.isHittable, "保存后应回到原来的图库位置")
    XCTAssertEqual(second.frame.midY, anchorY, accuracy: 24, "保存不能把图库跳回第一页")
    XCTAssertTrue(second.isSelected)

    openSavedStory()
    assertStoryContains([0, 130])
    app.buttons["edit-story"].tap()
    let addPhotos = app.buttons["story-add-photos"]
    for _ in 0..<6 where !addPhotos.isHittable { app.swipeUp() }
    XCTAssertTrue(addPhotos.isHittable)
    addPhotos.tap()
    XCTAssertTrue(app.navigationBars["添加照片"].waitForExistence(timeout: 5))
    let third = reveal(245, selecting: true)
    third.tap()
    app.buttons["完成（1）"].tap()
    XCTAssertTrue(app.buttons["save-story"].waitForExistence(timeout: 5))
    app.buttons["save-story"].tap()
    assertStoryContains([0, 130, 245])
    screenshot("paging-story-appended-across-240")

    app.terminate()
    app.launchArguments.removeAll { $0 == "-reset-test-data" }
    app.launch()
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 15))
    openSavedStory()
    assertStoryContains([0, 130, 245])
    screenshot("paging-story-after-relaunch")
  }

  func testDetailLoadsNextCursorAndReturnsToGridAnchor() {
    // Stop before grid prefetch begins at item 96, then reach the next page in detail.
    _ = reveal(78)
    let grid = visibleGrid()
    let visible = visibleNumbers(in: grid, selecting: false)
    XCTAssertLessThan(visible.max() ?? 1_000, 96, "此测试必须从网格尚未预取第二页的位置进入详情")
    let initial = visible.max() ?? 78
    let photo = app.cells[identifier(initial)]
    let anchorY = photo.frame.midY
    photo.tap()
    XCTAssertTrue(app.navigationBars[title(initial)].waitForExistence(timeout: 5))
    for index in (initial + 1)...122 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.45))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
      XCTAssertTrue(app.navigationBars[title(index)].waitForExistence(timeout: 5), "详情应继续到 \(title(index))")
    }
    screenshot("paging-detail-loaded-second-page")
    for index in stride(from: 121, through: 119, by: -1) {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.45))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
      XCTAssertTrue(app.navigationBars[title(index)].waitForExistence(timeout: 5), "反向跨页应回到 \(title(index))")
    }
    screenshot("paging-detail-returned-across-cursor-boundary")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 5))
    XCTAssertTrue(photo.isHittable, "详情返回应保留网格锚点")
    XCTAssertEqual(photo.frame.midY, anchorY, accuracy: 24)
  }

  private func openSavedStory() {
    app.tabBars.buttons["故事"].tap()
    let story = app.staticTexts["分页验收故事"]
    XCTAssertTrue(story.waitForExistence(timeout: 10))
    story.tap()
    XCTAssertTrue(app.buttons["edit-story"].waitForExistence(timeout: 5))
  }

  private func assertStoryContains(_ indices: [Int]) {
    XCTAssertTrue(app.staticTexts["story-count"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["story-count"].label, "\(indices.count) 张照片")
    let frames = indices.map { index -> CGRect in
      let photo = app.cells[identifier(index)]
      XCTAssertTrue(photo.waitForExistence(timeout: 5))
      XCTAssertTrue(photo.isHittable)
      return photo.frame
    }
    for index in 1..<frames.count {
      let previous = frames[index - 1], current = frames[index]
      XCTAssertTrue(current.midY > previous.midY + 2 ||
        (abs(current.midY - previous.midY) <= 2 && current.midX > previous.midX),
        "继续添加应保留原有顺序，并把新照片追加到末尾")
    }
  }

  private func reveal(_ index: Int, selecting: Bool = false) -> XCUIElement {
    let element = app.cells[identifier(index, selecting: selecting)]
    for _ in 0..<100 {
      let grid = visibleGrid()
      let safeFrame = grid.frame.insetBy(dx: 0, dy: 18)
      if element.exists && element.isHittable && safeFrame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
        return element
      }
      // Direction needs only the first exposed cell, not a separate AX request
      // for every visible cell on every scroll step.
      let prefix = selecting ? "select-paging-" : "photo-paging-"
      let first = grid.cells.firstMatch.identifier
      let firstNumber = first.hasPrefix(prefix) ? Int(first.dropFirst(prefix.count)) : nil
      let downward = index < (firstNumber ?? 0)
      let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.25 : 0.75))
      let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.75 : 0.25))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    XCTFail("滚动分页图库后仍找不到 \(identifier(index, selecting: selecting))")
    return element
  }

  private func visibleGrid() -> XCUIElement {
    let grids = app.collectionViews.matching(identifier: "media-grid")
    if !grids.firstMatch.exists { XCTAssertTrue(grids.firstMatch.waitForExistence(timeout: 5)) }
    guard let grid = grids.allElementsBoundByIndex.first(where: \.isHittable) else {
      XCTFail("原生 UICollectionView 必须可见并可交互")
      return grids.firstMatch
    }
    return grid
  }

  private func visibleNumbers(in grid: XCUIElement, selecting: Bool) -> [Int] {
    let prefix = selecting ? "select-paging-" : "photo-paging-"
    return grid.cells.allElementsBoundByIndex.compactMap { cell in
      guard cell.identifier.hasPrefix(prefix), cell.isHittable else { return nil }
      return Int(cell.identifier.dropFirst(prefix.count))
    }.sorted()
  }

  private func identifier(_ index: Int, selecting: Bool = false) -> String {
    (selecting ? "select-paging-" : "photo-paging-") + String(format: "%04d", index)
  }

  private func title(_ index: Int) -> String { "分页照片 " + String(format: "%04d", index) }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
