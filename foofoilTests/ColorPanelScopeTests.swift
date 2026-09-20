//  ColorPanelScopeTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import Testing
@testable import foofoil

/// 取色面板（SVG）与文档样式面板都是应用级/单例窗口：只作用于打开它的那扇箔，
/// 且箔窗关闭或重置时一并收起。
@MainActor
@Suite(.serialized)
struct ColorPanelScopeTests {
    /// SVG 取色：其他窗口处于前台时也不能接收这扇箔的面板取色。
    @Test func colorChangesApplyOnlyToOwningFoil() throws {
        let appDelegate = try #require(NSApplication.shared.delegate as? AppDelegate)
        let owner = AppState()
        let other = AppState()
        let ownerController = FloatingWindowController(appState: owner)
        let otherController = FloatingWindowController(appState: other)
        appDelegate.addWindowController(ownerController)
        appDelegate.addWindowController(otherController)
        defer {
            ownerController.close()
            otherController.close()
            NSColorPanel.shared.close()
            HistoryManager.shared.removeFromHistory(owner.toConfig())
            HistoryManager.shared.removeFromHistory(other.toConfig())
        }

        owner.showColorPanel()
        let panel = offScreenColorPanel()
        panel.color = try #require(NSColor(hex: "#112233"))
        #expect(owner.svgColor == "#112233", "面板所属窗口未收到取色")
        #expect(other.svgColor == nil, "取色落到了非面板所属窗口")

        // 面板转由另一扇箔接管后，取色同样只写入新的所属窗口。
        other.showColorPanel()
        panel.color = try #require(NSColor(hex: "#445566"))
        #expect(other.svgColor == "#445566")
        #expect(owner.svgColor == "#112233", "旧窗口仍接收取色")
    }

    /// 文档样式面板绑定打开它的箔，并可改绑；只收起属于该箔的面板。
    @Test func stylePanelFollowsOwningFoil() throws {
        let appDelegate = try #require(NSApplication.shared.delegate as? AppDelegate)
        let owner = AppState()
        let other = AppState()
        let ownerController = FloatingWindowController(appState: owner)
        let otherController = FloatingWindowController(appState: other)
        appDelegate.addWindowController(ownerController)
        appDelegate.addWindowController(otherController)
        defer {
            ownerController.close()
            otherController.close()
            DocumentStylePanelController.shared.dismiss(ownedBy: owner)
            HistoryManager.shared.removeFromHistory(owner.toConfig())
            HistoryManager.shared.removeFromHistory(other.toConfig())
        }

        DocumentStylePanelController.shared.show(for: owner)
        #expect(DocumentStylePanelController.shared.attachedState === owner)
        #expect(DocumentStylePanelController.shared.window?.isVisible == true)

        DocumentStylePanelController.shared.show(for: other)
        #expect(DocumentStylePanelController.shared.attachedState === other)

        // 不属于当前所属箔的收起请求不生效。
        appDelegate.dismissDocumentStylePanel(ownedBy: owner)
        #expect(DocumentStylePanelController.shared.attachedState === other)

        appDelegate.dismissDocumentStylePanel(ownedBy: other)
        #expect(DocumentStylePanelController.shared.attachedState == nil)
        #expect(DocumentStylePanelController.shared.window?.isVisible == false)
    }

    /// 箔窗关闭时，属于它的样式面板一并收起。
    @Test func closingOwnerWindowDismissesStylePanel() throws {
        let appDelegate = try #require(NSApplication.shared.delegate as? AppDelegate)
        let owner = AppState()
        let controller = FloatingWindowController(appState: owner)
        _ = controller.window
        appDelegate.addWindowController(controller)
        defer {
            controller.close()
            HistoryManager.shared.removeFromHistory(owner.toConfig())
        }

        DocumentStylePanelController.shared.show(for: owner)
        #expect(DocumentStylePanelController.shared.window?.isVisible == true)

        controller.close()

        #expect(DocumentStylePanelController.shared.attachedState == nil, "箔窗关闭后仍保留样式面板归属")
        #expect(DocumentStylePanelController.shared.window?.isVisible == false)
    }

    /// ⌘K 重置箔时先收起面板，并按新窗口处理：样式不带到新的空白箔上。
    @Test func resettingContentDismissesStylePanel() throws {
        let appDelegate = try #require(NSApplication.shared.delegate as? AppDelegate)
        let state = AppState()
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        // 窗口停在屏幕外：重置会触发一次窗口尺寸收尾，避免干扰依赖真实指针的用例。
        window.setFrame(NSRect(x: -4000, y: -4000, width: 400, height: 400), display: false)
        state.windowFrame = window.frameDescriptor
        appDelegate.addWindowController(controller)
        defer {
            controller.close()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }

        state.backgroundColorHex = "#123456"
        state.textColorHex = "#F5EFE0"
        state.documentFontName = "Menlo-Regular"
        state.documentLineSpacing = 1.8
        state.documentParagraphSpacing = 0.8
        DocumentStylePanelController.shared.show(for: state)

        state.resetContent()

        #expect(DocumentStylePanelController.shared.attachedState == nil, "重置后仍保留样式面板归属")
        #expect(DocumentStylePanelController.shared.window?.isVisible == false)
        #expect(state.backgroundColorHex == nil, "重置后把内容背景色带到了新的空白箔")
        #expect(state.textColorHex == nil)
        #expect(state.documentFontName == nil)
        #expect(state.documentLineSpacing == nil)
        #expect(state.documentParagraphSpacing == nil)
    }

    /// 面板只在可见时才派发取色，因此需要显示；位置放到屏幕外，避免抢走真实指针事件。
    private func offScreenColorPanel() -> NSColorPanel {
        let panel = NSColorPanel.shared
        panel.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        panel.orderFront(nil)
        return panel
    }
}
