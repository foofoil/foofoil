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

        // 输入测试正文后成为可调样式的文档箔。
        app.menuBars.menuBarItems["View"].click()
        let entry = app.menuBars.menuItems.matching(identifier: "documentStyleAction").element(boundBy: 0)
        XCTAssertTrue(entry.exists)
        XCTAssertTrue(entry.isEnabled)
    }

    @MainActor
    func testDocumentStyleEntryHiddenForBlankFoil() throws {
        let app = launchApp(withDocument: false)
        app.menuBars.menuBarItems["View"].click()
        XCTAssertFalse(app.menuBars.menuItems["documentStyleAction"].exists)
    }

    @MainActor
    func testDocumentStyleEntryHiddenForImageFoil() throws {
        let app = launchApp()

        // 保存数据副本，避免清空剪贴板后原 NSPasteboardItem 失效。
        let savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedClipboard)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([makeTestImage()])
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["openClipboardContentAction"].click()

        // 等图片箔显示出来并成为当前箔：菜单显隐跟随当前箔。
        let imageFoil = app.windows.containing(
            NSPredicate(format: "elementType == %d", XCUIElement.ElementType.image.rawValue)
        ).element(boundBy: 0)
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
        let panel = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Document Style")).element(boundBy: 0)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "文档样式面板未打开")
        // 文本箔的外观、背景、字体、行距、段距都渲染出来。
        XCTAssertTrue(panel.staticTexts["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.descendants(matching: .any)["documentAppearancePicker"].exists)
        XCTAssertTrue(panel.staticTexts["Background Color"].exists)
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

        app.windows.element(boundBy: 0).typeKey("i", modifierFlags: [.command])

        let panel = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Document Style")).element(boundBy: 0)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "⌘I 未打开文档样式面板")
        panel.buttons["_XCUI:CloseWindow"].click()
    }

    /// 固定为英文，菜单项地址与系统语言无关。
    @MainActor
    private func launchApp(withDocument: Bool = true) -> XCUIApplication {
        let app = makeTestApplication()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 15), "箔窗未出现")
        if withDocument {
            // 空白箔现在显示搜索入口，通过剪贴板打开正文来创建文档箔。
            let pasteboard = NSPasteboard.general
            let saved = (pasteboard.pasteboardItems ?? []).map { original in
                let copy = NSPasteboardItem()
                for type in original.types {
                    if let data = original.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            defer {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
            pasteboard.clearContents()
            pasteboard.setString("Document style UI fixture", forType: .string)
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuItems["openClipboardContentAction"].click()
            XCTAssertTrue(app.textViews.element(boundBy: 0).waitForExistence(timeout: 10))
        }
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
