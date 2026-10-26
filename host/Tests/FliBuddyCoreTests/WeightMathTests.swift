import Testing
@testable import FliBuddyCore

@Suite("WeightMath")
struct WeightMathTests {
    @Test func grossAddsTheCore() {
        #expect(WeightMath.grossFromNet(484, core: 250) == 734)
    }

    @Test func grossWithZeroOrUnknownCoreIsTheNet() {
        #expect(WeightMath.grossFromNet(484, core: 0) == 484)
        #expect(WeightMath.grossFromNet(484, core: nil) == 484)
    }

    @Test func grossIgnoresANegativeCore() {
        #expect(WeightMath.grossFromNet(484, core: -10) == 484)
    }

    @Test func remainingIsLabelMinusUsed() {
        #expect(WeightMath.remaining(label: 1000, used: 516) == 484)
        #expect(WeightMath.remaining(label: 1000, used: 0) == 1000)
    }

    @Test func remainingRoundsFractionalUse() {
        #expect(WeightMath.remaining(label: 1000, used: 515.6) == 484)
        #expect(WeightMath.remaining(label: 1000, used: 515.4) == 485)
    }

    @Test func remainingClampsAtZero() {
        #expect(WeightMath.remaining(label: 1000, used: 1200) == 0)
        #expect(WeightMath.remaining(label: 0, used: 0) == 0)
    }
}
