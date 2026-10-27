import Foundation
import Observation

/// The session feed for the views: rows newest scan first, the weight draft
/// of each row, and the host actions (save, reopen, New, Link, Clear).
@MainActor
@Observable
public final class FeedViewModel {
    /// Weights are 0...9999 g, so four digits.
    public nonisolated static let maxWeightDigits = 4

    public private(set) var items: [FeedItem] = []
    public private(set) var bambuddy: BambuddyState = .unchecked
    /// Why new items get no colour names, when the colour map failed to load.
    public private(set) var colorNamesProblem: String?
    public private(set) var isCheckingBambuddy = false
    /// The New form's core weight and the preselected weight mode come from here.
    public var settings: Settings

    /// Bambuddy's spools for the Link picker; see `loadLinkCandidates()`.
    public private(set) var linkCandidates: [Spool] = []
    /// The list `linkCandidates` came from; Link names it to the session.
    private var linkListing: SpoolListing?
    /// The Link picker's pick; every load of `linkCandidates` drops it, when
    /// it starts and when it ends, as an id of an older list may name another
    /// spool in the new one.
    public var linkSelection: Spool.ID?
    public private(set) var linkError: String?
    public private(set) var isLoadingLinkCandidates = false
    /// Counts the loads of `linkCandidates`; only the latest one publishes.
    private var linkLoads = 0

    /// Which row has the keyboard; see `FocusModel`.
    public private(set) var focus = FocusModel()
    /// Sheets open over the feed (New, Link, Tag details): while any is, no
    /// weight field takes the keyboard.
    private var openSheets = 0

    /// The haptic a host action asks for: success after a save, error after
    /// any failed action. A new value per event, so the same kind twice in a
    /// row still plays.
    public struct Haptic: Equatable, Sendable {
        public enum Kind: Sendable {
            case success
            case error
        }

        public var kind: Kind
        public var serial: Int
    }

    public private(set) var haptic: Haptic?

    /// A row's weight field: the suggestion until the user types (`touched`),
    /// then what they typed; and the mode it is in.
    public struct Draft: Equatable, Sendable {
        public var value: String
        public var touched: Bool
        public var mode: Intent.WeightMode

        public init(value: String, touched: Bool, mode: Intent.WeightMode) {
            self.value = value
            self.touched = touched
            self.mode = mode
        }
    }

    private let session: Session
    private var rows: [FeedRow.ID: FeedRow] = [:]
    private var itemsByID: [FeedRow.ID: FeedItem] = [:]
    /// What the user typed; absent while the field shows the suggestion.
    private var weightTexts: [FeedRow.ID: String] = [:]
    private var modes: [FeedRow.ID: Intent.WeightMode] = [:]
    private var errors: [FeedRow.ID: String] = [:]
    private var busy: Set<FeedRow.ID> = []
    /// Rows that waited for a weight, or were saving one, at the last snapshot.
    private var waitingIDs: Set<FeedRow.ID> = []
    private var entryIDs: Set<FeedRow.ID> = []

    public init(session: Session, settings: Settings) {
        self.session = session
        self.settings = settings
    }

    /// Follows the session until the calling task is cancelled.
    public func observe() async {
        for await snapshot in await session.snapshots() {
            apply(snapshot)
        }
    }

    public func apply(_ snapshot: SessionSnapshot) {
        // The session keeps rows by last scan, newest last.
        items = snapshot.rows.reversed().map { FeedItem($0, coreWeight: settings.coreWeight) }
        rows = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        bambuddy = snapshot.bambuddy
        colorNamesProblem = snapshot.colorNamesProblem
        isCheckingBambuddy = snapshot.isCheckingBambuddy
        for id in Set(weightTexts.keys).union(modes.keys).union(errors.keys) where rows[id] == nil {
            forget(id)
        }
        // A row that left weight entry (saved, also from the Flipper, or
        // scanned again) drops the host's draft.
        for id in Set(weightTexts.keys).union(modes.keys) where itemsByID[id]?.isEntry != true {
            weightTexts[id] = nil
            modes[id] = nil
        }
        updateFocus()
    }

    public func item(_ id: FeedRow.ID) -> FeedItem? {
        itemsByID[id]
    }

    /// What Tag details lists for the row.
    public func tagDetails(for id: FeedRow.ID) -> TagDetails? {
        rows[id].map(TagDetails.init)
    }

    /// The Bambuddy half of the status bar.
    public var bambuddyStatus: StatusItem {
        bambuddy.statusItem(colorNamesProblem: colorNamesProblem, isChecking: isCheckingBambuddy)
    }

    /// Spoolman mode: FliBuddy cannot work at all, so the feed gives way to
    /// an explanation until a check finds the internal inventory again.
    public var isBlocked: Bool {
        bambuddy == .refused(.spoolmanMode)
    }

    // MARK: Weight entry

