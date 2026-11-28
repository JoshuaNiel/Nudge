import Testing
import Foundation
@testable import Nudge

// MARK: - Loading indicator (docs/specs/phase-2-dashboard.md §V7)

@Suite("NudgeLoadingIndicator")
@MainActor
struct LoadingIndicatorTests {

    @Test func defaultsToLargeBrandTippingPoint() {
        let indicator = NudgeLoadingIndicator()
        #expect(indicator.style == .tippingPoint)
        #expect(indicator.size == .large)
        #expect(indicator.tone == .brand)
        #expect(indicator.reduceMotion == nil, "follows the system Reduce Motion setting")
    }

    @Test func sizeHeights() {
        #expect(LoadingIndicatorSize.small.height == 22)
        #expect(LoadingIndicatorSize.large.height == 64)
    }

    @Test func tippingPointIsSquare() {
        #expect(LoadingIndicatorStyle.tippingPoint.aspectRatio == 1)
    }

    @Test func phaseWrapsIntoOneLoop() {
        #expect(LoadingMath.phase(0, period: 2) == 0)
        #expect(LoadingMath.phase(3, period: 2) == 0.5)
        #expect(LoadingMath.phase(-0.5, period: 2) == 0.75, "negative times wrap forward")
    }

    @Test func windowClampsToUnitRange() {
        #expect(LoadingMath.window(0.125, 0.25, 0.75) == 0)
        #expect(LoadingMath.window(0.5, 0.25, 0.75) == 0.5)
        #expect(LoadingMath.window(0.875, 0.25, 0.75) == 1)
    }
}
