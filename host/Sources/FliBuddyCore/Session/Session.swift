import Foundation

/// Why the session will not touch the inventory until it is checked again.
public enum Refusal: Equatable, Sendable {
    case spoolmanMode
    case permissionMissing(String)
    case unauthorized
}

/// The result of the startup check against Bambuddy.
public enum BambuddyState: Equatable, Sendable {
    /// Not checked yet; the first scan or intent checks.
    case unchecked
    /// No base URL or API key in the settings.
    case notConfigured
    case ready
    /// Spoolman mode or a key that cannot do the job; sticks until `checkBambuddy()`.
    case refused(Refusal)
    /// Bambuddy did not answer; the next scan or intent checks again.
    case unreachable(String)

    public var isReady: Bool { self == .ready }

    /// What the host shows when the session cannot use Bambuddy.
    public var message: String? {
        switch self {
        case .unchecked, .ready: nil
        case .notConfigured: "Set the Bambuddy URL and API key in Settings"
        case .refused(.spoolmanMode):
            "Bambuddy is in Spoolman mode; FliBuddy supports internal inventory only"
        case .refused(.permissionMissing(let permission)):
            "API key lacks the \(permission) permission; add it to the key in Bambuddy"
        case .refused(.unauthorized): "Bambuddy rejected the API key; check it in Settings"
        case .unreachable(let reason): reason
        }
    }

    /// The same, short enough for the Flipper screen.
    var flipperLines: [String] {
        switch self {
        case .unchecked, .ready: []
        case .notConfigured: ["Bambuddy not set up", "see host settings"]
        case .refused(.spoolmanMode): ["Spoolman mode", "not supported"]
        case .refused(.permissionMissing(let permission)): ["API key lacks", permission]
        case .refused(.unauthorized): ["API key rejected"]
        case .unreachable: ["Bambuddy unreachable"]
        }
    }
}

public enum SessionError: Error, Equatable, Sendable {
    case rowNotFound
    /// No spool carries the row's tag (UID given).
    case spoolNotFound(String)
    /// A host weight outside 0...9999 g.
    case invalidWeight(Int)
    /// Bambuddy is not usable; the message says why.
    case notReady(String)
}

extension SessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rowNotFound: "The feed row is gone"
        case .spoolNotFound(let uid): "No spool in Bambuddy carries tag \(uid)"
        case .invalidWeight(let grams): "Weight must be 0 to 9999 g, not \(grams)"
        case .notReady(let message): message
        }
    }
}

/// What the views render: the feed in arrival order, the Bambuddy state and
/// why colour names are missing, if they are.
public struct SessionSnapshot: Equatable, Sendable {
    public var rows: [FeedRow]
    public var bambuddy: BambuddyState
    public var colorNamesProblem: String?

    public init(rows: [FeedRow], bambuddy: BambuddyState, colorNamesProblem: String? = nil) {
        self.rows = rows
        self.bambuddy = bambuddy
        self.colorNamesProblem = colorNamesProblem
    }
}

