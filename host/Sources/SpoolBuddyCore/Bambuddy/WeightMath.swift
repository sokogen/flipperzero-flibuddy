import Foundation

/// Weight rules shared by the session and the views (see the plan's "Weight rules").
public enum WeightMath {
    /// Gross scale weight for `net` grams of filament on a `core` gram spool.
    /// An unknown or negative core counts as zero.
    public static func grossFromNet(_ net: Int, core: Int?) -> Int {
        net + max(0, core ?? 0)
    }

    /// Filament left on a spool, in whole grams, never negative.
    public static func remaining(label: Int, used: Double) -> Int {
        max(0, Int((Double(label) - used).rounded()))
    }
}
