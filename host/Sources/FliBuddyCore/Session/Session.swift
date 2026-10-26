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
    /// Linking moves the tag off the spool created on scan, which could not be deleted.
    case createdSpoolKept(spoolId: Int, reason: String)
}

extension SessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rowNotFound: "The feed row is gone"
        case .spoolNotFound(let uid): "No spool in Bambuddy carries tag \(uid)"
        case .invalidWeight(let grams): "Weight must be 0 to 9999 g, not \(grams)"
        case .notReady(let message): message
        case .createdSpoolKept(let id, let reason):
            "Spool \(id) created on scan could not be deleted, so the tag stays on it: \(reason)"
        }
    }
}

/// What the views render: the feed in arrival order, the Bambuddy state,
/// whether a startup check is under way and why colour names are missing, if
/// they are.
public struct SessionSnapshot: Equatable, Sendable {
    public var rows: [FeedRow]
    public var bambuddy: BambuddyState
    public var colorNamesProblem: String?
    public var isCheckingBambuddy: Bool

    public init(
        rows: [FeedRow], bambuddy: BambuddyState, colorNamesProblem: String? = nil, isCheckingBambuddy: Bool = false
    ) {
        self.rows = rows
        self.bambuddy = bambuddy
        self.colorNamesProblem = colorNamesProblem
        self.isCheckingBambuddy = isCheckingBambuddy
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
    /// How long the Flipper waits for a `result` before it shows an error
    /// (`APP_RESULT_TIMEOUT_MS`). The host measures its own latency against it,
    /// so a weigh it saved later counts as `savedAfterTimeout`.
    public static let flipperResultTimeout: TimeInterval = 10

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
    private let now: @Sendable () -> Date

    public init(settings: Settings, inventory: (any SpoolInventory)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.inventory = inventory
        self.now = now
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
        SessionSnapshot(
            rows: rows, bambuddy: bambuddy, colorNamesProblem: colorNamesProblem, isCheckingBambuddy: checking != nil
        )
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
            publish()
            return state
        }
        checking = task
        publish()
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

    /// Adds a row for the scan, newest last. A tag already in the feed (same
    /// tray UUID or UID) moves its row to the end and starts it over, so the
    /// feed never holds the same tag twice.
    @discardableResult
    public func record(_ scan: Scan) -> FeedRow.ID {
        var row = FeedRow(scanId: scan.scanId, scannedAt: now(), dump: scan.tag)
        if let index = rows.lastIndex(where: { Self.sameTag($0.tag, row.tag) }) {
            var known = rows.remove(at: index)
            known.scanId = row.scanId
            known.scannedAt = row.scannedAt
            known.dump = row.dump
            known.tag = row.tag
            known.status = .scanned
            known.request = nil
            row = known
        }
        row.colorName = colorNames?.name(for: row.tag)
        rows.append(row)
        publish()
        return row.id
    }

    /// Two scans of one tag, or of the two tags of one Bambu spool.
    static func sameTag(_ a: ParsedTag, _ b: ParsedTag) -> Bool {
        if let tray = a.trayUuid, tray == b.trayUuid { return true }
        return a.kind == b.kind && a.uid.uppercased() == b.uid.uppercased()
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
        let handler = IntentHandler(inventory: inventory, settings: settings)
        do {
            let spool = try await handler.find(row.tag)
            updateRow(id) {
                $0.spool = spool
                $0.status = spool == nil ? .unknown(prefill: row.tag.hasPrefill) : .awaitingWeight
            }
            if let spool { return LookupBuilder.found(scanId: row.scanId, spool: spool) }
            if let created = await createOnScan(id, handler) {
                return LookupBuilder.found(scanId: row.scanId, spool: created)
            }
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

    /// A tag with material that no spool carries is created at once with the
    /// defaults (the New form's values); the row then waits for a weight. A
    /// failed create marks the row and leaves New as the retry; the Flipper
    /// gets `unknown` and keeps its own New.
    private func createOnScan(_ id: FeedRow.ID, _ handler: IntentHandler) async -> Spool? {
        guard let row = rows.first(where: { $0.id == id }),
              let newSpool = NewSpool(
                  tag: row.tag, coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId,
                  colorName: row.colorName
              )
        else { return nil }
        do {
            let created = try await handler.inventory.createSpool(newSpool)
            updateRow(id) { IntentHandler.markCreated(&$0, created, by: .host) }
            return created
        } catch {
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            return nil
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
        let arrived = now()
        let task = Task {
            let result = await self.perform(intent, arrived: arrived)
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

    private func perform(_ intent: Intent, arrived: Date) async -> IntentResult {
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
        if intent.action == .weigh { updateRow(id) { $0.status = .saving } }
        do {
            var outcome = try await IntentHandler(inventory: inventory, settings: settings).perform(intent, on: row)
            if intent.action == .weigh, outcome.result.ok,
               now().timeIntervalSince(arrived) > Self.flipperResultTimeout {
                // The Flipper has shown an error by now; the host finished the save.
                outcome.row.status = .savedAfterTimeout
                outcome.row.savedBy = .host
            }
            return finish(intent, outcome)
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

    /// The row the intent's scan created, else the row of the same tag (it was
    /// scanned again since), or a new one when the host has none (restarted,
    /// or the feed was cleared).
    private func rowID(for intent: Intent) -> FeedRow.ID {
        let tag = TagParser.parse(intent.tag)
        if let row = rows.last(where: { $0.scanId == intent.scanId && $0.tag.uid == tag.uid })
            ?? rows.last(where: { Self.sameTag($0.tag, tag) }) {
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
        try await hostAction(id, status: .saving) { handler, row in
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

    /// Links the row's tag to an existing spool (the host's picker). A spool
    /// this session created for the tag is deleted first: Bambuddy refuses a
    /// tag another active spool carries. When the delete fails nothing
    /// changes; when the link fails after it, the row is left without a spool,
    /// so New and Link are offered again.
    @discardableResult
    public func link(row id: FeedRow.ID, toSpool spoolId: Int) async throws -> Spool {
        if let row = rows.first(where: { $0.id == id }), let created = row.createdSpoolId,
           created == row.spool?.id, created != spoolId {
            try await hostUpdate(id) { handler, row in
                try await handler.deleteCreated(row)
            }
        }
        return try await hostAction(id) { handler, row in
            try await handler.link(row, toSpool: spoolId)
        }
    }

    /// Takes a saved row back to weight entry for a re-weigh.
    public func reopen(row id: FeedRow.ID) {
        updateRow(id) {
            if $0.status == .saved || $0.status == .savedAfterTimeout, $0.spool != nil { $0.status = .awaitingWeight }
        }
    }

    /// Every spool in Bambuddy, for the host's link picker.
    public func listSpools() async throws -> [Spool] {
        guard let inventory = await ensureReady() else {
            throw SessionError.notReady(bambuddy.message ?? "Bambuddy not ready")
        }
        return try await inventory.listSpools()
    }

    /// A host action that ends with the row carrying a spool.
    @discardableResult
    private func hostAction(
        _ id: FeedRow.ID, status: FeedRow.Status? = nil, _ action: (IntentHandler, FeedRow) async throws -> FeedRow
    ) async throws -> Spool {
        let updated = try await hostUpdate(id, status: status, action)
        guard let spool = updated.spool else {
            let error = SessionError.spoolNotFound(updated.tag.uid)
            updateRow(id) { $0.status = .error(Self.describe(error)) }
            throw error
        }
        return spool
    }

    /// Runs a host action against a ready Bambuddy and writes the row back;
    /// `status` shows while it runs. A failure marks the row and is rethrown.
    @discardableResult
    private func hostUpdate(
        _ id: FeedRow.ID, status: FeedRow.Status? = nil, _ action: (IntentHandler, FeedRow) async throws -> FeedRow
    ) async throws -> FeedRow {
        guard rows.contains(where: { $0.id == id }) else { throw SessionError.rowNotFound }
        guard let inventory = await ensureReady() else {
            throw SessionError.notReady(bambuddy.message ?? "Bambuddy not ready")
        }
        guard let row = rows.first(where: { $0.id == id }) else { throw SessionError.rowNotFound }
        if let status { updateRow(id) { $0.status = status } }
        do {
            let updated = try await action(IntentHandler(inventory: inventory, settings: settings), row)
            replaceRow(updated)
            return updated
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
