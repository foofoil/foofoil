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
        #expect(drag.update(contacts: contacts(5, -4), windowOrigin: origin) == NSPoint(x: 215, y: 288))
        #expect(drag.update(contacts: contacts(10, -8), windowOrigin: NSPoint(x: 215, y: 288)) == NSPoint(x: 230, y: 276))
    }

    @Test func ignoresLandingJitterAndTracksUnorderedContacts() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        #expect(drag.update(contacts: contacts(0.5, 0.5), windowOrigin: .zero) == nil)
        #expect(!drag.isDragging)
        #expect(drag.update(contacts: contacts(3).reversed(), windowOrigin: .zero) == NSPoint(x: 9, y: 0))
    }

    @Test func replacementFingerReanchorsInsteadOfJumping() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        _ = drag.update(contacts: contacts(3), windowOrigin: .zero)
        let origin = NSPoint(x: 9, y: 0)
        #expect(drag.update(contacts: contacts(40, ids: [1, 2, 4]), windowOrigin: origin) == nil)
        #expect(drag.update(contacts: contacts(43, ids: [1, 2, 4]), windowOrigin: origin) == NSPoint(x: 18, y: 0))
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

    @Test func cancellationDiscardsPreviousAnchor() {
        var drag = ThreeFingerWindowDrag()
        _ = drag.update(contacts: contacts(), windowOrigin: .zero)
        drag.reset()
        #expect(!drag.isTracking)
        #expect(drag.update(contacts: contacts(100, 100), windowOrigin: NSPoint(x: 50, y: 50)) == nil)
    }
}
