//
//  BackgroundColorUITests.swift
//  foofoilUITests
//
//  Created by tolg on 2026/9/18.
//

import XCTest

/// 背景颜色的入口契约：只有文档箔的“视图”菜单里提供背景颜色。
final class BackgroundColorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBackgroundColorEntryAvailableForDocumentFoil() throws {
        let app = launchApp()

        // 启动后的空白箔就是一份文档。
        app.menuBars.menuBarItems["View"].click()
        let entry = app.menuBars.menuItems["backgroundColorAction"]
        XCTAssertTrue(entry.exists)
        XCTAssertTrue(entry.isEnabled)
    }

    @MainActor
    func testBackgroundColorEntryHiddenForImageFoil() throws {
        let app = launchApp()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([makeTestImage()])
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["openClipboardContentAction"].click()

        // 等图片箔显示出来并成为当前箔：菜单显隐跟随当前箔。
        let imageFoil = app.windows.containing(
            NSPredicate(format: "elementType == %d", XCUIElement.ElementType.image.rawValue)
        ).firstMatch
        XCTAssertTrue(imageFoil.waitForExistence(timeout: 15), "剪贴板图片未打开成图片箔")
        imageFoil.click()

        app.menuBars.menuBarItems["View"].click()
        XCTAssertFalse(
            app.menuBars.menuItems["backgroundColorAction"].exists,
            "图片箔不应提供背景颜色入口"
        )
    }

    /// 固定为英文，菜单项地址与系统语言无关。
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "箔窗未出现")
        return app
    }

    private func makeTestImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 120).fill()
        image.unlockFocus()
        return image
    }
}
