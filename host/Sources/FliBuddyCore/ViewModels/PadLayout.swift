import Foundation

/// How the iPhone/iPad app lays itself out (iPad page): a landscape iPad
/// gets the sidebar, a portrait one the tabs (iPadOS draws them at the
/// top), both with the feed as tiles; a compact width (an iPhone, a narrow
/// Split View or Stage Manager window) gets the iPhone's tabs and cards.
/// The window decides, measured at the root, not the device's orientation.
public enum FeedLayout: Equatable, Sendable {
    /// `NavigationSplitView`: the sidebar with both connection states and
    /// Clear feed; tiles.
    case sidebar
    /// `TabView` (the iPad's top tab bar): the connection banner; tiles.
    case tabs
    /// `TabView` (the iPhone's bottom tab bar): the banner; stacked cards.
    case cards

    /// The sidebar's width.
    public static let sidebarWidth: Double = 300
    /// A tile's narrowest width; the grid fits as many as this allows.
    public static let tileMinimumWidth: Double = 300
    /// Between tiles, across and down.
    public static let tileSpacing: Double = 12
    /// The grid's side margins.
    public static let tileMargin: Double = 28
    /// A row holds at most three tiles (a 13" iPad); wider windows widen them.
    public static let maximumTileColumns = 3

    /// A width and a height in points.
    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The window from a view's geometry: SwiftUI's size excludes the safe
    /// areas, and the keyboard is a bottom safe area, so the size alone makes
    /// a portrait iPad with the keyboard up look landscape. The insets put
    /// back make it the whole window either way.
    public static func windowSize(
        width: Double, height: Double, top: Double, bottom: Double, leading: Double, trailing: Double
    ) -> Size {
        Size(width: width + leading + trailing, height: height + top + bottom)
    }

    /// Around a square window the layout keeps what it had until the
    /// window is this much (in total) past square, so a resize across it
    /// does not flip the layout at every point.
    public static let squareDeadBand: Double = 40

    /// `isCompact`: the horizontal size class is compact. `previous`: the
    /// layout on screen, which holds within `squareDeadBand` of square.
    public static func forWindow(
        width: Double, height: Double, isCompact: Bool, previous: FeedLayout? = nil
    ) -> FeedLayout {
        guard !isCompact else { return .cards }
        let margin = squareDeadBand / 2
        switch previous {
        case .tabs: return width > height + margin ? .sidebar : .tabs
        case .sidebar: return height > width + margin ? .tabs : .sidebar
        case .cards, nil: return width > height ? .sidebar : .tabs
        }
    }

    /// The sidebar carries the connection states and Clear feed.
    public var hasSidebar: Bool { self == .sidebar }
    /// The feed is a grid of tiles rather than a list of cards.
    public var showsTiles: Bool { self != .cards }
    /// The connection banner over the feed and Clear in its toolbar;
    /// beside the sidebar these live in the sidebar.
    public var showsBanner: Bool { !hasSidebar }
    /// The iPhone's bottom tab bar hides while the number pad is up; the
    /// iPad's top one stays, or Settings would be out of reach while a row
    /// waits for a weight.
    public var hidesTabBarWhileTyping: Bool { self == .cards }
    /// "Clear the feed?" is a centred alert on the iPad, an action sheet on
    /// the iPhone.
    public var centresClearConfirmation: Bool { self != .cards }

    /// Tiles to a row in a grid `width` wide (the margins left out): two on
    /// an 11" iPad, three on a 13", in both orientations.
    public static func tileColumns(width: Double) -> Int {
        let fits = Int(((width + tileSpacing) / (tileMinimumWidth + tileSpacing)).rounded(.down))
        return min(maximumTileColumns, max(1, fits))
    }
}

