import Foundation
import Observation

/// The Spools tab (iPhone, iPad): Bambuddy's inventory, read-only, for
/// looking a spool up at the bench (ios spec, "Spools"). It loads every spool,
/// archived ones included, in one request and keeps the last good list as a
/// cache; the scope, search, material filter and sort work on the device. The
/// views bind to it and call `refresh()` on appear and on pull to refresh;
/// `observe()` loads again after each write the feed makes.
@MainActor
@Observable
public final class SpoolsViewModel {
    // MARK: Texts

    public nonisolated static let title = "Spools"
    public nonisolated static let searchPrompt = LinkPickerModel.phonePlaceholder
    public nonisolated static let loadingTitle = "Loading spools\u{2026}"
    public nonisolated static let sortTitle = "Sort by"
    public nonisolated static let materialTitle = "Material"
    public nonisolated static let allMaterialsTitle = "All materials"
    public nonisolated static let menuTitle = "Sort and filter"
    public nonisolated static let lowWord = "Low"
    public nonisolated static let archivedWord = "Archived"
    /// Less than this share of the label weight left reads `Low`.
    public nonisolated static let lowFraction = 0.15

    public enum Scope: String, CaseIterable, Identifiable, Sendable {
        case active, archived, all

        public var id: Self { self }

        public var title: String {
            switch self {
            case .active: "Active"
            case .archived: "Archived"
            case .all: "All"
            }
        }
    }

    public enum Sort: String, CaseIterable, Identifiable, Sendable {
        case recentlyUpdated, leastLeft, material, colour

        public var id: Self { self }

        public var title: String {
            switch self {
            case .recentlyUpdated: "Recently updated"
            case .leastLeft: "Least left"
            case .material: "Material"
            case .colour: "Colour"
            }
        }
    }

    /// The button a state offers.
    public enum Action: Equatable, Sendable {
        /// Check Bambuddy again (clears a Spoolman refusal), then load.
        case retry
        /// The view opens Settings; `perform` does nothing.
        case openSettings
        /// Drop the material filter.
        case showAllMaterials

        public var title: String {
            switch self {
            case .retry: "Retry"
            case .openSettings: "Open Settings"
            case .showAllMaterials: SpoolsViewModel.allMaterialsTitle
            }
        }
    }

    /// What shows in place of the list, or of its rows (`ContentUnavailableView`).
    public struct Unavailable: Equatable, Sendable {
        public let title: String
        public let systemImage: String
        public let message: String
        public let action: Action?
        /// The symbol is red: something is wrong, not merely empty.
        public let isProblem: Bool

        public static let connectBambuddy = Unavailable(
            title: "Connect Bambuddy", systemImage: "server.rack",
            message: "Scan the API-key QR code in Bambuddy, or type its address.", action: .openSettings,
            isProblem: false
        )
        public static let needsHTTPS = Unavailable(
            title: "Bambuddy needs HTTPS", systemImage: "lock.slash",
            message: "FliBuddy talks to Bambuddy over https:// only. Change the address in Settings.",
            action: .openSettings, isProblem: true
        )
        public static let untrustedCertificate = Unavailable(
            title: "Bambuddy's certificate is not trusted", systemImage: "lock.trianglebadge.exclamationmark",
            message: "This device does not trust the certificate Bambuddy uses for https://.", action: .retry,
            isProblem: true
        )
        public static let unreachable = Unavailable(
            title: "Can't reach Bambuddy", systemImage: "wifi.exclamationmark",
            message: "Check that Bambuddy is running and on the same network.", action: .retry, isProblem: true
        )
        public static let noPermission = Unavailable(
            title: "Can't read the inventory", systemImage: "lock.trianglebadge.exclamationmark",
            message: "The API key needs the inventory:read permission. Add it to the key in Bambuddy.",
            action: .openSettings, isProblem: true
        )
        public static let keyRejected = Unavailable(
            title: "Bambuddy rejected the API key", systemImage: "lock.trianglebadge.exclamationmark",
            message: "Check the key in Settings, or scan the QR code of a new one.", action: .openSettings,
            isProblem: true
        )
        /// The feed's blocking screen, word for word.
        public static let spoolmanMode = Unavailable(
            title: "Bambuddy is in Spoolman mode", systemImage: "nosign",
            message: "FliBuddy works with Bambuddy's own inventory. Switch Bambuddy's inventory back from Spoolman in its settings, then retry.",
            action: .retry, isProblem: true
        )
        public static let noSpools = Unavailable(
            title: "No spools in Bambuddy", systemImage: "shippingbox",
            message: "Spools added in Bambuddy, or with New in the feed, show here.", action: nil, isProblem: false
        )

