import XCTest

final class SearchUITests: XCTestCase {
  @MainActor func testSearchModifySaveAndReopen() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-reset-test-data"]
    app.launch()
    app.tabBars.buttons["找照片"].tap()
    let field = app.textFields["photo-search-input"].exists ? app.textFields["photo-search-input"] : app.textViews["photo-search-input"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    app.buttons["去年春节在武汉"].tap()
    XCTAssertTrue(app.staticTexts["search-conditions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["search-conditions"].label.contains("武汉"))
    app.buttons["保存搜索"].tap()
    let name = "武汉春节 UI " + UUID().uuidString.prefix(6)
    app.alerts.textFields.firstMatch.typeText(name)
    app.alerts.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    attach("搜索相册", app: app)
    app.buttons["重置"].tap()
    app.buttons["saved-search-menu"].tap()
    XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
    app.buttons[name].tap()
    XCTAssertTrue(app.staticTexts["search-conditions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["search-conditions"].label.contains("武汉"))
    app.buttons["修改条件"].tap()
    XCTAssertTrue(app.navigationBars["修改条件"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    app.buttons["搜索设置"].tap()
    XCTAssertTrue(app.navigationBars["任务与搜索设置"].waitForExistence(timeout: 5))
    let cloudToggle = app.switches["允许云端补充"]
    for _ in 0..<6 where !cloudToggle.isHittable { app.swipeUp() }
    XCTAssertTrue(cloudToggle.isHittable)
    XCTAssertEqual(app.switches["允许云端补充"].value as? String, "0")
    attach("搜索设置", app: app)
    app.buttons["完成"].tap()
  }
  @MainActor func testSearchAccessibleLayout() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-reset-test-data",
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    app.tabBars.buttons["找照片"].tap()
    XCTAssertTrue(app.buttons["搜索设置"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["创建故事（0）"].exists)
    XCTAssertFalse(app.buttons["保存搜索"].exists, "空搜索不应留下禁用的操作底栏")
    let controls = app.scrollViews["search-controls-scroll"]
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    let field = app.textFields["photo-search-input"].exists ? app.textFields["photo-search-input"] : app.textViews["photo-search-input"]
    XCTAssertTrue(field.isHittable)
    attach("搜索大字号空状态", app: app)
    field.tap()
    // Fixed date plus enough conditions to exceed the control viewport. This
    // intentionally produces the uncertain group without AI or network requests.
    field.typeText("2023-09-21 海边 山林 建筑 人物 日落 夜景 食物 聚餐")
    app.buttons["photo-search-submit"].tap()
    XCTAssertTrue(app.staticTexts["search-conditions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["search-conditions"].label.contains("2023-09-21"))
    XCTAssertTrue(app.staticTexts["search-conditions"].label.contains("聚餐"))

    let edit = app.buttons["修改条件"]
    reveal(edit, in: controls, app: app)
    edit.tap()
    let editor = app.navigationBars["修改条件"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: editor)], timeout: 5), .completed)

    let kind = app.descendants(matching: .any).matching(identifier: "search-result-kind").firstMatch
    reveal(kind, in: controls, app: app)
    kind.tap()
    let possible = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '可能相关' ")).firstMatch
    XCTAssertTrue(possible.waitForExistence(timeout: 5))
    possible.tap()
    let grid = app.collectionViews["media-grid"]
    let photo = app.cells["photo-sample-10"]
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    XCTAssertTrue(photo.isHittable, "长条件不能把搜索结果挤出屏幕")
    XCTAssertGreaterThan(grid.frame.height, 140)
    XCTAssertLessThanOrEqual(controls.frame.maxY, grid.frame.minY + 1)
    XCTAssertTrue(app.buttons["保存搜索"].isHittable)
    attach("搜索大字号长条件与结果", app: app)

    // Moving just the controls must leave the result grid available for browsing.
    reveal(field, in: controls, app: app, downward: true)
    XCTAssertTrue(field.isHittable)
    XCTAssertTrue(photo.isHittable)
    attach("搜索大字号回到输入", app: app)
    photo.tap()
    XCTAssertTrue(app.buttons["photo-info"].waitForExistence(timeout: 5))
    attach("搜索大字号进入结果详情", app: app)
  }
  @MainActor private func reveal(_ element: XCUIElement, in scrollView: XCUIElement,
    app: XCUIApplication, downward: Bool = false) {
    for _ in 0..<16 {
      if element.exists && element.isHittable { return }
      // The scroll view's AX frame extends behind the navigation bar. XCTest's
      // default swipeDown starts there, so it never reaches the scroll gesture.
      let frame = scrollView.frame.intersection(app.frame)
      let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY) + 12
      let bottom = min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12
      XCTAssertGreaterThan(bottom - top, 80, "控制区必须保留真实可拖动的可见空间")
      let upper = top + (bottom - top) * 0.2
      let lower = top + (bottom - top) * 0.8
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: frame.midX, dy: downward ? upper : lower))
      let end = origin.withOffset(CGVector(dx: frame.midX, dy: downward ? lower : upper))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    XCTFail("大字号控制区中的 \(element.identifier) 应可通过滚动触达")
  }
  @MainActor private func attach(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
}
