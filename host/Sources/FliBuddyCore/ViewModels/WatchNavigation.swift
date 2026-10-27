import Foundation

/// The watch's one navigation stack: the feed at the root, a row's detail or
/// Settings (and over it Scan for Flipper) on top. A row that starts waiting for a weight opens its detail
/// on its own while the feed is the screen showing; a detail pops back to the
/// feed a second after its save, and the newest row still waiting opens next.
public struct WatchNavigation: Equatable, Sendable {
    public enum Screen: Hashable, Sendable {
        case row(FeedRow.ID)
        case settings
        case scan
    }

    public struct Row: Equatable, Sendable {
        public var id: FeedRow.ID
        public var isWaiting: Bool

        public init(id: FeedRow.ID, isWaiting: Bool) {
            self.id = id
            self.isWaiting = isWaiting
        }
    }

    /// How long a saved row's detail stays before it pops.
    public static let popDelay: Duration = .seconds(1)

    /// The screens over the feed; empty while the feed shows.
    public var path: [Screen] = []
    /// The feed, newest first, as of the last `update(rows:)`.
    public private(set) var rows: [Row] = []

    public init(path: [Screen] = [], rows: [Row] = []) {
        self.path = path
        self.rows = rows
    }

    public init(_ items: [FeedItem]) {
        rows = items.map(Self.row)
    }

    public var isFeedShowing: Bool {
        path.isEmpty
    }

    /// New rows or states. The newest row that started waiting opens when
    /// the feed shows; with a detail or Settings on screen nothing opens.
    public mutating func update(rows new: [Row]) {
        let waiting = Set(rows.filter(\.isWaiting).map(\.id))
        rows = new
        guard isFeedShowing, let started = new.first(where: { $0.isWaiting && !waiting.contains($0.id) }) else {
            return
        }
        path = [.row(started.id)]
    }

    public mutating func update(_ items: [FeedItem]) {
        update(rows: items.map(Self.row))
    }

    /// The tap on a row in the feed.
    public mutating func open(_ id: FeedRow.ID) {
        path = [.row(id)]
    }

    /// The tap on the connection glyph.
    public mutating func openSettings() {
        path = [.settings]
    }

    /// Scan for Flipper, from Settings.
    public mutating func openScan() {
        path = [.settings, .scan]
    }

    /// A Flipper was picked: back to Settings. Leaves any other screen alone.
    public mutating func closeScan() {
        guard path.last == .scan else { return }
        path.removeLast()
    }

    /// `popDelay` after `id` saved: its detail pops back to the feed and
    /// the newest row still waiting opens. Nothing happens if another screen
    /// took its place meanwhile or `id` waits again (Weigh again); if the
    /// user went back already, the waiting row still opens.
    public mutating func popAfterSave(_ id: FeedRow.ID) {
        guard path.isEmpty || path == [.row(id)] else { return }
        guard rows.first(where: { $0.id == id })?.isWaiting != true else { return }
        path = rows.first { $0.isWaiting && $0.id != id }.map { [.row($0.id)] } ?? []
    }

    private static func row(_ item: FeedItem) -> Row {
        Row(id: item.id, isWaiting: item.isWaiting)
    }
}

/// The watch's one connection glyph: the Flipper's problem while it is not
/// connected, else Bambuddy's, else the green antenna. Its text is the
/// glyph's accessibility label, in the short phrase where there is one.
public enum WatchGlyph {
    public static let healthyText = "Flipper connected"

    public static func status(flipper: StatusItem, bambuddy: StatusItem) -> StatusItem {
        for side in [flipper, bambuddy] where !side.isHealthy {
            var item = side
            item.text = side.short ?? side.text
            item.short = nil
            return item
        }
        return StatusItem(
            text: healthyText, symbol: .symbol("antenna.radiowaves.left.and.right"), tint: .green,
            detail: flipper.detail
        )
    }
}
