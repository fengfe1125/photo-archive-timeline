import XCTest

@MainActor final class LivePhotoUITests: XCTestCase {
  func testRealPhotoKitStoryAndRestart() {
    continueAfterFailure = false
    let app = XCUIApplication()
    // iOS can present this while XCTest is still completing the triggering tap.
    // Handle it before XCTest's default interruption handler chooses “不允许”.
    let monitor = addUIInterruptionMonitor(withDescription: "照片图库完整访问") { alert in
      let allow = alert.buttons.matching(NSPredicate(format:
        "label == '允许完全访问' OR label == 'Allow Full Access'")).firstMatch
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    defer { removeUIInterruptionMonitor(monitor) }
    app.resetAuthorizationStatus(for: .photos)
    app.launchArguments = ["-live-ui-testing", "-reset-live-test-data", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 30))
    let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = system.alerts.buttons.matching(NSPredicate(format:
      "label == '允许完全访问' OR label == 'Allow Full Access'")).firstMatch
    if allow.waitForExistence(timeout: 3) {
      allow.tap()
    } else if !app.staticTexts["完整照片访问"].exists {
      let authorize = app.buttons["选择照片访问范围"]
      XCTAssertTrue(authorize.waitForExistence(timeout: 10))
      authorize.tap()
      // The interruption monitor may already have handled it during authorize.tap().
      if allow.waitForExistence(timeout: 3) { allow.tap() }
    }
    XCTAssertTrue(app.staticTexts["完整照片访问"].waitForExistence(timeout: 15), "必须实际授予完整照片权限，不能跳过或拒绝授权")
    let photo = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 30), "Seed public test photos and grant this test app photo permission before running")
    let imageID = photo.identifier
    photo.tap()
    XCTAssertTrue(app.buttons["photo-info"].waitForExistence(timeout: 10))
    app.buttons["photo-info"].tap()
    app.swipeUp()
    XCTAssertTrue(app.staticTexts["系统照片库"].waitForExistence(timeout: 10))
    app.buttons["close-info"].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["select-mode"].tap()
    app.cells[imageID.replacingOccurrences(of: "photo-", with: "select-")].tap()
    app.buttons["用 1 张照片创建故事"].tap()
    let title = app.textFields["story-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    title.tap(); title.typeText("Real PhotoKit story")
    app.buttons["save-story"].tap()
    app.tabBars.buttons["故事"].tap()
    XCTAssertTrue(app.staticTexts["Real PhotoKit story"].waitForExistence(timeout: 10))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Live PhotoKit saved story"; attachment.lifetime = .keepAlways; add(attachment)
    app.terminate()
    app.launchArguments.removeAll { $0 == "-reset-live-test-data" }
    app.launch()
    app.tabBars.buttons["故事"].tap()
    XCTAssertTrue(app.staticTexts["Real PhotoKit story"].waitForExistence(timeout: 20))
  }
}
