import Foundation

/// The watch's weight entry on the Digital Crown, in whole grams 0…9999.
/// The crown is bound to `grams` in crown units of 1 g, one per detent; a
/// slow turn moves 1 g per detent, a turn at `fastVelocity` or faster 5 g.
public struct CrownWeight: Equatable, Sendable {
    public static let range = 0...9999
    /// Crown speed in detents (crown units) per second from which one
    /// detent is worth `fastStep` grams: about 6 (watch spec).
    public static let fastVelocity = 6.0
    public static let fastStep = 5

    public private(set) var grams: Int

    public init(grams: Int) {
        self.grams = min(max(grams, Self.range.lowerBound), Self.range.upperBound)
    }

    /// The weight field's text for `FeedViewModel.setWeightText`.
    public var text: String { String(grams) }

    /// Whole grams in range; a non-finite value goes to the nearer end (NaN to 0).
    public static func clamp(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? range.upperBound : range.lowerBound }
        let rounded = value.rounded()
        if rounded <= Double(range.lowerBound) { return range.lowerBound }
        if rounded >= Double(range.upperBound) { return range.upperBound }
        return Int(rounded)
    }

    /// Follows the crown, which moved from `grams` to `value` at `velocity`
    /// (crown units per second, signed). A non-finite value changes nothing.
    public mutating func turn(to value: Double, velocity: Double) {
        guard value.isFinite else { return }
        let delta = value - Double(grams)
        let fast = abs(velocity) >= Self.fastVelocity
        grams = Self.clamp(fast ? Double(grams) + delta.rounded() * Double(Self.fastStep) : value)
    }
}
