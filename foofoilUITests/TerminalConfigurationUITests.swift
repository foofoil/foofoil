import XCTest

final class TerminalConfigurationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSwiftUIFormRemainsInteractiveWhenOpenedFromBlankFoil() {
        let app = makeTestApplication()
        app.launch()
        app.activate()
        app.typeKey("n", modifierFlags: .command)
        // 必须从 SwiftUI 按钮进入，菜单入口不能覆盖嵌套回调导致的失效。
        let open = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "terminal", ["Open Terminal…", "打开终端…"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()

        let environment = app.textViews.matching(NSPredicate(format: "label IN %@", ["Environment (KEY=VALUE, one per line)", "环境变量（每行 KEY=VALUE）"])).firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 5))
        environment.click()
        environment.typeText("FOIL_TEST=one\nFOIL_SECOND=two")
        XCTAssertEqual(environment.value as? String, "FOIL_TEST=one\nFOIL_SECOND=two")
        let script = app.textViews.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", ["Trusted startup script", "可信初始化脚本"], ["Trusted startup script", "可信初始化脚本"])).firstMatch
        XCTAssertTrue(script.waitForExistence(timeout: 5), app.debugDescription)
        script.click()
        script.typeText("echo first\necho second")
        XCTAssertEqual(script.value as? String, "echo first\necho second")

        app.buttons.matching(NSPredicate(format: "label IN %@", ["Choose…", "选择…"])).firstMatch.click()
        let pickerCancel = app.buttons["CancelButton"]
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 5))
        pickerCancel.click()
        XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(environment.value as? String, "FOIL_TEST=one\nFOIL_SECOND=two")
        app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", ["Cancel", "取消"], ["Cancel", "取消"])).firstMatch.click()
        XCTAssertTrue(environment.waitForNonExistence(timeout: 5))
    }
}
