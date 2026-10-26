import Foundation
import Testing
@testable import SpoolBuddyCore

@Suite("CrownWeight")
struct CrownWeightTests {
    @Test(arguments: [
        (0.0, 0), (484.4, 484), (484.5, 485), (-3.0, 0), (-0.4, 0), (9999.4, 9999), (10_000.0, 9999), (123_456.0, 9999),
        (Double.infinity, 9999), (-Double.infinity, 0), (Double.nan, 0),
    ])
    func roundsAndClamps(_ value: Double, _ grams: Int) {
        #expect(CrownWeight.clamp(value) == grams)
    }

    @Test(arguments: [(-5, 0), (0, 0), (812, 812), (12_000, 9999)])
    func startsInRange(_ start: Int, _ grams: Int) {
        #expect(CrownWeight(grams: start).grams == grams)
    }

    @Test func aSlowTurnMovesOneGramPerStep() {
        var weight = CrownWeight(grams: 500)
        weight.turn(to: 501, velocity: 3)
        #expect(weight.grams == 501)
        weight.turn(to: 499, velocity: -3)
        #expect(weight.grams == 499)
    }

    @Test func aFastTurnMovesFiveGramsPerStep() {
        var weight = CrownWeight(grams: 500)
        weight.turn(to: 501, velocity: CrownWeight.fastVelocity)
        #expect(weight.grams == 505)
        weight.turn(to: 504, velocity: -CrownWeight.fastVelocity * 2)
        #expect(weight.grams == 500)
        weight.turn(to: 502, velocity: 40)
        #expect(weight.grams == 510)
    }

    @Test func aFractionalStepRounds() {
        var weight = CrownWeight(grams: 500)
        weight.turn(to: 500.6, velocity: 1)
        #expect(weight.grams == 501)
        weight.turn(to: 501.4, velocity: 50)
        #expect(weight.grams == 501)
    }

    @Test func turnsStopAtTheEnds() {
        var weight = CrownWeight(grams: 9997)
        weight.turn(to: 9998, velocity: 100)
        #expect(weight.grams == 9999)
        weight = CrownWeight(grams: 2)
        weight.turn(to: 1, velocity: -100)
        #expect(weight.grams == 0)
        weight.turn(to: -1, velocity: -1)
        #expect(weight.grams == 0)
    }

    @Test func aNonFiniteCrownValueIsIgnored() {
        var weight = CrownWeight(grams: 500)
        weight.turn(to: .nan, velocity: 1)
        #expect(weight.grams == 500)
        weight.turn(to: 501, velocity: .nan)
        #expect(weight.grams == 501)
    }

    @Test func theWeightFieldTextFeedsTheFeed() {
        #expect(CrownWeight(grams: 7).text == "7")
        #expect(FeedViewModel.grams(from: CrownWeight(grams: 9999).text) == 9999)
    }

    @Test func seedsFromTheTypedWeightThenTheSuggestion() {
        #expect(CrownWeight.seed(typed: "812", suggested: 1000).grams == 812)
        #expect(CrownWeight.seed(typed: "", suggested: 1000).grams == 1000)
        #expect(CrownWeight.seed(typed: "", suggested: nil).grams == 0)
    }
}