    /// Digits only, at most four, without leading zeros: a digit typed after
    /// a lone `0` replaces it.
    public nonisolated static func sanitizeWeight(_ text: String) -> String {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        let significant = digits.drop { $0 == "0" }
        return String((significant.isEmpty ? digits.prefix(1) : significant).prefix(maxWeightDigits))
    }

    public nonisolated static func grams(from text: String) -> Int? {
        Int(sanitizeWeight(text))
    }

    /// The typed value, else the suggestion in the row's mode.
    public func draft(for id: FeedRow.ID) -> Draft {
        let mode = mode(for: id)
        if let typed = weightTexts[id] { return Draft(value: typed, touched: true, mode: mode) }
        let suggestion = itemsByID[id]?.suggestion(mode: mode)
        return Draft(value: suggestion.map(String.init) ?? "", touched: false, mode: mode)
    }

    public func weightText(for id: FeedRow.ID) -> String {
        draft(for: id).value
    }

    /// The user typed: the field keeps this value through a mode switch. A
    /// write of the unchanged suggestion (a field echoing its value when it
    /// loses focus) leaves the row untouched.
    public func setWeightText(_ text: String, for id: FeedRow.ID) {
        let text = Self.sanitizeWeight(text)
        let current = draft(for: id)
        guard current.touched || text != current.value else { return }
        weightTexts[id] = text
        focus.update(rows: focusRows())
    }

    /// The line under the field for the current draft.
    public func readout(for id: FeedRow.ID) -> FeedItem.Readout? {
        guard let item = itemsByID[id] else { return nil }
        let draft = draft(for: id)
        return item.readout(value: Self.grams(from: draft.value), mode: draft.mode)
    }

    /// What the row was last saved in, else the default from the settings.
    public func mode(for id: FeedRow.ID) -> Intent.WeightMode {
        modes[id] ?? rows[id]?.weight?.mode ?? settings.defaultMode
    }

    /// Switching converts the number on screen. An untouched suggestion
    /// follows the mode (it is derived from it) and stays untouched; a typed
    /// value is converted and stays typed; an empty field stays empty.
    public func setMode(_ mode: Intent.WeightMode, for id: FeedRow.ID) {
        let old = self.mode(for: id)
        modes[id] = mode
        guard mode != old, let typed = weightTexts[id], let grams = Self.grams(from: typed) else { return }
        weightTexts[id] = String(Self.convert(grams, to: mode, core: itemsByID[id]?.core))
    }

    /// A weight in the other mode: to net `grams − core`, not below 0 (as on
    /// the Flipper); to gross `grams + core`, not above 9999.
    public nonisolated static func convert(_ grams: Int, to mode: Intent.WeightMode, core: Int?) -> Int {
        let core = max(0, core ?? 0)
        return mode == .net ? max(0, grams - core) : min(CrownWeight.range.upperBound, grams + core)
    }

    public func isBusy(_ id: FeedRow.ID) -> Bool {
        busy.contains(id)
    }

    /// A weight for the row is on its way to Bambuddy (the session says so;
    /// `isBusy` also covers New and Link).
    public func isSaving(_ id: FeedRow.ID) -> Bool {
        itemsByID[id]?.isSaving == true
    }

    /// "Save", or "Saving…" while the weight is on its way.
    public func saveTitle(for id: FeedRow.ID) -> String {
        isSaving(id) ? "Saving\u{2026}" : "Save"
    }

    /// The last host action on the row failed with this message.
    public func error(for id: FeedRow.ID) -> String? {
        errors[id]
    }

    /// Disabled while empty, below the core weight in gross, or saving.
    public func canSave(_ id: FeedRow.ID) -> Bool {
        guard let item = itemsByID[id], item.isEntry, !item.isSaving, !busy.contains(id) else { return false }
        return readout(for: id).map { !$0.isError } == true && Self.grams(from: weightText(for: id)) != nil
    }

    /// Opens a saved row again for a re-weigh.
    public func reopen(_ id: FeedRow.ID) async {
        guard itemsByID[id]?.isReopenable == true else { return }
        await session.reopen(row: id)
        apply(await session.snapshot)
    }

    /// Records the row's weight; true when Bambuddy took it.
    @discardableResult
    public func save(_ id: FeedRow.ID) async -> Bool {
        guard canSave(id), let grams = Self.grams(from: weightText(for: id)) else { return false }
        let mode = mode(for: id)
        guard await perform(id, { try await $0.saveWeight(row: id, grams: grams, mode: mode) }) else { return false }
        weightTexts[id] = nil
        modes[id] = nil
        play(.success)
        return true
    }

    // MARK: Focus

    /// The row with the keyboard, for the list selection and the field focus.
    public var focusedRow: FeedRow.ID? {
        get { focus.focusedRow }
        set { focus.focus(newValue) }
    }

    /// The weight field that has the keyboard: the focused row's, while it
    /// shows one. A row that turns back into an entry (a re-weigh, a rescan)
    /// gets its field focused again although `focusedRow` did not change.
    /// None while a sheet is open; the row keeps its focus for when it closes.
    public var focusedField: FeedRow.ID? {
        guard openSheets == 0 else { return nil }
        return focus.focusedRow.flatMap { itemsByID[$0]?.isEntry == true ? $0 : nil }
    }