        static func noMatch(_ query: String) -> Unavailable {
            Unavailable(
                title: "No spools match \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass",
                message: "Search looks at material, colour, brand and note.", action: nil, isProblem: false
            )
        }

        static func noMaterial(_ material: String) -> Unavailable {
            Unavailable(
                title: "No \(material) spools", systemImage: "line.3.horizontal.decrease.circle",
                message: "Choose All materials to see every spool.", action: .showAllMaterials, isProblem: false
            )
        }

        static func emptyScope(_ scope: Scope) -> Unavailable {
            Unavailable(
                title: scope == .archived ? "No archived spools" : "No active spools", systemImage: "shippingbox",
                message: "Bambuddy has spools in the other scope.", action: nil, isProblem: false
            )
        }
    }

    public enum Content: Equatable, Sendable {
        /// Nothing loaded yet.
        case loading
        case unavailable(Unavailable)
        /// The list (`rows`, or `emptyResult` when none pass the filters).
        case list
    }

    /// One row of the list.
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: Int
        public let swatch: Swatch?
        /// `PLA Matte`.
        public let title: String
        /// `Charcoal · Bambu Lab`; `nil` without either.
        public let subtitle: String?
        /// `410 g left of 1000 · updated 3 d ago`.
        public let detail: String
        /// `410 g left of 1000`: `detail` without the update, where it does not fit.
        public let left: String
        public let isLow: Bool
        public let isArchived: Bool
        public let hasTag: Bool
        /// The whole row in one sentence.
        public let accessibilityLabel: String
    }

    /// The read-only detail of one spool.
    public struct Detail: Equatable, Sendable {
        public static let footer = "Read-only. Edit spools in Bambuddy."
        public static let openTitle = "Open in Bambuddy"
        public static let todayTitle = "Today"
        public static let detailsTitle = "Details"

        /// A labelled value in Details.
        public struct Fact: Equatable, Sendable {
            public let label: String
            public let value: String
            public let monospaced: Bool

            public init(_ label: String, _ value: String, monospaced: Bool = false) {
                self.label = label
                self.value = value
                self.monospaced = monospaced
            }
        }

        /// Today's feed row for the spool: its status phrase and look.
        public struct Today: Equatable, Sendable {
            public let text: String
            public let symbol: StatusSymbol
            public let tint: StatusTint
        }

        public let id: Int
        public let swatch: Swatch?
        public let title: String
        public let subtitle: String?
        /// What is left of the label weight, 0...1.
        public let fraction: Double
        /// `410 g left of 1000 g`.
        public let gaugeText: String
        /// `41%`.
        public let percentText: String
        public let isLow: Bool
        public let facts: [Fact]
        public let today: Today?
        /// The spool in Bambuddy's inventory page; `nil` without a usable URL.
        public let bambuddyURL: URL?
    }

    /// Why the last load failed.
    enum Problem: Equatable {
        case noServer
        case needsHTTPS
        case untrustedCertificate
        case spoolman
        case noPermission
        case rejected
        case unreachable
    }

    // MARK: State

    /// The search text, scope, material and sort the list applies.
    public var query = ""
    public var scope = Scope.active
    public var material: String?
    public var sort = Sort.recentlyUpdated
    /// The spool whose detail is open.
    public var selection: Spool.ID?
    public var settings: Settings
    public private(set) var isLoading = false
    /// When the cached list was loaded.
    public private(set) var loadedAt: Date?
    /// The feed, for the detail's Today line.
    let feed: FeedViewModel?

    private let session: Session
    private let now: @Sendable () -> Date
    private let locale: Locale
    private let timeZone: TimeZone
    /// The cache: the last good list and the settings it came from.
    private var spools: [Spool] = []
    private var listedUnder: Int?
    private var catalog: [CatalogEntry] = []
    private var catalogUnder: Int?
    private var problem: Problem?
    /// Counts loads; only the latest one publishes (`forgetList` counts too).
    private var loads = 0
    /// A load was started since the list was last forgotten.
    private var started = false
    private var seenRevision: Int?

    /// `locale` and `timeZone` format the time of the cached list and the
    /// archive date; the rest of the texts are English, as the app is.
    public init(
        session: Session, feed: FeedViewModel? = nil, settings: Settings,
        now: @escaping @Sendable () -> Date = { Date() }, locale: Locale = .current, timeZone: TimeZone = .current
    ) {
        self.session = session
        self.feed = feed
        self.settings = settings
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
    }

    // MARK: Loading

    /// Loads once, when nothing was loaded yet (the iPad sidebar's count).
    public func loadIfNeeded() async {
        guard loadedAt == nil, !started else { return }
        await refresh()
    }

    /// Loads the list again. A failure keeps a cached list from the same
    /// settings when Bambuddy did not answer; any other failure, or a list
    /// from other settings, replaces it with the state.
    public func refresh() async {
        loads += 1
        let load = loads
        started = true
        isLoading = true
        let result: Result<SpoolListing, any Error>
        do {
            result = .success(try await session.listSpools(includeArchived: true))
        } catch {
            result = .failure(error)
        }
        // The catalog only names the empty spool; without it the grams stand
        // alone. Loaded once per settings.
        var entries: [CatalogEntry]?
        if case .success(let listing) = result, catalogUnder != listing.configuration {
            entries = try? await session.catalog()
        }
        let state = await session.snapshot.bambuddy
        let current = await session.currentConfiguration
        guard load == loads else { return }
        isLoading = false
        switch result {
        case .success(let listing) where listing.configuration != current:
            // Listed under settings that have changed since (another URL or key).
            dropCache()
            Log.info(.session, "spools: dropped a list from older settings")
            return
        case .success(let listing):
            spools = listing.spools
            listedUnder = listing.configuration
            if let entries {
                catalog = entries
                catalogUnder = listing.configuration
            }
            loadedAt = now()
            problem = nil
            let archived = listing.spools.filter(\.isArchived).count
            Log.info(.session, "spools: loaded n=\(listing.spools.count) archived=\(archived)")
        case .failure(let error) where error is CancellationError:
            return
        case .failure(let error):
            problem = Self.problem(after: error, state: state)
            if problem != .unreachable || listedUnder != current { dropCache() }
            Log.error(.session, "spools: load failed: \(Session.describe(error))")
        }
        if let selection, !spools.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// Another Bambuddy URL or key: the list belongs to the old one. Loads
    /// again when a list was loaded before.
    public func serverChanged() async {
        if forgetList() { await refresh() }
    }

    /// Drops the list, its state and the pick at once (`HostModel` loads
    /// again after its check); true when something had been loaded.
    func forgetList() -> Bool {
        let hadList = loadedAt != nil || started
        started = false
        // A load still under way speaks for the old settings: it must not publish.
        loads += 1
        isLoading = false
        dropCache()
        problem = nil
        selection = nil
        return hadList
    }

    /// A state's button.
    public func perform(_ action: Action) async {
        switch action {
        case .retry:
            await session.checkBambuddy()
            await refresh()
        case .openSettings: break
        case .showAllMaterials: material = nil
        }
    }

    /// Follows the session until the calling task is cancelled: each write it
    /// makes to Bambuddy loads the list again, once a list was loaded.
    public func observe() async {
        for await snapshot in await session.snapshots() {
            defer { seenRevision = snapshot.inventoryRevision }
            guard let seen = seenRevision, seen != snapshot.inventoryRevision, loadedAt != nil || problem != nil else {
                continue
            }
            await refresh()
        }
    }

    private func dropCache() {
        spools = []
        listedUnder = nil
        catalog = []
        catalogUnder = nil
        loadedAt = nil
    }

    nonisolated static func problem(after error: any Error, state: BambuddyState) -> Problem {
        switch error {
        case SessionError.notReady:
            switch state {
            case .notConfigured: .noServer
            case .needsHTTPS: .needsHTTPS
            case .untrustedCertificate: .untrustedCertificate
            case .refused(.spoolmanMode): .spoolman
            case .refused(.permissionMissing): .noPermission
            case .refused(.unauthorized): .rejected
            case .unchecked, .ready, .unreachable: .unreachable
            }
        case BambuddyError.permissionMissing: .noPermission
        case BambuddyError.unauthorized: .rejected
        case BambuddyError.untrustedCertificate: .untrustedCertificate
        default: .unreachable
        }
    }

    // MARK: What the views show

    public var content: Content {
        switch problem {
        case .noServer: return .unavailable(.connectBambuddy)
        case .needsHTTPS: return .unavailable(.needsHTTPS)
        case .untrustedCertificate: return .unavailable(.untrustedCertificate)
        case .spoolman: return .unavailable(.spoolmanMode)
        case .noPermission: return .unavailable(.noPermission)
        case .rejected: return .unavailable(.keyRejected)
        case .unreachable where loadedAt == nil: return .unavailable(.unreachable)
        case .unreachable, nil: return loadedAt == nil ? .loading : .list
        }
    }

    /// `Couldn't refresh · showing 10:42` over a cached list Bambuddy did not
    /// refresh.
    public var staleNotice: String? {
        guard problem == .unreachable, let loadedAt else { return nil }
        let time = loadedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        return "Couldn't refresh \u{00B7} showing \(time)"
    }

    /// The spools of the scope that pass the search and the material, sorted.
    public var rows: [Row] {
        guard content == .list else { return [] }
        let now = now()
        return Self.sorted(shown, by: sort).map { Self.row($0, now: now) }
    }

    /// In place of the rows when none pass the filters.
    public var emptyResult: Unavailable? {
        guard content == .list, shown.isEmpty else { return nil }
        if spools.isEmpty { return .noSpools }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { return .noMatch(words) }
        if let material { return .noMaterial(material) }
        return .emptyScope(scope)
    }

    /// The materials in the inventory, for the filter menu.
    public var materials: [String] {
        Set(spools.map(\.material)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A material is chosen (the menu's symbol fills).
    public var isFiltering: Bool { material != nil }

    /// Active spools in the list; `nil` until one loaded (the sidebar badge).
    public var activeCount: Int? {
        content == .list ? spools.filter { !$0.isArchived }.count : nil
    }

    /// `7 active spools. Pull down to refresh.` under the list.
    public var footer: String? {
        guard let count = activeCount else { return nil }
        return "\(count) active spool\(count == 1 ? "" : "s"). Pull down to refresh."
    }

    public var selectedDetail: Detail? {
        selection.flatMap(detail(for:))
    }

    public func detail(for id: Spool.ID) -> Detail? {
        guard content == .list, let spool = spools.first(where: { $0.id == id }) else { return nil }
        let today = feed?.items.first { $0.spoolId == id }.map {
            Detail.Today(text: $0.statusText, symbol: $0.statusSymbol, tint: $0.statusTint)
        }
        return Detail(
            id: spool.id, swatch: spool.rgba.flatMap(Swatch.init(rgba:)), title: Self.title(spool),
            subtitle: Self.subtitle(spool), fraction: Self.fraction(spool),
            gaugeText: "\(spool.remaining) g left of \(spool.labelWeight) g",
            percentText: "\(Int((Self.fraction(spool) * 100).rounded()))%", isLow: Self.isLow(spool),
            facts: facts(spool), today: today,
            bambuddyURL: Self.bambuddyURL(base: settings.baseURL, spoolId: spool.id)
        )
    }

    private var shown: [Spool] {
        let inScope = spools.filter { spool in
            switch scope {
            case .active: !spool.isArchived
            case .archived: spool.isArchived
            case .all: true
            }
        }
        let ofMaterial = material.map { material in inScope.filter { $0.material == material } } ?? inScope
        return LinkPickerModel.filter(ofMaterial, query: query)
    }

    private func facts(_ spool: Spool) -> [Detail.Fact] {
        typealias Fact = Detail.Fact
        let entry = spool.coreWeightCatalogId.flatMap { id in catalog.first { $0.id == id } }
        var facts = [Fact("Material", spool.material)]
        if let subtype = Self.present(spool.subtype) { facts.append(Fact("Subtype", subtype)) }
        if let brand = Self.present(spool.brand) { facts.append(Fact("Brand", brand)) }
        facts.append(Fact("Label weight", "\(spool.labelWeight) g"))
        facts.append(Fact("Empty spool", entry.map { "\($0.name) \u{00B7} \(spool.coreWeight) g" } ?? "\(spool.coreWeight) g"))
        facts.append(Fact("Last scale weight", spool.lastScaleWeight.map { "\($0) g" } ?? "Never weighed"))
        let tag = Self.present(spool.tagUid) ?? Self.present(spool.trayUuid)
        facts.append(tag.map { Fact("Tag", $0, monospaced: true) } ?? Fact("Tag", "No tag"))
        if let note = Self.present(spool.note) { facts.append(Fact("Note", note)) }
        facts.append(Fact("Spool #", "\(spool.id)"))
        if spool.isArchived {
            let date = spool.archivedAt.flatMap(BambuddyDate.parse).map {
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
            }
            facts.append(Fact("Archived on", date ?? spool.archivedAt ?? "Yes"))
        }
        return facts
    }

    // MARK: Formatting

    nonisolated static func title(_ spool: Spool) -> String {
        FeedItem.title(material: spool.material, subtype: spool.subtype)
    }

    nonisolated static func subtitle(_ spool: Spool) -> String? {
        let parts = [spool.colorName, spool.brand].compactMap(present)
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    nonisolated static func fraction(_ spool: Spool) -> Double {
        guard spool.labelWeight > 0 else { return 0 }
        return min(1, Double(spool.remaining) / Double(spool.labelWeight))
    }

    /// Less than 15 % of the label weight left on an active spool.
    nonisolated static func isLow(_ spool: Spool) -> Bool {
        !spool.isArchived && spool.labelWeight > 0 && Double(spool.remaining) < Double(spool.labelWeight) * lowFraction
    }

    nonisolated static func row(_ spool: Spool, now: Date) -> Row {
        let title = title(spool)
        let low = isLow(spool)
        let updated = spool.updatedDate
        let left = "\(spool.remaining) g left of \(spool.labelWeight)"
        let detail = updated.map { "\(left) \u{00B7} updated \(ago($0, now: now))" } ?? left
        let hasTag = present(spool.tagUid) != nil || present(spool.trayUuid) != nil
        let spoken: [String?] = [
            title, present(spool.colorName), present(spool.brand),
            "\(spool.remaining) grams left of \(spool.labelWeight)", low ? "low" : nil,
            spool.isArchived ? "archived" : nil, hasTag ? "tag linked" : nil,
            updated.map { "updated \(ago($0, now: now, spelledOut: true))" },
        ]
        return Row(
            id: spool.id, swatch: spool.rgba.flatMap(Swatch.init(rgba:)), title: title, subtitle: subtitle(spool),
            detail: detail, left: left, isLow: low, isArchived: spool.isArchived, hasTag: hasTag,
            accessibilityLabel: spoken.compactMap { $0 }.joined(separator: ", ") + "."
        )
    }

    /// `just now`, `5 min ago`, `3 h ago`, `3 d ago`, `2 mo ago`, `1 y ago`
    /// (whole units, rounded down; a time ahead of `now` is `just now`);
    /// `spelledOut` for VoiceOver: `3 days ago`.
    public nonisolated static func ago(_ date: Date, now: Date, spelledOut: Bool = false) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        guard minutes >= 1 else { return "just now" }
        let (count, short, long): (Int, String, String) = switch minutes {
        case ..<60: (minutes, "min", "minute")
        case ..<(24 * 60): (minutes / 60, "h", "hour")
        case ..<(30 * 24 * 60): (minutes / (24 * 60), "d", "day")
        case ..<(365 * 24 * 60): (minutes / (30 * 24 * 60), "mo", "month")
        default: (minutes / (365 * 24 * 60), "y", "year")
        }
        return spelledOut ? "\(count) \(long)\(count == 1 ? "" : "s") ago" : "\(count) \(short) ago"
    }

    /// Ties fall back to the id, so the order never jumps between loads.
    nonisolated static func sorted(_ spools: [Spool], by sort: Sort) -> [Spool] {
        func text(_ a: String?, _ b: String?) -> ComparisonResult? {
            switch (present(a), present(b)) {
            case let (a?, b?):
                let order = a.localizedStandardCompare(b)
                return order == .orderedSame ? nil : order
            case (nil, _?): return .orderedDescending
            case (_?, nil): return .orderedAscending
            case (nil, nil): return nil
            }
        }
        return spools.sorted { a, b in
            let order: ComparisonResult? = switch sort {
            case .recentlyUpdated:
                switch (a.updatedDate, b.updatedDate) {
                case let (x?, y?) where x != y: x > y ? .orderedAscending : .orderedDescending
                case (nil, _?): .orderedDescending
                case (_?, nil): .orderedAscending
                default: nil
                }
            case .leastLeft:
                a.remaining == b.remaining ? text(title(a), title(b))
                    : (a.remaining < b.remaining ? .orderedAscending : .orderedDescending)
            case .material: text(title(a), title(b)) ?? text(a.colorName, b.colorName)
            case .colour: text(a.colorName, b.colorName) ?? text(title(a), title(b))
            }
            return (order ?? (a.id < b.id ? .orderedAscending : .orderedDescending)) == .orderedAscending
        }
    }

    /// `<Bambuddy URL>/inventory?spool=<id>`: Bambuddy's inventory page opens
    /// the spool's form for it. A path prefix (reverse proxy) is kept; a
    /// `user:password@` is dropped rather than handed to the browser.
    public nonisolated static func bambuddyURL(base: String, spoolId: Int) -> URL? {
        let text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        var prefix = components.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.user = nil
        components.password = nil
        components.path = prefix + "/inventory"
        components.queryItems = [URLQueryItem(name: "spool", value: String(spoolId))]
        components.fragment = nil
        return components.url
    }

    private nonisolated static func present(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
