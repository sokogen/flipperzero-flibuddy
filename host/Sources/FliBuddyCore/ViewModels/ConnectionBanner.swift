import Foundation

/// The iPhone's connection banner: one green line while both sides work,
/// else one line per side in trouble (Flipper first), each in its short
/// phrase with its own action.
public struct ConnectionBanner: Equatable, Sendable {
    public var lines: [StatusItem]

    public static let healthyText = "Flipper connected \u{00B7} Bambuddy ready"

    public init(flipper: StatusItem, bambuddy: StatusItem) {
        if flipper.isHealthy, bambuddy.isHealthy {
            let detail = [flipper.detail, bambuddy.detail].compactMap { $0 }.joined(separator: " \u{00B7} ")
            lines = [
                StatusItem(
                    text: Self.healthyText, symbol: .symbol("checkmark.circle.fill"), tint: .green,
                    detail: detail.isEmpty ? nil : detail
                ),
            ]
        } else {
            lines = [flipper, bambuddy].filter { !$0.isHealthy }.map(Self.shortened)
        }
    }

    /// Both sides are down: the capsule grows to two lines.
    public var isTwoLines: Bool {
        lines.count > 1
    }

    private static func shortened(_ item: StatusItem) -> StatusItem {
        var line = item
        line.text = item.short ?? item.text
        line.short = nil
        return line
    }
}
