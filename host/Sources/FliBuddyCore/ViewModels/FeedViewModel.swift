import Foundation
import Observation

/// The session feed for the views: rows newest first, the weight being typed
/// for each row, and the host actions (save, New, Link, Clear).
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

    private let session: Session
    private var rows: [FeedRow.ID: FeedRow] = [:]
    private var weightTexts: [FeedRow.ID: String] = [:]
    private var modes: [FeedRow.ID: Intent.WeightMode] = [:]
    private var errors: [FeedRow.ID: String] = [:]
    private var busy: Set<FeedRow.ID> = []

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
        items = snapshot.rows.reversed().map(FeedItem.init)
        rows = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        bambuddy = snapshot.bambuddy
        colorNamesProblem = snapshot.colorNamesProblem
        for id in Set(weightTexts.keys).union(modes.keys).union(errors.keys) where rows[id] == nil {
            forget(id)
        }
    }

    // MARK: Weight entry

    /// Digits only, at most four.
    public nonisolated static func sanitizeWeight(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(maxWeightDigits))
    }

    public nonisolated static func grams(from text: String) -> Int? {
        Int(sanitizeWeight(text))
    }

    public func weightText(for id: FeedRow.ID) -> String {
        weightTexts[id] ?? ""
    }

    public func setWeightText(_ text: String, for id: FeedRow.ID) {
        weightTexts[id] = Self.sanitizeWeight(text)
    }

    /// What the row was last saved in, else the default from the settings.
    public func mode(for id: FeedRow.ID) -> Intent.WeightMode {
        modes[id] ?? rows[id]?.weight?.mode ?? settings.defaultMode
    }

    public func setMode(_ mode: Intent.WeightMode, for id: FeedRow.ID) {
        modes[id] = mode
    }

    public func isBusy(_ id: FeedRow.ID) -> Bool {
        busy.contains(id)
    }

    /// The last host action on the row failed with this message.
    public func error(for id: FeedRow.ID) -> String? {
        errors[id]
    }

    public func canSave(_ id: FeedRow.ID) -> Bool {
        guard let row = rows[id], row.spool != nil, !busy.contains(id) else { return false }
        return Self.grams(from: weightText(for: id)) != nil
    }

    public func save(_ id: FeedRow.ID) async {
        guard canSave(id), let grams = Self.grams(from: weightText(for: id)) else { return }
        let mode = mode(for: id)
        if await perform(id, { try await $0.saveWeight(row: id, grams: grams, mode: mode) }) {
            weightTexts[id] = nil
            modes[id] = nil
        }
    }

    // MARK: Unknown tags

    public func newSpoolForm(for id: FeedRow.ID) -> NewSpoolForm? {
        rows[id].map { NewSpoolForm(tag: $0.tag, settings: settings, colorName: $0.colorName) }
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
