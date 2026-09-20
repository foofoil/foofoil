//
//  BackgroundColorUITests.swift
//  foofoilUITests
//
//  Created by tolg on 2026/9/18.
//

import XCTest

/// 文档样式的入口契约：只有可调样式的文档箔在“视图”菜单里提供「文档样式…」。
final class DocumentStyleUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDocumentStyleEntryAvailableForDocumentFoil() throws {
        let app = launchApp()

        // 启动后的空白箔就是一份文档。
        app.menuBars.menuBarItems["View"].click()
        let entry = app.menuBars.menuItems["documentStyleAction"]
        XCTAssertTrue(entry.exists)
        XCTAssertTrue(entry.isEnabled)
    }

    @MainActor
    func testDocumentStyleEntryHiddenForImageFoil() throws {
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
            app.menuBars.menuItems["documentStyleAction"].exists,
            "图片箔不应提供文档样式入口"
        )
    }

    /// 打开面板：窗口真的出现，且标题就是面板名。
    @MainActor
    func testDocumentStyleEntryOpensPanel() throws {
        let app = launchApp()

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["documentStyleAction"].click()

        // 菜单项标题带省略号，窗口标题同键；用前缀匹配避免受省略号影响。
        let panel = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Document Style")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "文档样式面板未打开")
        // 空白箔是可调样式的文档：背景、字体、行距、段距四段都渲染出来。
        XCTAssertTrue(panel.staticTexts["Background Color"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["Font"].exists)
        XCTAssertTrue(panel.staticTexts["Line Spacing"].exists)
        XCTAssertTrue(panel.staticTexts["Paragraph Spacing"].exists)
        panel.buttons["_XCUI:CloseWindow"].click()
        XCTAssertFalse(panel.waitForExistence(timeout: 2), "面板未关闭")
    }

    /// 默认快捷键 ⌘I 真的能打开面板（键位没有被窗口或文本视图吞掉）。
    @MainActor
    func testDocumentStyleShortcutOpensPanel() throws {
        let app = launchApp()

        app.typeKey("i", modifierFlags: [.command])

        let panel = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Document Style")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "⌘I 未打开文档样式面板")
        panel.buttons["_XCUI:CloseWindow"].click()
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
