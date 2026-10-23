import AppKit
import Testing
@testable import foofoil

struct FoilExposeGridTests {
    @Test @MainActor func cardGridMatchesExistingContentWidthAndSpacing() {
        let metrics = FoilExposeGridMetrics(width: 1240, compact: false)
        #expect(metrics.columns == 5)
        #expect(metrics.itemSize == NSSize(width: 216, height: 244))
        #expect(metrics.inset == 44)
    }

    @Test @MainActor func wideScreensCenterTheSameGridWithoutLargerCards() {
        let normal = FoilExposeGridMetrics(width: 1240, compact: false)
        let wide = FoilExposeGridMetrics(width: 2560, compact: false)
        #expect(wide.columns == normal.columns)
        #expect(wide.itemSize == normal.itemSize)
        #expect(wide.inset == 704)
    }

    @Test @MainActor func compactResultsHaveIndependentColumnCount() {
        let metrics = FoilExposeGridMetrics(width: 1240, compact: true)
        #expect(metrics.columns == 3)
        #expect(metrics.itemSize.height == 58)
        #expect(abs(2 * metrics.inset + 3 * metrics.itemSize.width + 20 - 1240) < 0.001)
    }

    @Test @MainActor func narrowAndInitialZeroWidthNeverProduceInvalidFrames() {
        for width: CGFloat in [0, 40, 120, 400] {
            for compact in [false, true] {
                let metrics = FoilExposeGridMetrics(width: width, compact: compact)
                #expect(metrics.columns >= 1)
                #expect(metrics.itemSize.width > 0)
                #expect(metrics.itemSize.height > 0)
                #expect(metrics.inset >= 0)
                if width > 0 {
                    #expect(CGFloat(metrics.columns) * metrics.itemSize.width + 2 * metrics.inset <= width + 0.001)
                }
            }
        }
    }

    @Test func firstRowRevealsHeadingEvenWhenCardIsFullyVisible() {
        let frame = NSRect(x: 240, y: 50, width: 200, height: 244)
        let visible = NSRect(x: 0, y: 30, width: 1000, height: 500)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: frame, visibleRect: visible, maximum: 900, revealTop: true) == 0)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: frame, visibleRect: visible, maximum: 900) == nil)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: frame, visibleRect: NSRect(x: 0, y: 0, width: 1000, height: 500), maximum: 900, revealTop: true) == nil)
    }

    @Test func visibleSelectionDoesNotScroll() {
        let visible = NSRect(x: 0, y: 100, width: 1000, height: 500)
        let frame = NSRect(x: 0, y: 150, width: 200, height: 244)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: frame, visibleRect: visible, maximum: 900) == nil)
    }

    @Test func partiallyVisibleSelectionScrollsMinimallyToItsEdge() {
        let visible = NSRect(x: 0, y: 100, width: 1000, height: 500)
        // 顶部被裁：把卡片顶边对齐视口顶部。
        let clippedTop = NSRect(x: 0, y: 40, width: 200, height: 244)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: clippedTop, visibleRect: visible, maximum: 900) == 40)
        // 底部被裁：把卡片底边对齐视口底部。
        let clippedBottom = NSRect(x: 0, y: 500, width: 200, height: 244)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: clippedBottom, visibleRect: visible, maximum: 900) == 244)
    }

    @Test func offscreenSelectionCentersAndClampsToContent() {
        let visible = NSRect(x: 0, y: 100, width: 1000, height: 500)
        let above = NSRect(x: 0, y: -200, width: 200, height: 244)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: above, visibleRect: visible, maximum: 900) == 0)
        let below = NSRect(x: 0, y: 900, width: 200, height: 244)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: below, visibleRect: visible, maximum: 900) == 772)
        #expect(FoilExposeGridScrollTarget.originY(itemFrame: below, visibleRect: visible, maximum: 300) == 300)
    }

    @Test func pageScrollPrefersFirstFullyVisibleCandidate() {
        let visible = NSRect(x: 0, y: 100, width: 1000, height: 500)
        let clipped = (index: 0, frame: NSRect(x: 0, y: 40, width: 200, height: 244))
        let fullyVisible = (index: 5, frame: NSRect(x: 0, y: 150, width: 200, height: 244))
        let below = (index: 10, frame: NSRect(x: 0, y: 700, width: 200, height: 244))
        #expect(FoilExposeGridPageSelection.firstIndex(candidates: [clipped, fullyVisible, below], visibleRect: visible) == 5)
        // 没有完整可见项时退回第一个相交项。
        #expect(FoilExposeGridPageSelection.firstIndex(candidates: [clipped, below], visibleRect: visible) == 0)
        #expect(FoilExposeGridPageSelection.firstIndex(candidates: [], visibleRect: visible) == nil)
    }
}
