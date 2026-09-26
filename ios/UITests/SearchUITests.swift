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
    XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
    app.buttons[name].tap()
    XCTAssertTrue(app.staticTexts["search-conditions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["search-conditions"].label.contains("武汉"))
    app.buttons["修改条件"].tap()
    XCTAssertTrue(app.navigationBars["修改条件"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    app.buttons["搜索设置"].tap()
    XCTAssertTrue(app.switches["允许云端补充"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.switches["允许云端补充"].value as? String, "0")
    attach("搜索设置", app: app)
    app.buttons["完成"].tap()
  }
  @MainActor func testSearchAccessibleLayout() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    app.tabBars.buttons["找照片"].tap()
    XCTAssertTrue(app.buttons["搜索设置"].waitForExistence(timeout: 10))
    attach("搜索大字号", app: app)
  }
  @MainActor private func attach(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
}
