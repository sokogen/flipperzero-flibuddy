import Foundation

/// What the watch's read-only Settings and its Scan for Flipper screen say
/// (watch spec, "Settings").
public enum WatchSettingsTexts {
    public static let emptyText = "Open FliBuddy on the iPhone to send its settings."
    public static let changeOnIPhone = "Change these on iPhone."

    /// A search this long without a Flipper hints that another device has it.
    public static let longSearch: TimeInterval = 30

    public static let holdATag = "Hold a spool\u{2019}s tag to the Flipper running FliBuddy."

    /// The watch's empty feed: settings first (they come from the iPhone),
    /// then a Flipper to choose, then a hint after a long search (a Flipper
    /// connected to another device stops advertising, so the watch cannot
    /// tell it apart from one out of range), else hold a tag.
    public static func emptyFeed(
        _ state: FeedEmptyState, linkActive: Bool, searchingSince: Date?, now: Date
    ) -> String {
        switch state {
        case .noServer: return "Set up FliBuddy on your iPhone first."
        case .noFlipper where !linkActive: return "Choose your Flipper in Settings."
        case .noFlipper:
            guard let searchingSince, now.timeIntervalSince(searchingSince) >= longSearch else { return holdATag }
            return "No Flipper found. It may be connected to another device."
        case .noScans: return holdATag
        }
    }

    /// The server as host and port, `bambuddy.local:8000`; the URL as typed
    /// when it has no host; `Not set` when empty.
    public static func server(_ url: String) -> String {
        let url = url.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return "Not set" }
        guard let parsed = URL(string: url), let host = parsed.host(), !host.isEmpty else { return url }
        return parsed.port.map { "\(host):\($0)" } ?? host
    }

    public static func coreWeight(_ grams: Int) -> String {
        "\(grams) g"
    }

    public static func mode(_ mode: Intent.WeightMode) -> String {
        mode == .gross ? "Gross" : "Net"
    }

    /// `Received 2 min ago. Change these on iPhone.`; without a receipt
    /// since launch only the second sentence.
    public static func footer(received: Date?, now: Date) -> String {
        guard let received else { return changeOnIPhone }
        return "Received \(age(now.timeIntervalSince(received))). \(changeOnIPhone)"
    }

    /// `just now`, `2 min ago`, `1 h ago`, `3 d ago`: short and the same in
    /// every locale, as the rest of the watch's copy.
    static func age(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(0, seconds))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }

    /// RSSI from which a Flipper reads `Nearby · strong`.
    public static let strongSignal = -60

    /// A found Flipper's signal in words: `Nearby · strong`, or `Nearby`.
    public static func signal(rssi: Int) -> String {
        rssi >= strongSignal ? "Nearby \u{00B7} strong" : "Nearby"
    }

    /// The Flipper platter's name; the watch's own Flipper choice.
    public static func flipperName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Flipper" }
        return name
    }

    /// The Flipper platter's line from the Flipper half of the status (never
    /// Bambuddy's): `Connected` in green, else the short phrase without a
    /// leading `Flipper ` (`nearby`), as the glyph shows it.
    public static func flipperStatus(_ flipper: StatusItem) -> StatusItem {
        guard !flipper.isHealthy else {
            return StatusItem(
                text: "Connected", symbol: .symbol("antenna.radiowaves.left.and.right"), tint: .green,
                detail: flipper.detail
            )
        }
        var item = flipper
        let phrase = flipper.short ?? flipper.text
        item.text = phrase.hasPrefix("Flipper ") ? String(phrase.dropFirst("Flipper ".count)) : phrase
        item.short = nil
        return item
    }
}
