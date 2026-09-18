//  ColorPanelScopeTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import Testing
@testable import foofoil

/// 取色面板是应用级单例：取色只落在打开它的那扇箔，箔窗关闭后面板一并收起。
///
/// 用例只为验证归属关系，不把窗口/面板摆到屏幕上（屏幕坐标远离可见区域），
/// 避免与依赖真实指针的其他用例相互干扰。
@MainActor
@Suite(.serialized)
struct ColorPanelScopeTests {
    /// 其他箔只能接收自己那扇面板的取色；不属于某箔的取色一律丢弃。
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

        owner.showBackgroundColorPanel()
        let panel = offScreenPanel()
        panel.color = try #require(NSColor(hex: "#112233"))
        #expect(owner.backgroundColorHex == "#112233", "面板所属窗口未收到取色")
        #expect(other.backgroundColorHex == nil, "取色落到了非面板所属窗口")

        // 面板转由另一扇箔接管后，取色同样只写入新的所属窗口。
        other.showBackgroundColorPanel()
        panel.color = try #require(NSColor(hex: "#445566"))
        #expect(other.backgroundColorHex == "#445566", "面板所属窗口未收到取色")
        #expect(owner.backgroundColorHex == "#112233", "旧窗口仍接收取色")
    }

    /// 箔窗关闭时，属于它的取色面板一并收起，避免残留取色作用到其他窗口。
    @Test func closingOwnerWindowDismissesColorPanel() throws {
        let appDelegate = try #require(NSApplication.shared.delegate as? AppDelegate)
        let owner = AppState()
        let controller = FloatingWindowController(appState: owner)
        let window = try #require(controller.window)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        appDelegate.addWindowController(controller)
        defer {
            controller.close()
            NSColorPanel.shared.close()
            HistoryManager.shared.removeFromHistory(owner.toConfig())
        }

        owner.showBackgroundColorPanel()
        let panel = offScreenPanel()
        #expect(panel.isVisible)
        #expect(appDelegate.colorPanelOwner === owner)

        controller.close()

        #expect(appDelegate.colorPanelOwner == nil, "箔窗关闭后仍保留取色面板归属")
        #expect(!panel.isVisible, "箔窗关闭后取色面板仍在屏幕上")

        // 面板已收起：残留回调不再写入已关闭窗口的状态。
        owner.backgroundColorHex = nil
        panel.color = try #require(NSColor(hex: "#778899"))
        #expect(owner.backgroundColorHex == nil, "面板收起后仍写入了背景色")
    }

    /// ⌘K 重置箔时先收起属于它的取色面板，并按新窗口处理：内容背景色不带到新的空白箔上。
    @Test func resettingContentDismissesColorPanel() throws {
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
            NSColorPanel.shared.close()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }

        state.backgroundColorHex = "#123456"
        state.showBackgroundColorPanel()
        let panel = offScreenPanel()
        #expect(panel.isVisible)
        #expect(appDelegate.colorPanelOwner === state)

        state.resetContent()

        #expect(appDelegate.colorPanelOwner == nil, "重置后仍保留取色面板归属")
        #expect(!panel.isVisible, "重置后取色面板仍在屏幕上")
        #expect(state.backgroundColorHex == nil, "重置后把内容背景色带到了新的空白箔")
    }

    /// 面板只在可见时才派发取色，因此需要显示；位置放到屏幕外，避免抢走真实指针事件。
    private func offScreenPanel() -> NSColorPanel {
        let panel = NSColorPanel.shared
        panel.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        panel.orderFront(nil)
        return panel
    }
}
