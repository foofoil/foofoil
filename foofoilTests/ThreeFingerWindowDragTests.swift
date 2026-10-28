import AppKit
import Testing
@testable import foofoil

struct ThreeFingerWindowDragTests {
    private func contacts(_ x: CGFloat = 0, _ y: CGFloat = 0, ids: [Int] = [1, 2, 3]) -> [ThreeFingerWindowDrag.Contact] {
        ids.enumerated().map { index, id in
            .init(identity: id, position: NSPoint(x: CGFloat(index) * 10 + x, y: 20 + y))
        }
    }

    @Test func movementDoesNotCompoundAndSupportsBothAxes() {
        var drag = ThreeFingerWindowDrag()
        let origin = NSPoint(x: 200, y: 300)
        #expect(drag.update(contacts: contacts(), windowOrigin: origin) == nil)
        #expect(drag.update(contacts: contacts(5, -4), windowOrigin: origin) == NSPoint(x: 225, y: 280))
        #expect(drag.update(contacts: contacts(10, -8), windowOrigin: NSPoint(x: 225, y: 280)) == NSPoint(x: 250, y: 260))
    }

    @Test func ignoresLandingJitterAndTracksUnorderedContacts() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        #expect(drag.update(contacts: contacts(0.5, 0.5), windowOrigin: .zero) == nil)
        #expect(!drag.isDragging)
        #expect(drag.update(contacts: contacts(3).reversed(), windowOrigin: .zero) == NSPoint(x: 15, y: 0))
    }

    @Test func replacementFingerReanchorsInsteadOfJumping() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        _ = drag.update(contacts: contacts(3), windowOrigin: .zero)
        let origin = NSPoint(x: 15, y: 0)
        #expect(drag.update(contacts: contacts(40, ids: [1, 2, 4]), windowOrigin: origin) == nil)
        #expect(drag.update(contacts: contacts(43, ids: [1, 2, 4]), windowOrigin: origin) == NSPoint(x: 30, y: 0))
    }

    @Test(arguments: [0, 1, 2, 4]) func otherFingerCountsStopDragging(count: Int) {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        #expect(drag.update(contacts: contacts(ids: Array(0..<count)), windowOrigin: .zero) == nil)
        #expect(!drag.isTracking)
        #expect(!drag.isDragging)
        #expect(drag.update(contacts: contacts(100, 100), windowOrigin: .zero) == nil)
    }

    @Test(arguments: [NSPoint(x: 0, y: 0), NSPoint(x: -1600, y: 400), NSPoint(x: 200, y: -1200)])
    func cursorKeepsItsWindowOffsetAcrossDisplayOrigins(origin: NSPoint) {
        let cursor = CGPoint(x: origin.x + 80, y: 1000 - (origin.y + 60))
        let movedOrigin = NSPoint(x: origin.x + 45, y: origin.y - 30)
        let movedCursor = ThreeFingerWindowDrag.cursorPosition(cursor, followingWindowFrom: origin, to: movedOrigin)
        #expect(movedCursor.x - movedOrigin.x == 80)
        #expect((1000 - movedCursor.y) - movedOrigin.y == 60)
        let returned = ThreeFingerWindowDrag.cursorPosition(movedCursor, followingWindowFrom: movedOrigin, to: origin)
        #expect(returned == cursor)
    }

    @Test func scrollSuppressionSurvivesPartialLiftAndMomentum() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        let landingScroll = drag.shouldSuppressScroll(phase: .began, momentumPhase: [])
        #expect(landingScroll)
        _ = drag.update(contacts: contacts(3), windowOrigin: .zero)
        _ = drag.update(contacts: contacts(ids: [1, 2]), windowOrigin: .zero)
        #expect(!drag.isTracking)
        let partialLiftScroll = drag.shouldSuppressScroll(phase: .changed, momentumPhase: [])
        #expect(partialLiftScroll)
        let partialLiftNewPhase = drag.shouldSuppressScroll(phase: .began, momentumPhase: [])
        #expect(partialLiftNewPhase)
        _ = drag.update(contacts: [], windowOrigin: .zero)
        let endingScroll = drag.shouldSuppressScroll(phase: .ended, momentumPhase: [])
        #expect(endingScroll)
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            let momentumScroll = drag.shouldSuppressScroll(phase: [], momentumPhase: phase)
            #expect(momentumScroll)
        }
        let trailingScroll = drag.shouldSuppressScroll(phase: [], momentumPhase: [])
        #expect(trailingScroll)
        let freshScroll = drag.shouldSuppressScroll(phase: .began, momentumPhase: [])
        #expect(!freshScroll)
        let freshScrollChange = drag.shouldSuppressScroll(phase: .changed, momentumPhase: [])
        #expect(!freshScrollChange)
    }

    @Test func freshTwoFingerTouchRestoresScrolling() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        _ = drag.update(contacts: [], windowOrigin: .zero)
        _ = drag.update(contacts: contacts(ids: [4, 5]), windowOrigin: .zero)
        let twoFingerScroll = drag.shouldSuppressScroll(phase: .changed, momentumPhase: [])
        #expect(!twoFingerScroll)
    }

    @Test func cancellationKeepsTailSuppressedAndExplicitResetClearsIt() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        drag.reset(keepingScrollSuppression: true)
        #expect(!drag.isTracking)
        let cancelledScroll = drag.shouldSuppressScroll(phase: .cancelled, momentumPhase: [])
        #expect(cancelledScroll)
        let cancelledMomentum = drag.shouldSuppressScroll(phase: [], momentumPhase: .began)
        #expect(cancelledMomentum)
        drag.reset()
        let resetScroll = drag.shouldSuppressScroll(phase: [], momentumPhase: [])
        #expect(!resetScroll)
    }

    @Test func ordinaryMouseWheelDoesNotGetStuckAfterDragging() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        _ = drag.update(contacts: [], windowOrigin: .zero)
        let mouseWheelSuppressed = drag.shouldSuppressScroll(
            phase: [], momentumPhase: [], hasPreciseScrollingDeltas: false)
        #expect(!mouseWheelSuppressed)
        let momentumSuppressed = drag.shouldSuppressScroll(phase: [], momentumPhase: .began)
        #expect(momentumSuppressed)
    }

    @Test func cancellationDiscardsPreviousAnchor() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        drag.reset()
        #expect(!drag.isTracking)
        #expect(drag.update(contacts: contacts(100, 100), windowOrigin: NSPoint(x: 50, y: 50)) == nil)
    }
}

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct SidebarThreeFingerWindowDragTests {
    private final class DragWindow: FloatingWindow {
        var activationRequests = 0
        var wasActivatedWhenDragStarted = false
        var onActivation: (() -> Void)?

        override func makeKeyAndOrderFront(_ sender: Any?) {
            activationRequests += 1
            super.makeKeyAndOrderFront(sender)
            onActivation?()
        }

        override func performDrag(with event: NSEvent) {
            wasActivatedWhenDragStarted = activationRequests > 0
        }
    }

    @Test(arguments: [false, true]) func commandDragActivatesTargetBeforeNativeDrag(fromSidebar: Bool) throws {
        let target = DragWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), defer: false)
        let foreground = FloatingWindow(contentRect: NSRect(x: 500, y: 100, width: 300, height: 200), defer: false)
        for window in [target, foreground] { window.isReleasedWhenClosed = false }
        defer { target.close(); foreground.close() }
        target.orderFront(nil)
        foreground.makeKeyAndOrderFront(nil)
        #expect(!target.isKeyWindow)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: .command,
            timestamp: 0, windowNumber: target.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        if fromSidebar {
            let panel = NavigatorPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            target.addChildWindow(panel, ordered: .above)
            defer { target.removeChildWindow(panel); panel.close() }
            panel.sendEvent(event)
        } else {
            target.sendEvent(event)
        }
        #expect(target.wasActivatedWhenDragStarted)
        #expect(target.activationRequests == 1)
    }

    @Test(arguments: [false, true]) func threeFingerDragActivatesTargetOnFirstMovement(fromSidebar: Bool) throws {
        let target = DragWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), defer: false)
        let foreground = FloatingWindow(contentRect: NSRect(x: 500, y: 100, width: 300, height: 200), defer: false)
        for window in [target, foreground] { window.isReleasedWhenClosed = false }
        defer { target.close(); foreground.close() }
        target.orderFront(nil)
        foreground.makeKeyAndOrderFront(nil)
        let panel = NavigatorPanel(contentRect: NSRect(x: 50, y: 100, width: 50, height: 200),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { target.removeChildWindow(panel); panel.close() }
        if fromSidebar {
            target.addChildWindow(panel, ordered: .above)
            // 后台测试宿主无法取得系统焦点，模拟侧栏交出焦点时的同步回调。
            target.onActivation = { panel.resignKey() }
        }
        let cursor = CGEvent(source: nil)?.location
        defer { if let cursor { CGWarpMouseCursorPosition(cursor) } }
        let origin = target.frame.origin
        func contacts(_ x: CGFloat) -> [ThreeFingerWindowDrag.Contact] {
            (1...3).map { .init(identity: $0, position: NSPoint(x: x, y: 0)) }
        }
        target.handleWindowDragContacts(contacts(0))
        target.handleWindowDragContacts(contacts(0.5))
        #expect(target.activationRequests == 0)
        #expect(target.frame.origin == origin)
        target.handleWindowDragContacts(contacts(3))
        #expect(target.activationRequests == 1)
        #expect(target.frame.origin == NSPoint(x: origin.x + 15, y: origin.y))
        target.handleWindowDragContacts(contacts(6))
        #expect(target.frame.origin == NSPoint(x: origin.x + 30, y: origin.y))
        #expect(target.activationRequests == 1)
    }

    @Test func sidebarRoutesToItsOwnFoilAndMovesWithIt() throws {
        let foil = FloatingWindow(contentRect: NSRect(x: 500, y: 300, width: 400, height: 300), defer: false)
        let otherFoil = FloatingWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200), defer: false)
        let panel = NavigatorPanel(contentRect: NSRect(x: 300, y: 300, width: 200, height: 300),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [foil, otherFoil, panel] { window.isReleasedWhenClosed = false }
        defer {
            foil.removeChildWindow(panel)
            panel.close()
            foil.close()
            otherFoil.close()
        }
        let sidebar = NavigatorHostingView(appState: AppState(isIncognito: true))
        panel.contentView = sidebar
        foil.addChildWindow(panel, ordered: .above)
        #expect(sidebar.allowedTouchTypes.contains(.indirect))
        let target = try #require(sidebar.windowDragTarget)
        #expect(target === foil)
        let previousPanelOrigin = panel.frame.origin
        let otherFrame = otherFoil.frame
        target.setFrameOrigin(NSPoint(x: foil.frame.minX + 30, y: foil.frame.minY - 20))
        #expect(panel.frame.origin == NSPoint(x: previousPanelOrigin.x + 30, y: previousPanelOrigin.y - 20))
        #expect(otherFoil.frame == otherFrame)
        foil.removeChildWindow(panel)
        #expect(sidebar.windowDragTarget == nil)
    }

    @Test func embeddedSidebarTargetsHostAndKeepsOrdinaryHitTesting() {
        let foil = FloatingWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), defer: false)
        foil.isReleasedWhenClosed = false
        defer { foil.close() }
        let sidebar = NavigatorHostingView(appState: AppState(isIncognito: true), isFullScreenOverlay: true)
        foil.contentView = sidebar
        #expect(sidebar.windowDragTarget === foil)
        #expect(sidebar.allowedTouchTypes.contains(.indirect))
        // 普通点击仍命中原生控件，三指根视图不能挡住行按钮或搜索框。
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 24))
        sidebar.addSubview(button, positioned: .above, relativeTo: nil)
        let point = sidebar.convert(NSPoint(x: 30, y: 20), to: sidebar.superview)
        #expect(sidebar.hitTest(point) === button)
    }
}
