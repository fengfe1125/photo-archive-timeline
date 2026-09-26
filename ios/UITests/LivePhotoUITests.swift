import XCTest

@MainActor final class LivePhotoUITests: XCTestCase {
  func testRealPhotoKitStoryAndRestart() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.resetAuthorizationStatus(for: .photos)
    app.launchArguments = ["-live-ui-testing", "-reset-live-test-data", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    XCTAssertTrue(app.buttons["select-mode"].waitForExistence(timeout: 30))
    let authorize = app.buttons["选择照片访问范围"]
    if authorize.waitForExistence(timeout: 5) {
      authorize.tap()
      let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      let allow = system.buttons.matching(NSPredicate(format: "label CONTAINS '完全访问' OR label CONTAINS '全部照片' OR label CONTAINS 'Full Access'")).firstMatch
      XCTAssertTrue(allow.waitForExistence(timeout: 10))
      allow.tap()
    }
    let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-' AND identifier != 'photo-info'")).firstMatch
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
    app.buttons[imageID.replacingOccurrences(of: "photo-", with: "select-")].tap()
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
