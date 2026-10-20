import AppKit
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct InactiveCommandScrollTests {
    private func scroll(command: Bool = true) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                       wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        if command { event.flags = .maskCommand }
        return try #require(NSEvent(cgEvent: event))
    }

    // 按 Mac Mouse Fix 的 TouchSimulator.m 构造合成捏合，仅用于测试，不投递系统事件。
    private func magnify(_ amount: Double = 0.1, phase: NSEvent.Phase = []) throws -> NSEvent {
        let event = try #require(CGEvent(source: nil))
        event.type = try #require(CGEventType(rawValue: 29))
        event.flags = []
        event.setIntegerValueField(try #require(CGEventField(rawValue: 110)), value: 8)
        // IOHID 的 changed/ended/cancelled 位与 NSEvent.Phase 不相同。
        let hidPhase: Int64 = phase.contains(.began) ? 1 : phase.contains(.changed) ? 2
            : phase.contains(.ended) ? 4 : phase.contains(.cancelled) ? 8 : 0
        event.setIntegerValueField(try #require(CGEventField(rawValue: 132)), value: hidPhase)
        event.setDoubleValueField(try #require(CGEventField(rawValue: 113)), value: amount)
        let result = try #require(NSEvent(cgEvent: event))
        #expect(result.type == .magnify)
        #expect(result.phase == phase)
        #expect(!result.modifierFlags.contains(.command))
        return result
    }

    @Test(arguments: [false, true]) func backgroundFoilResizesWithoutChangingKeyWindow(synthesizedPinch: Bool) throws {
        let controller = FloatingWindowController(appState: AppState(isIncognito: true))
        let window = try #require(controller.window)
        defer { controller.close() }
        window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 300), display: false)
        window.orderFront(nil)
        let foreground = NSWindow(contentRect: NSRect(x: 600, y: 100, width: 100, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        foreground.isReleasedWhenClosed = false
        defer { foreground.close() }
        foreground.makeKeyAndOrderFront(nil)
        #expect(!window.isKeyWindow)
        let key = NSApp.keyWindow
        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        #expect(controller.handlePointerCommandScroll(try synthesizedPinch ? magnify() : scroll(), at: point, hitWindowNumber: window.windowNumber))
        #expect(window.frame.width > 400)
        #expect(window.frame.height > 300)
        #expect(NSApp.keyWindow === key)
    }

    @Test func coveredHiddenAndUnmodifiedFoilsDoNotResize() throws {
        let controller = FloatingWindowController(appState: AppState(isIncognito: true))
        let window = try #require(controller.window)
        defer { controller.close() }
        window.orderFront(nil)
        let frame = window.frame
        let point = NSPoint(x: frame.midX, y: frame.midY)
        #expect(!controller.handlePointerCommandScroll(try scroll(), at: point, hitWindowNumber: -1))
        #expect(!controller.handlePointerCommandScroll(try scroll(command: false), at: point, hitWindowNumber: window.windowNumber))
        #expect(!controller.handlePointerCommandScroll(try scroll(), at: NSPoint(x: frame.maxX + 20, y: frame.maxY + 20), hitWindowNumber: window.windowNumber))
        window.orderOut(nil)
        #expect(!controller.handlePointerCommandScroll(try scroll(), at: point, hitWindowNumber: window.windowNumber))
        #expect(window.frame == frame)
    }

    @Test(arguments: [false, true]) func backgroundSidebarChangesWidthOnly(synthesizedPinch: Bool) throws {
        let state = AppState(isIncognito: true)
        state.navigatorPanelVisibilityMode = .always
        state.builtInNavigatorContributions = [.init(id: "test", titleLocalizationKey: "Navigator", style: .outline,
                                                   items: [.init(id: "a", title: "A")])]
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        defer { controller.close() }
        let originalPreference = SettingsStore.shared.navigatorPanelWidth
        defer { SettingsStore.shared.navigatorPanelWidth = originalPreference }
        window.orderFront(nil)
        controller.restoreAfterApplicationUnhide()
        let panel = try #require(window.childWindows?.first { $0 is NavigatorPanel })
        let key = NSApp.keyWindow
        let frame = window.frame
        state.navigatorPanelWidth = 240
        let width = state.navigatorPanelWidth
        let point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        #expect(controller.handlePointerCommandScroll(try synthesizedPinch ? magnify() : scroll(), at: point, hitWindowNumber: panel.windowNumber))
        #expect(state.navigatorPanelWidth != width)
        #expect(window.frame.size == frame.size)
        #expect(NSApp.keyWindow === key)
        #expect(!controller.handlePointerCommandScroll(try scroll(), at: point, hitWindowNumber: -1))
    }

    @Test func synthesizedPinchResetsBetweenGesturesAndRespectsOcclusion() throws {
        let controller = FloatingWindowController(appState: AppState(isIncognito: true))
        let window = try #require(controller.window)
        defer { controller.close() }
        window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 300), display: false)
        window.orderFront(nil)
        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        #expect(!controller.handlePointerCommandScroll(try magnify(), at: point, hitWindowNumber: -1))
        #expect(window.frame.width == 400)
        for _ in 0..<2 {
            #expect(controller.handlePointerCommandScroll(try magnify(0, phase: .began), at: point, hitWindowNumber: window.windowNumber))
            #expect(controller.handlePointerCommandScroll(try magnify(0.1, phase: .changed), at: point, hitWindowNumber: window.windowNumber))
            #expect(controller.handlePointerCommandScroll(try magnify(0, phase: .ended), at: point, hitWindowNumber: window.windowNumber))
        }
        // AppKit 对窗口 frame 做像素对齐，两次缩放允许累计的取整误差。
        #expect(abs(window.frame.width - 484) < 3)
        window.orderOut(nil)
        #expect(!controller.handlePointerCommandScroll(try magnify(), at: point, hitWindowNumber: window.windowNumber))
    }

    @Test func fullscreenDoesNotResizeWindow() throws {
        let state = AppState(isIncognito: true)
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window as? FloatingWindow)
        defer { controller.close() }
        let frame = window.frame
        state.isFullScreen = true
        #expect(!window.handleCommandScroll(try scroll(), at: .zero))
        #expect(window.frame == frame)
    }
}