/// The host session: turns Flipper scans into feed rows and `lookup` replies,
/// performs intents once per id, and lets the host edit any row.
///
/// The Flipper and the host are peers: whichever side saves a weight last wins,
/// and each row records which side that was.
public actor Session {
    /// Completed intent ids remembered for repeats (the Flipper retries by id).
    public static let resultCacheSize = 256

    public private(set) var rows: [FeedRow] = []
    public private(set) var bambuddy: BambuddyState = .unchecked
    public private(set) var settings: Settings
    /// Set when the colour map failed to load; new items then carry no colour name.
    public private(set) var colorNamesProblem: String?

    private var inventory: (any SpoolInventory)?
    /// Bumped by `reconfigure`; a check of older settings does not count.
    private var configuration = 0
    /// Bambuddy's colour names, loaded once per configuration after the
    /// startup check; `nil` until then or after a failed load.
    private var colorNames: ColorNameResolver?
    /// The startup check under way; overlapping callers wait for it.
    private var checking: Task<BambuddyState, Never>?
    /// Completed intents by id, with the intent that produced each result.
    private var results: [String: (intent: Intent, result: IntentResult)] = [:]
    private var resultOrder: [String] = []
    private var inFlight: [String: (intent: Intent, task: Task<IntentResult, Never>)] = [:]
    private var observers: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

    public init(settings: Settings, inventory: (any SpoolInventory)?) {
        self.settings = settings
        self.inventory = inventory
    }

    deinit {
        for observer in observers.values { observer.finish() }
    }

    /// New settings (and the client built from them); the next scan checks again.
    public func reconfigure(settings: Settings, inventory: (any SpoolInventory)?) {
        self.settings = settings
        self.inventory = inventory
        configuration += 1
        colorNames = nil
        colorNamesProblem = nil
        for index in rows.indices { rows[index].colorName = nil }
        setBambuddy(.unchecked)
    }

    /// The current snapshot, then one per change, until the session goes away.
    public func snapshots() -> AsyncStream<SessionSnapshot> {
        let (stream, continuation) = AsyncStream<SessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    public var snapshot: SessionSnapshot {
        SessionSnapshot(rows: rows, bambuddy: bambuddy, colorNamesProblem: colorNamesProblem)
    }

    public func clear() {
        rows.removeAll()
        publish()
    }

    // MARK: Startup check

    /// Refuses Spoolman mode and keys that cannot read the settings, then
    /// loads the colour map unless it is loaded already. When the settings
    /// change during the check, the new ones are checked instead. A call
    /// while a check is under way waits for that check.
    @discardableResult
    public func checkBambuddy() async -> BambuddyState {
        if let checking { return await checking.value }
        // The task forgets itself in the actor turn that finishes the check,
        // so a call after that turn (new settings, say) checks afresh.
        let task = Task {
            let state = await runCheck()
            checking = nil
            return state
        }
        checking = task
        return await task.value
    }

    private func runCheck() async -> BambuddyState {
        let checking = configuration
        guard let inventory else {
            setBambuddy(.notConfigured)
            return bambuddy
        }
        let state = await Self.check(inventory)
        guard checking == configuration else { return await runCheck() }
        setBambuddy(state)
        if state.isReady, colorNames == nil {
            await loadColorNames(from: inventory, checking: checking)
            guard checking == configuration else { return await runCheck() }
        }
        return state
    }

    /// The startup check alone, without the colour map (the settings' "Test connection").
    static func check(_ inventory: any SpoolInventory) async -> BambuddyState {
        do {
            return try await inventory.spoolmanEnabled() ? .refused(.spoolmanMode) : .ready
        } catch BambuddyError.permissionMissing(let permission) {
            return .refused(.permissionMissing(permission))
        } catch BambuddyError.unauthorized {
            return .refused(.unauthorized)
        } catch {
            return .unreachable(describe(error))
        }
    }

    /// A failed load is reported and leaves new items unnamed; the next
    /// startup check (a settings save) tries again. Every row in the feed is
    /// named again when the map arrives.
    private func loadColorNames(from inventory: any SpoolInventory, checking: Int) async {
        let loaded: Result<ColorMap, any Error>
        do {
            loaded = .success(try await inventory.colorMap())
        } catch {
            loaded = .failure(error)
        }
        guard checking == configuration else { return }
        switch loaded {
        case .success(let map):
            let resolver = ColorNameResolver(map)
            colorNames = resolver
            colorNamesProblem = nil
            for index in rows.indices {
                rows[index].colorName = resolver.name(for: rows[index].tag)
            }
        case .failure(let error):
            colorNamesProblem = "Colour names unavailable: \(Self.describe(error))"
        }
        publish()
    }

    /// Checks when the state may have changed since (never checked, or unreachable).
    private func ensureReady() async -> (any SpoolInventory)? {
        switch bambuddy {
        case .unchecked, .unreachable, .notConfigured: await checkBambuddy()
        case .ready, .refused: break
        }
        return bambuddy.isReady ? inventory : nil
    }

    // MARK: Flipper messages

    /// The reply to a Flipper message: `lookup` for a scan, `result` for an
    /// intent, nothing otherwise (`hello` belongs to the transport session).
    public func handle(_ message: Message) async -> Message? {
        switch message {
        case .scan(let scan): .lookup(await handleScan(scan))
        case .intent(let intent): .result(await handleIntent(intent))
        case .hello, .lookup, .result: nil
        }
    }

    public func handleScan(_ scan: Scan) async -> Lookup {
        await lookup(row: record(scan))
    }

    /// Adds a row for the scan, newest last.
    @discardableResult
    public func record(_ scan: Scan) -> FeedRow.ID {
        var row = FeedRow(scanId: scan.scanId, dump: scan.tag)
        row.colorName = colorNames?.name(for: row.tag)
        rows.append(row)
        publish()
        return row.id
    }

    /// Looks the row's tag up in Bambuddy and builds the Flipper's `lookup`.
    public func lookup(row id: FeedRow.ID) async -> Lookup {
        guard let row = rows.first(where: { $0.id == id }) else {
            return LookupBuilder.error(scanId: "unknown", lines: ["Scan dropped"], error: "row cleared")
        }
        guard let inventory = await ensureReady() else {
            updateRow(id) { $0.status = .error(bambuddy.message ?? "Bambuddy not ready") }
            return LookupBuilder.error(
                scanId: row.scanId, lines: bambuddy.flipperLines, error: bambuddy.message ?? "not ready"
            )
        }
        do {
            let spool = try await IntentHandler(inventory: inventory, settings: settings).find(row.tag)
            updateRow(id) {
                $0.spool = spool
                $0.status = spool == nil ? .unknown(prefill: row.tag.hasPrefill) : .awaitingWeight
            }
            if let spool { return LookupBuilder.found(scanId: row.scanId, spool: spool) }
            return LookupBuilder.unknown(scanId: row.scanId, tag: row.tag, core: settings.coreWeight)
        } catch {
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            let isNetwork = if case BambuddyError.network = error { true } else { false }
            return LookupBuilder.error(
                scanId: row.scanId, lines: [isNetwork ? "Bambuddy unreachable" : "Lookup failed"], error: message
            )
        }
    }

    /// Performs the intent once per `id`: a repeat (also while the first is
    /// still running) gets the same result. Only results that a retry would
    /// not change are remembered; Bambuddy failures may be retried. A repeat
    /// is the same intent again: a restarted Flipper may reuse an id for
    /// another intent, which is performed after the one still running under
    /// that id, so the newer outcome is the one that stays.
    public func handleIntent(_ intent: Intent) async -> IntentResult {
        while true {
            if let cached = results[intent.id], cached.intent == intent { return cached.result }
            guard let running = inFlight[intent.id] else { break }
            if running.intent == intent { return await running.task.value }
            _ = await running.task.value
        }
        let task = Task {
            let result = await self.perform(intent)
            self.settle(intent)
            return result
        }
        inFlight[intent.id] = (intent, task)
        return await task.value
    }

    /// Ends the intent's run before anyone waiting on it resumes.
    private func settle(_ intent: Intent) {
        if inFlight[intent.id]?.intent == intent { inFlight[intent.id] = nil }
    }

    private func perform(_ intent: Intent) async -> IntentResult {
        let id = rowID(for: intent)
        let failed = intent.action == .new ? "Not created" : "Not saved"
        if intent.action == .createOnHost || intent.action == .linkOnHost {
            guard let row = rows.first(where: { $0.id == id }) else { return dropped(intent, failed) }
            return finish(intent, IntentHandler.flag(intent, on: row))
        }
        guard let inventory = await ensureReady() else {
            let message = bambuddy.message ?? "Bambuddy not ready"
            updateRow(id) { $0.status = .error(message) }
            return LookupBuilder.result(id: intent.id, ok: false, lines: [failed] + bambuddy.flipperLines, error: message)
        }
        guard let row = rows.first(where: { $0.id == id }) else { return dropped(intent, failed) }
        do {
            return finish(intent, try await IntentHandler(inventory: inventory, settings: settings).perform(intent, on: row))
        } catch {
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            return LookupBuilder.result(id: intent.id, ok: false, lines: [failed], error: message)
        }
    }

    private func finish(_ intent: Intent, _ outcome: IntentHandler.Outcome) -> IntentResult {
        replaceRow(outcome.row)
        remember(intent, outcome.result)
        return outcome.result
    }

    /// The feed was cleared while the intent waited for Bambuddy.
    private func dropped(_ intent: Intent, _ failed: String) -> IntentResult {
        LookupBuilder.result(id: intent.id, ok: false, lines: [failed], error: "feed cleared; scan again")
    }

    /// The row the intent's scan created, or a new one when the host has none
    /// (restarted, or the feed was cleared).
    private func rowID(for intent: Intent) -> FeedRow.ID {
        let uid = TagParser.parse(intent.tag).uid
        if let row = rows.last(where: { $0.scanId == intent.scanId && $0.tag.uid == uid }) {
            return row.id
        }
        return record(Scan(scanId: intent.scanId, tag: intent.tag))
    }

    private func remember(_ intent: Intent, _ result: IntentResult) {
        // an id reused for another intent counts as the newest
        if results.updateValue((intent, result), forKey: result.id) != nil {
            resultOrder.removeAll { $0 == result.id }
        }
        resultOrder.append(result.id)
        while resultOrder.count > Self.resultCacheSize {
            results[resultOrder.removeFirst()] = nil
        }
    }

    // MARK: Host actions

    /// Saves a weight typed on the host: the same Bambuddy call a Flipper
    /// `weigh` makes, marked as saved by the host.
    public func saveWeight(row id: FeedRow.ID, grams: Int, mode: Intent.WeightMode) async throws {
        guard (0...LookupBuilder.maxGrams).contains(grams) else { throw SessionError.invalidWeight(grams) }
        try await hostAction(id) { handler, row in
            try await handler.weigh(row, grams: grams, mode: mode, by: .host)
        }
    }

    /// Creates the item from the host's New form and links the row to it. A
    /// spool that already carries the tag (the lookup may have failed) is used
    /// instead, so no duplicate is created.
    @discardableResult
    public func createSpool(row id: FeedRow.ID, _ newSpool: NewSpool) async throws -> Spool {
        try await hostAction(id) { handler, row in
            guard let existing = try await handler.find(row.tag) else {
                return try await handler.create(row, newSpool, by: .host)
            }
            var row = row
            row.spool = existing
            row.status = .awaitingWeight
            row.request = nil
            return row
        }
    }

    /// Links the row's tag to an existing spool (the host's picker).
    @discardableResult
    public func link(row id: FeedRow.ID, toSpool spoolId: Int) async throws -> Spool {
        try await hostAction(id) { handler, row in
            try await handler.link(row, toSpool: spoolId)
        }
    }

    /// Every spool in Bambuddy, for the host's link picker.
    public func listSpools() async throws -> [Spool] {
        guard let inventory = await ensureReady() else {
            throw SessionError.notReady(bambuddy.message ?? "Bambuddy not ready")
        }
        return try await inventory.listSpools()
    }

    @discardableResult
    private func hostAction(
        _ id: FeedRow.ID, _ action: (IntentHandler, FeedRow) async throws -> FeedRow
    ) async throws -> Spool {
        guard rows.contains(where: { $0.id == id }) else { throw SessionError.rowNotFound }
        guard let inventory = await ensureReady() else {
            throw SessionError.notReady(bambuddy.message ?? "Bambuddy not ready")
        }
        guard let row = rows.first(where: { $0.id == id }) else { throw SessionError.rowNotFound }
        do {
            let updated = try await action(IntentHandler(inventory: inventory, settings: settings), row)
            replaceRow(updated)
            // Every host action ends with the row carrying a spool.
            guard let spool = updated.spool else { throw SessionError.spoolNotFound(row.tag.uid) }
            return spool
        } catch {
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            throw error
        }
    }

    // MARK: Plumbing

    private func updateRow(_ id: FeedRow.ID, _ change: (inout FeedRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        publish()
    }

    /// Writes back a row changed across an await; a cleared row stays cleared.
    private func replaceRow(_ row: FeedRow) {
        updateRow(row.id) { $0 = row }
    }

    private func setBambuddy(_ state: BambuddyState) {
        guard state != bambuddy else { return }
        bambuddy = state
        publish()
    }

    private func publish() {
        let current = snapshot
        for observer in observers.values { observer.yield(current) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