    /// A sheet over the feed appeared; pair with `sheetClosed()`.
    public func sheetOpened() {
        openSheets += 1
    }

    public func sheetClosed() {
        openSheets = max(0, openSheets - 1)
    }

    /// ⌘↑ / ⌘↓.
    public func moveFocus(_ direction: FocusModel.Direction) {
        focus.moveFocus(direction)
    }

    /// ⌘S: saves the focused row when it can be saved.
    public func saveFocused() async {
        guard let id = focus.focusedRow else { return }
        await save(id)
    }

    /// Acts on what changed since the last snapshot only, so a refresh never
    /// moves focus: rows that started waiting (oldest first, so the newest
    /// wins) and rows that went from weight entry to saved.
    private func updateFocus() {
        focus.update(rows: focusRows())
        let waiting = Set(items.filter(\.isWaiting).map(\.id))
        for item in items.reversed() where item.isWaiting && !waitingIDs.contains(item.id) {
            focus.onRowBecameWaiting(item.id)
        }
        for item in items where item.isReopenable && entryIDs.contains(item.id) {
            focus.onSaved(item.id)
        }
        waitingIDs = waiting
        entryIDs = Set(items.filter(\.isEntry).map(\.id))
    }

    private func focusRows() -> [FocusModel.Row] {
        items.map { FocusModel.Row(id: $0.id, isWaiting: $0.isWaiting, isTouched: weightTexts[$0.id] != nil) }
    }

    // MARK: Unknown tags

    public func newSpoolForm(for id: FeedRow.ID) -> NewSpoolForm? {
        rows[id].map { NewSpoolForm(tag: $0.tag, settings: settings, colorName: $0.colorName) }
    }

    /// New without the form: the tag's own data and the settings' defaults
    /// (the retry after a failed create on scan).
    public func createFromTag(_ id: FeedRow.ID) async -> Bool {
        guard let form = newSpoolForm(for: id) else { return false }
        return await create(id, form)
    }

    /// Creates the item from the form and links the row; `false` when it failed.
    public func create(_ id: FeedRow.ID, _ form: NewSpoolForm) async -> Bool {
        guard let newSpool = form.newSpool else { return false }
        return await perform(id) { try await $0.createSpool(row: id, newSpool) }
    }

    /// Links the row to a spool of `linkCandidates`. A pick from a list of
    /// older settings links nothing and loads the list again; so does a pick
    /// while the list loads.
    public func link(_ id: FeedRow.ID, toSpool spoolId: Int) async -> Bool {
        guard !isLoadingLinkCandidates else { return false }
        var stale = false
        let linked = await perform(id) { session in
            do {
                guard let listing = linkListing else { throw SessionError.staleSpoolList }
                try await session.link(row: id, toSpool: spoolId, from: listing)
            } catch SessionError.staleSpoolList {
                stale = true
                throw SessionError.staleSpoolList
            }
        }
        if stale { await loadLinkCandidates() }
        return linked
    }

    /// Loads overlap when the picker closes and opens again before the first
    /// ends: only the latest one ends the loading, and a cancelled one (the
    /// picker closed) leaves the list and its error as they were.
    public func loadLinkCandidates() async {
        linkLoads += 1
        let load = linkLoads
        isLoadingLinkCandidates = true
        linkSelection = nil
        let listed: Result<SpoolListing, any Error>
        do {
            listed = .success(try await session.listSpools())
        } catch {
            listed = .failure(error)
        }
        guard load == linkLoads else { return }
        isLoadingLinkCandidates = false
        linkSelection = nil
        if !Task.isCancelled {
            switch listed {
            case .success(let listing):
                linkListing = listing
                linkCandidates = listing.spools
                linkError = nil
            case .failure(let error):
                linkListing = nil
                linkCandidates = []
                linkError = Session.describe(error)
            }
        }
        apply(await session.snapshot)
    }

    // MARK: Feed

    public func clear() async {
        await session.clear()
        apply(await session.snapshot)
    }

    // MARK: Plumbing

    @discardableResult
    private func perform(_ id: FeedRow.ID, _ action: (Session) async throws -> Void) async -> Bool {
        busy.insert(id)
        errors[id] = nil
        defer { busy.remove(id) }
        let ok: Bool
        do {
            try await action(session)
            ok = true
        } catch {
            errors[id] = Session.describe(error)
            ok = false
            play(.error)
        }
        apply(await session.snapshot)
        return ok
    }

    private func play(_ kind: Haptic.Kind) {
        haptic = Haptic(kind: kind, serial: (haptic?.serial ?? 0) + 1)
    }

    private func forget(_ id: FeedRow.ID) {
        weightTexts[id] = nil
        modes[id] = nil
        errors[id] = nil
    }
}
