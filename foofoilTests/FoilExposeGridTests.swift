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
}
