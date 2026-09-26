import XCTest

@MainActor final class PhotoArchiveUITests: XCTestCase {
  var app: XCUIApplication!
  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = [
        "-ui-testing", "-reset-test-data", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      ]
      app.launch()
    }
  }
  func screenshot(_ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }
  func testPhotoSheetReturnsToSameDetailAndLibrary() {
    let photo = app.buttons["photo-sample-10"]
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    screenshot("01-library")
    photo.tap()
    app.buttons["photo-info"].tap()
    XCTAssertTrue(app.buttons["close-info"].waitForExistence(timeout: 5))
    screenshot("02-info-sheet")
    app.buttons["close-info"].tap()
    XCTAssertTrue(app.buttons["photo-info"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(photo.waitForExistence(timeout: 5))
    screenshot("03-return-library")
  }
  func testCreateStoryAndPersistence() {
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 10))
    app.buttons["select-mode"].tap()
    app.buttons["select-sample-10"].tap()
    app.buttons["select-sample-11"].tap()
    app.buttons["用 2 张照片创建故事"].tap()
    let title = app.textFields["story-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("QA story")
    screenshot("04-story-draft")
    app.buttons["save-story"].tap()
    app.tabBars.buttons["故事"].tap()
    XCTAssertTrue(app.staticTexts["QA story"].waitForExistence(timeout: 5))
    app.staticTexts["QA story"].tap()
    XCTAssertEqual(app.staticTexts["story-count"].label, "2 张照片")
    screenshot("05-saved-story")
    app.terminate()
    app.launchArguments.removeAll { $0 == "-reset-test-data" }
    app.launch()
    app.tabBars.buttons["故事"].tap()
    XCTAssertTrue(app.staticTexts["QA story"].waitForExistence(timeout: 10))
  }
  func testCancelledStoryAndResetConfirmation() {
    app.tabBars.buttons["故事"].tap()
    app.buttons["story-sample-story"].tap()
    app.buttons["edit-story"].tap()
    let title = app.textFields["story-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText(" changed")
    app.buttons["取消"].tap()
    app.buttons["放弃修改"].tap()
    XCTAssertEqual(app.staticTexts["story-count"].label, "6 张照片")
    app.tabBars.buttons["图库"].tap()
    app.buttons["设置"].tap()
    app.swipeUp()
    app.buttons["重置示例数据"].tap()
    XCTAssertTrue(app.buttons["确认重置"].waitForExistence(timeout: 5))
    screenshot("06-reset-confirmation")
  }
  func testMetadataSaveAndRestore() {
    app.buttons["photo-sample-10"].tap()
    app.buttons["photo-info"].tap()
    app.buttons["edit-metadata"].tap()
    let field = app.textFields["metadata-notes"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("Saved note")
    app.buttons["save-metadata"].tap()
    XCTAssertTrue(app.staticTexts["Saved note"].waitForExistence(timeout: 5))
    app.swipeUp()
    app.buttons["恢复原始值"].tap()
    app.buttons["确认恢复"].tap()
    app.swipeDown()
    XCTAssertTrue(app.staticTexts["尚未添加描述"].waitForExistence(timeout: 5))
    screenshot("07-restored-metadata")
  }
  func testReorderCoverRemoveAndUndo() {
    app.tabBars.buttons["故事"].tap()
    app.buttons["story-sample-story"].tap()
    app.buttons["edit-story"].tap()
    app.buttons["actions-sample-10"].tap()
    app.buttons["设为封面"].tap()
    app.buttons["actions-sample-10"].tap()
    app.buttons["后移"].tap()
    app.buttons["actions-sample-11"].tap()
    app.buttons["移出故事"].tap()
    app.swipeUp()
    app.buttons["撤销移出照片"].tap()
    app.buttons["save-story"].tap()
    XCTAssertTrue(app.images["story-cover-sample-10"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["story-count"].label, "6 张照片")
    screenshot("08-changed-cover")
  }
  func testDemoSyncSurvivesNavigation() {
    app.buttons["设置"].tap()
    app.swipeUp()
    app.buttons["演示账号与同步"].tap()
    let email = app.textFields["演示邮箱"]
    XCTAssertTrue(email.waitForExistence(timeout: 5))
    email.tap()
    email.typeText("demo@example.com")
    app.buttons["演示登录"].tap()
    let consent = app.switches.firstMatch
    consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(app.buttons["演示同步失败"].isEnabled)
    app.buttons["演示同步失败"].tap()
    XCTAssertTrue(app.buttons["演示重试"].waitForExistence(timeout: 5))
    app.buttons["演示重试"].tap()
    XCTAssertTrue(app.staticTexts["演示：同步完成（未连接云端）"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.staticTexts["演示：同步完成（未连接云端）"].waitForExistence(timeout: 5))
    screenshot("09-demo-sync-shared")
  }
  func testDragAndInteractiveZoom() {
    let photo = app.buttons["photo-sample-10"]
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    photo.tap()
    // Begin a short interactive dismissal then reverse it; the system owns cancellation.
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.45))
    let short = app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.45))
    start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.1)
    if app.buttons["photo-info"].exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
    XCTAssertTrue(photo.waitForExistence(timeout: 5))
    app.tabBars.buttons["故事"].tap()
    app.buttons["story-sample-story"].tap()
    app.buttons["edit-story"].tap()
    let source = app.buttons["actions-sample-10"]
    let target = app.buttons["actions-sample-12"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    // onMove handles sit at the trailing edge of the same row.
    let rowY = source.frame.midY
    let endY = target.frame.midY
    let handle = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: app.frame.width - 38, dy: rowY))
    let landing = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: app.frame.width - 38, dy: endY))
    handle.press(forDuration: 0.8, thenDragTo: landing)
    XCTAssertGreaterThan(
      app.buttons["actions-sample-10"].frame.midY, app.buttons["actions-sample-12"].frame.midY)
    screenshot("10-native-reorder")
    app.buttons["save-story"].tap()
    XCTAssertEqual(app.staticTexts["story-count"].label, "6 张照片")
  }
  func testAccessibilityLayout() {
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 10))
    screenshot("11-accessibility-library")
    app.buttons["设置"].tap()
    app.swipeUp()
    screenshot("12-accessibility-settings")
    let motionLabel = app.staticTexts["motion-status"]
    for _ in 0..<8 where !(motionLabel.exists && motionLabel.isHittable) { app.swipeUp() }
    XCTAssertTrue(motionLabel.isHittable)
    screenshot("14-system-reduce-motion")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.tabBars.buttons["故事"].tap()
    app.buttons["story-sample-story"].tap()
    app.buttons["edit-story"].tap()
    let title = app.textFields["story-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText(" — a long story title across several lines, saved with accessibility text size")
    app.buttons["save-story"].tap()
    XCTAssertTrue(app.buttons["edit-story"].waitForExistence(timeout: 5))
    screenshot("13-accessibility-long-title")
  }
}
