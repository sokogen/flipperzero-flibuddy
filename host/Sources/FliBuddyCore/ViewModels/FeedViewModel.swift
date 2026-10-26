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
    /// The New form's core weight and the preselected weight mode come from here.
    public var settings: Settings

    /// Bambuddy's spools for the Link picker; see `loadLinkCandidates()`.
    public private(set) var linkCandidates: [Spool] = []
    public private(set) var linkError: String?
    public private(set) var isLoadingLinkCandidates = false

    /// Which row has the keyboard; see `FocusModel`.
    public private(set) var focus = FocusModel()

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
        items = snapshot.rows.reversed().map(FeedItem.init)
        rows = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        bambuddy = snapshot.bambuddy
        colorNamesProblem = snapshot.colorNamesProblem
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

    // MARK: Weight entry

    /// Digits only, at most four.
    public nonisolated static func sanitizeWeight(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(maxWeightDigits))
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

    /// An untouched suggestion follows the mode (it is derived from it); a
    /// typed value stays as it is.
    public func setMode(_ mode: Intent.WeightMode, for id: FeedRow.ID) {
        modes[id] = mode
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

    public func save(_ id: FeedRow.ID) async {
        guard canSave(id), let grams = Self.grams(from: weightText(for: id)) else { return }
        let mode = mode(for: id)
        if await perform(id, { try await $0.saveWeight(row: id, grams: grams, mode: mode) }) {
            weightTexts[id] = nil
            modes[id] = nil
        }
    }

    // MARK: Focus

    /// The row with the keyboard, for the list selection and the field focus.
    public var focusedRow: FeedRow.ID? {
        get { focus.focusedRow }
        set { focus.focus(newValue) }
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

    public func link(_ id: FeedRow.ID, toSpool spoolId: Int) async -> Bool {
        await perform(id) { try await $0.link(row: id, toSpool: spoolId) }
    }

    public func loadLinkCandidates() async {
        isLoadingLinkCandidates = true
        defer { isLoadingLinkCandidates = false }
        do {
            linkCandidates = try await session.listSpools()
            linkError = nil
        } catch {
            linkCandidates = []
            linkError = Session.describe(error)
        }
        apply(await session.snapshot)
    }

    public func linkMatches(_ query: String) -> [Spool] {
        Self.filter(linkCandidates, query: query)
    }

    /// Spools where every word of `query` appears in the material, subtype,
    /// colour, brand or note, ignoring case and diacritics.
    public static func filter(_ spools: [Spool], query: String) -> [Spool] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return spools }
        return spools.filter { spool in
            let fields = [spool.material, spool.subtype, spool.colorName, spool.brand, spool.note].compactMap { $0 }
            return words.allSatisfy { word in
                fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
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
        }
        apply(await session.snapshot)
        return ok
    }

    private func forget(_ id: FeedRow.ID) {
        weightTexts[id] = nil
        modes[id] = nil
        errors[id] = nil
    }
}
