import Foundation

/// The iPhone's connection banner: one green line while both sides work,
/// else one line per side in trouble (Flipper first), each in its short
/// phrase with its own action. Beside an empty feed that shows a setup step
/// (no Bambuddy, no Flipper chosen) the setup lines are left out: the empty
/// feed says the same with its button, so a first run shows no banner.
/// Real problems of a set-up app (unreachable, searching, a rejected key)
/// stay.
public struct ConnectionBanner: Equatable, Sendable {
    /// Which side a line speaks for.
    public enum Side: Equatable, Sendable {
        case flipper
        case bambuddy
        /// The healthy line, both sides at once.
        case both

        /// The side's name in the chip's VoiceOver label.
        var name: String? {
            switch self {
            case .flipper: "Flipper"
            case .bambuddy: "Bambuddy"
            case .both: nil
            }
        }
    }

    /// A line with the side it speaks for.
    public struct Entry: Equatable, Sendable {
        public var item: StatusItem
        public var side: Side

        /// The chip's VoiceOver label with its side: `Retry Bambuddy`.
        public var actionLabel: String? {
            guard let action = item.action, let name = side.name else { return nil }
            return action.accessibilityLabel(for: name)
        }
    }

    public var entries: [Entry]

    /// The lines, top to bottom; none when the empty feed says it all.
    public var lines: [StatusItem] {
        entries.map(\.item)
    }

    public static let healthyText = "Flipper connected \u{00B7} Bambuddy ready"

    /// `emptyState`: what the empty feed under the banner shows, `nil` when
    /// it shows rows (or the Spoolman screen).
    public init(flipper: StatusItem, bambuddy: StatusItem, emptyState: FeedEmptyState? = nil) {
        if flipper.isHealthy, bambuddy.isHealthy {
            let detail = [flipper.detail, bambuddy.detail].compactMap { $0 }.joined(separator: " \u{00B7} ")
            entries = [
                Entry(
                    item: StatusItem(
                        text: Self.healthyText, symbol: .symbol("checkmark.circle.fill"), tint: .green,
                        detail: detail.isEmpty ? nil : detail
                    ),
                    side: .both
                ),
            ]
        } else {
            let hidesSetup = emptyState?.isSetupStep ?? false
            entries = [Entry(item: flipper, side: .flipper), Entry(item: bambuddy, side: .bambuddy)]
                .filter { !$0.item.isHealthy && !(hidesSetup && $0.item.isSetupStep) }
                .map { Entry(item: Self.shortened($0.item), side: $0.side) }
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