/// The iPad sidebar (ipados spec, "Landscape structure"): the Flipper and
/// Bambuddy rows under Connections, Feed with its row count, Settings, and
/// Clear feed at the bottom.
public struct Sidebar: Equatable, Sendable {
    /// A connection row: the side's name over a sub line, its symbol and
    /// tint, and the action chip the state offers.
    public struct StatusRow: Equatable, Sendable {
        public var name: String
        public var subline: String
        /// Always an SF Symbol name; a state that spins shows `spins` beside
        /// the sub line instead.
        public var symbol: String
        public var tint: StatusTint
        public var spins: Bool
        /// The sub line is red (a red Bambuddy state).
        public var isSublineRed: Bool
        public var action: StatusItem.Action?
        /// The reason behind the phrase, for the pointer label.
        public var detail: String?
    }

    public static let connectionsTitle = "Connections"
    public static let settingsHint = "\u{2318},"
    public static let clearTitle = "Clear feed"
    public static let clearHint = "\u{2318}\u{232B}"

    public let flipper: StatusRow
    public let bambuddy: StatusRow
    /// Feed's badge: the number of rows.
    public let feedCount: Int
    /// Clear feed is disabled while the feed is empty.
    public let canClear: Bool

    /// `flipperName`: the chosen Flipper's name (`Settings.peripheralName`);
    /// `serverURL`: Bambuddy's URL as typed in the settings.
    public init(flipper: StatusItem, bambuddy: StatusItem, flipperName: String?, serverURL: String, feedCount: Int) {
        self.flipper = Self.flipperRow(flipper, name: flipperName)
        self.bambuddy = Self.bambuddyRow(bambuddy, serverURL: serverURL)
        self.feedCount = feedCount
        canClear = feedCount > 0
    }

    /// `Workshop · Bluetooth` when connected (the Flipper's name in place of
    /// `Flipper`), else the status phrase, which names no Flipper.
    static func flipperRow(_ item: StatusItem, name: String?) -> StatusRow {
        let prefix = "Flipper \u{00B7} "
        var subline = item.text
        if item.isHealthy, subline.hasPrefix(prefix), let name, !name.isEmpty {
            subline = "\(name) \u{00B7} \(subline.dropFirst(prefix.count))"
        }
        return row(item, name: "Flipper", subline: subline, spinning: "antenna.radiowaves.left.and.right.slash")
    }

    /// The status phrase without `Bambuddy`, capitalised: `Ready ·
    /// bambuddy.local` (the URL's host), `Not checked`, `Unreachable`,
    /// `In Spoolman mode`, `Ready · colour names unavailable`.
    static func bambuddyRow(_ item: StatusItem, serverURL: String) -> StatusRow {
        var subline = item.text
        for prefix in ["Bambuddy is ", "Bambuddy \u{00B7} ", "Bambuddy "] where subline.hasPrefix(prefix) {
            subline = String(subline.dropFirst(prefix.count))
            break
        }
        if subline == "Checking Bambuddy\u{2026}" { subline = "Checking\u{2026}" }
        subline = subline.prefix(1).uppercased() + subline.dropFirst()
        if subline == "Ready", let host = Self.host(of: serverURL) {
            subline = "Ready \u{00B7} \(host)"
        }
        var row = row(item, name: "Bambuddy", subline: subline, spinning: "server.rack")
        row.isSublineRed = item.tint == .red
        return row
    }

    /// `bambuddy.local` from `http://bambuddy.local:8000/`; a URL typed
    /// without a scheme still names its host.
    static func host(of url: String) -> String? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parsed = URL(string: text).flatMap(\.host) ?? URL(string: "http://\(text)").flatMap(\.host)
        return parsed.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func row(_ item: StatusItem, name: String, subline: String, spinning: String) -> StatusRow {
        let (symbol, spins): (String, Bool) = switch item.symbol {
        case .progress: (spinning, true)
        case .symbol(let name): (name, false)
        }
        return StatusRow(
            name: name, subline: subline, symbol: symbol, tint: item.tint, spins: spins, isSublineRed: false,
            action: item.action, detail: item.detail
        )
    }
}
