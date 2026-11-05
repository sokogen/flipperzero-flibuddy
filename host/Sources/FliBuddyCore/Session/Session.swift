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

    /// The case's name, for the log.
    var name: String {
        switch self {
        case .unchecked: "unchecked"
        case .notConfigured: "notConfigured"
        case .ready: "ready"
        case .refused: "refused"
        case .unreachable: "unreachable"
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
    /// The settings changed while a host action ran; its write was not sent.
    case settingsChanged
    /// The Link picker's spools are from older settings, perhaps another Bambuddy.
    case staleSpoolList
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
        case .settingsChanged: "The Bambuddy settings changed; try again"
        case .staleSpoolList: "The spool list is from older Bambuddy settings; pick the spool again"
        }
    }
}

/// Bambuddy's spools for the Link picker and the settings they were listed
/// under: Link refuses a spool picked from a list of older settings.
public struct SpoolListing: Equatable, Sendable {
    public var spools: [Spool]
    let configuration: Int
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
    /// The feed keeps this many rows; a scan beyond it drops the oldest.
    public static let maxRows = 200

    public private(set) var rows: [FeedRow] = []
    public private(set) var bambuddy: BambuddyState = .unchecked
    public private(set) var settings: Settings
    /// Set when the colour map failed to load; new items then carry no colour name.
    public private(set) var colorNamesProblem: String?

    private var inventory: (any SpoolInventory)?
    /// Bumped by `reconfigure`; a check of older settings does not count.
    private var configuration = 0
    /// Rows whose spool came from older settings, perhaps another Bambuddy:
    /// shown as they are, looked up again by tag before the next write.
    private var staleSpools: Set<FeedRow.ID> = []
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
    private var pushObservers: [UUID: AsyncStream<Message>.Continuation] = [:]
    private let now: @Sendable () -> Date

    public init(settings: Settings, inventory: (any SpoolInventory)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.inventory = inventory
        self.now = now
    }

    deinit {
        for observer in observers.values { observer.finish() }
        for observer in pushObservers.values { observer.finish() }
    }

    /// New settings (and the client built from them); the next scan checks
    /// again. The rows' spools may belong to the old Bambuddy: the next write
    /// looks each up again by tag, and Link no longer deletes spools created
    /// on scan.
    public func reconfigure(settings: Settings, inventory: (any SpoolInventory)?) {
        self.settings = settings
        self.inventory = inventory
        configuration += 1
        colorNames = nil
        colorNamesProblem = nil
        for index in rows.indices {
            rows[index].colorName = nil
            rows[index].createdSpoolId = nil
            if rows[index].spool != nil { staleSpools.insert(rows[index].id) }
        }
        setBambuddy(.unchecked)
    }

    /// Settings that keep the Bambuddy URL and key (weight mode, core
    /// weight, catalog entry, transport): the next action uses them, and the
    /// rows, the startup check and the colour map stay as they are.
    public func update(settings: Settings) {
        self.settings = settings
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

    /// Lines the host sends the Flipper by itself, from the call on, until the
    /// session goes away: a fresh `lookup` after the owner creates the spool
    /// or links the tag on the host (PROTOCOL.md, Session). Nothing is
    /// buffered for a Flipper that is not connected.
    public func pushes() -> AsyncStream<Message> {
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        pushObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePushObserver(id) }
        }
        return stream
    }

    public var snapshot: SessionSnapshot {
        SessionSnapshot(
            rows: rows, bambuddy: bambuddy, colorNamesProblem: colorNamesProblem, isCheckingBambuddy: checking != nil
        )
    }

    public func clear() {
        rows.removeAll()
        staleSpools.removeAll()
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
            return try await state(spoolmanEnabled: inventory.spoolmanEnabled())
        } catch {
            return state(after: error)
        }
    }

    /// The startup check's answer when Bambuddy said whether it is in Spoolman mode.
    static func state(spoolmanEnabled: Bool) -> BambuddyState {
        spoolmanEnabled ? .refused(.spoolmanMode) : .ready
    }

    /// The startup check's answer when asking Bambuddy failed.
    static func state(after error: any Error) -> BambuddyState {
        switch error {
        case BambuddyError.permissionMissing(let permission): .refused(.permissionMissing(permission))
        case BambuddyError.unauthorized: .refused(.unauthorized)
        default: .unreachable(describe(error))
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
            Log.error(.session, "colour names failed: error=\(Self.describe(error))")
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
        Log.info(.session, Self.describe(scan))
        return await lookup(row: record(scan))
    }

    /// `scan: id=… uid=… tray=… kind=mfc|ntag material=…`.
    private static func describe(_ scan: Scan) -> String {
        let tag = TagParser.parse(scan.tag)
        return "scan: id=\(scan.scanId) uid=\(tag.uid) tray=\(tag.trayUuid ?? "none") "
            + "kind=\(scan.tag.type.rawValue) material=\(tag.material ?? "none") autosave=\(scan.autosave)"
    }

    /// Adds a row for the scan, newest last. A tag already in the feed (same
    /// tray UUID or UID) moves its row to the end and starts it over, so the
    /// feed never holds the same tag twice. The row keeps the scan's autosave.
    /// Beyond `maxRows` the oldest rows go, as Clear would drop them.
    @discardableResult
    public func record(_ scan: Scan) -> FeedRow.ID {
        var row = FeedRow(scanId: scan.scanId, scannedAt: now(), autosave: scan.autosave, dump: scan.tag)
        if let index = rows.lastIndex(where: { Self.sameTag($0.tag, row.tag) }) {
            var known = rows.remove(at: index)
            known.scanId = row.scanId
            known.scannedAt = row.scannedAt
            known.autosave = row.autosave
            known.dump = row.dump
            known.tag = row.tag
            known.status = .scanned
            known.request = nil
            // The rescan makes a known spool of it: no stand-in Link may delete.
            known.createdSpoolId = nil
            row = known
        }
        row.colorName = colorNames?.name(for: row.tag) ?? row.tag.bambuColor?.name
        rows.append(row)
        if rows.count > Self.maxRows {
            for dropped in rows.prefix(rows.count - Self.maxRows) { staleSpools.remove(dropped.id) }
            rows.removeFirst(rows.count - Self.maxRows)
        }
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
        let started = now()
        let (lookup, outcome) = await find(row: id)
        let ms = Int((now().timeIntervalSince(started) * 1000).rounded())
        switch outcome {
        case .found(let spool): Log.info(.session, "lookup: id=\(lookup.scanId) status=found spool=\(spool) ms=\(ms)")
        case .created(let spool):
            Log.info(.session, "lookup: id=\(lookup.scanId) status=created spool=\(spool) ms=\(ms)")
        case .notFound: Log.info(.session, "lookup: id=\(lookup.scanId) status=not_found ms=\(ms)")
        case .failed(let error): Log.error(.session, "lookup: id=\(lookup.scanId) status=error ms=\(ms) error=\(error)")
        }
        return lookup
    }

    /// What a lookup came to, for the log.
    private enum LookupOutcome {
        case found(Int)
        case created(Int)
        case notFound
        case failed(String)
    }

    private func find(row id: FeedRow.ID) async -> (Lookup, LookupOutcome) {
        guard let row = rows.first(where: { $0.id == id }) else {
            return (LookupBuilder.error(scanId: "unknown", lines: ["Scan dropped"], error: "row cleared"), .failed("row cleared"))
        }
        guard let inventory = await ensureReady() else {
            let message = bambuddy.message ?? "Bambuddy not ready"
            updateRow(id) { $0.status = .error(message) }
            return (
                LookupBuilder.error(scanId: row.scanId, lines: bambuddy.flipperLines, error: bambuddy.message ?? "not ready"),
                .failed(message)
            )
        }
        let handler = IntentHandler(inventory: inventory, settings: settings)
        let started = configuration
        let found: Result<Spool?, any Error>
        do {
            found = .success(try await handler.find(row.tag))
        } catch {
            found = .failure(error)
        }
        // The answer of a Bambuddy the settings have since left counts for
        // nothing, least of all as a reason to create a spool there.
        guard started == configuration else { return await find(row: id) }
        do {
            let spool = try found.get()
            // A tag about to be created on scan stays Looking up until the
            // create returns, rather than offering New and Link meanwhile.
            let createsOnScan = spool == nil && newSpoolOnScan(id, handler) != nil
            updateRow(id) {
                $0.spool = spool
                if spool != nil {
                    $0.status = .awaitingWeight
                } else if !createsOnScan {
                    $0.status = .unknown(prefill: row.tag.hasPrefill)
                }
            }
            staleSpools.remove(id)
            if let spool { return (LookupBuilder.found(scanId: row.scanId, spool: spool), .found(spool.id)) }
            if let created = await createOnScan(id, handler, startedUnder: started) {
                return (LookupBuilder.found(scanId: row.scanId, spool: created, created: true), .created(created.id))
            }
            return (
                LookupBuilder.unknown(
                    scanId: row.scanId, tag: row.tag, core: settings.coreWeight,
                    colorName: row.colorName
                ), .notFound
            )
        } catch {
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            let isNetwork = if case BambuddyError.network = error { true } else { false }
            let lookup = LookupBuilder.error(
                scanId: row.scanId, lines: [isNetwork ? "Bambuddy unreachable" : "Lookup failed"], error: message
            )
            return (lookup, .failed(message))
        }
    }

    /// With the scan's autosave on, a tag with material that no spool carries
    /// is created at once with the defaults (the New form's values); the row
    /// then waits for a weight. A failed create marks the row and leaves New
    /// as the retry; the Flipper gets `unknown` and keeps its own Add.
    private func createOnScan(_ id: FeedRow.ID, _ handler: IntentHandler, startedUnder started: Int) async -> Spool? {
        guard let newSpool = newSpoolOnScan(id, handler) else { return nil }
        let scanId = scanId(of: id)
        do {
            let created = try await handler.inventory.createSpool(newSpool)
            updateRow(id) { IntentHandler.markCreated(&$0, created, by: .host) }
            settleSpool(id, startedUnder: started)
            Log.info(.session, "create on scan: id=\(scanId) spool=\(created.id)")
            return created
        } catch {
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            Log.error(.session, "create on scan failed: id=\(scanId) error=\(message)")
            return nil
        }
    }

    /// The spool a scan creates for the row's tag: the New form's defaults;
    /// nil when the scan's autosave is off or the tag has no material.
    private func newSpoolOnScan(_ id: FeedRow.ID, _ handler: IntentHandler) -> NewSpool? {
        guard let row = rows.first(where: { $0.id == id }), row.autosave else { return nil }
        return handler.newSpool(for: row)
    }

    /// Performs the intent once per `id`: a repeat (also while the first is
    /// still running) gets the same result. Only results that a retry would
    /// not change are remembered; Bambuddy failures may be retried. A repeat
    /// is the same intent again: a restarted Flipper may reuse an id for
    /// another intent, which is performed after the one still running under
    /// that id, so the newer outcome is the one that stays.
    public func handleIntent(_ intent: Intent) async -> IntentResult {
        Log.info(.session, describe(intent))
        let result = await resolve(intent)
        if result.ok {
            Log.info(.session, "result: id=\(result.id) ok")
        } else {
            Log.error(.session, "result: id=\(result.id) error=\(result.error ?? result.lines.joined(separator: " / "))")
        }
        return result
    }

    /// `intent: id=… action=… spool=… grams=… mode=…`; the spool is the one
    /// the host knows for the tag, if any.
    private func describe(_ intent: Intent) -> String {
        let tag = TagParser.parse(intent.tag)
        let row = rows.last(where: { $0.scanId == intent.scanId && $0.tag.uid == tag.uid })
            ?? rows.last(where: { Self.sameTag($0.tag, tag) })
        var text = "intent: id=\(intent.id) action=\(intent.action.rawValue) spool=\(row?.spool.map { "\($0.id)" } ?? "none")"
        if let grams = intent.grams { text += " grams=\(grams)" }
        if let mode = intent.mode { text += " mode=\(mode.rawValue)" }
        return text
    }

    private func resolve(_ intent: Intent) async -> IntentResult {
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
        let failed = IntentHandler.failureLine(intent.action)
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
        switch intent.action {
        case .weigh: updateRow(id) { $0.status = .saving }
        case .full, .empty, .delete: updateRow(id) { $0.status = .updating }
        case .new, .createOnHost, .linkOnHost: break
        }
        let started = configuration
        let guarded = configured(inventory, under: started)
        do {
            var outcome = try await IntentHandler(inventory: guarded, settings: settings).perform(intent, on: forWrite(row))
            if outlived(guarded, startedUnder: started) { return await perform(intent, arrived: arrived) }
            if intent.action == .weigh, outcome.result.ok,
               now().timeIntervalSince(arrived) > Self.flipperResultTimeout {
                // The Flipper has shown an error by now; the host finished the save.
                outcome.row.status = .savedAfterTimeout
                outcome.row.savedBy = .host
            }
            return finish(intent, outcome, startedUnder: started)
        } catch {
            // the Flipper waits for the result: perform the intent on the new settings
            if outlived(guarded, startedUnder: started) { return await perform(intent, arrived: arrived) }
            let message = Self.describe(error)
            updateRow(id) { $0.status = .error(message) }
            return LookupBuilder.result(id: intent.id, ok: false, lines: [failed], error: message)
        }
    }

    /// `started`: the configuration a Bambuddy call ran under; `nil` when none was made.
    private func finish(_ intent: Intent, _ outcome: IntentHandler.Outcome, startedUnder started: Int? = nil) -> IntentResult {
        replaceRow(outcome.row)
        if let started { settleSpool(outcome.row.id, startedUnder: started) }
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
        return record(Scan(scanId: intent.scanId, autosave: false, tag: intent.tag))
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

    /// Saves a weight typed on the host: the same Bambuddy calls a Flipper
    /// `weigh` makes, marked as saved by the host. On a tag no spool carries
    /// it creates the spool from the tag first.
    /// A row that had no spool (the save created it) pushes a fresh `lookup`.
    public func saveWeight(row id: FeedRow.ID, grams: Int, mode: Intent.WeightMode) async throws {
        guard (0...LookupBuilder.maxGrams).contains(grams) else { throw SessionError.invalidWeight(grams) }
        let hadSpool = rows.first { $0.id == id }?.spool != nil
        try await hostAction(id, status: .saving) { handler, row in
            try await handler.weigh(row, grams: grams, mode: mode, by: .host)
        }
        if !hadSpool { pushLookup(row: id) }
    }

    /// Creates the item from the host's New form and links the row to it. A
    /// spool that already carries the tag (the lookup may have failed) is used
    /// instead, so no duplicate is created.
    @discardableResult
    public func createSpool(row id: FeedRow.ID, _ newSpool: NewSpool) async throws -> Spool {
        let scanId = scanId(of: id)
        do {
            let spool = try await hostAction(id) { handler, row in
                guard let existing = try await handler.find(row.tag) else {
                    return try await handler.create(row, newSpool, by: .host)
                }
                var row = row
                row.spool = existing
                row.status = .awaitingWeight
                row.request = nil
                return row
            }
            Log.info(.session, "create: id=\(scanId) spool=\(spool.id)")
            pushLookup(row: id)
            return spool
        } catch {
            Log.error(.session, "create failed: id=\(scanId) error=\(Self.describe(error))")
            throw error
        }
    }

    /// Links the row's tag to an existing spool (the host's picker). A spool
    /// this session created for the tag is deleted first: Bambuddy refuses a
    /// tag another active spool carries. When the delete fails nothing
    /// changes; when the link fails after it, the row is left without a spool,
    /// so New and Link are offered again.
    /// `listing` is the picker's list the spool was chosen from: a list from
    /// older settings is refused, as its ids may name other spools now.
    @discardableResult
    public func link(row id: FeedRow.ID, toSpool spoolId: Int, from listing: SpoolListing) async throws -> Spool {
        let scanId = scanId(of: id)
        guard listing.configuration == configuration else {
            Log.error(.session, "link failed: id=\(scanId) spool=\(spoolId) error=\(Self.describe(SessionError.staleSpoolList))")
            throw SessionError.staleSpoolList
        }
        if let row = rows.first(where: { $0.id == id }), let created = row.createdSpoolId,
           created == row.spool?.id, created != spoolId {
            do {
                try await hostUpdate(id, under: listing.configuration) { handler, row in
                    try await handler.deleteCreated(row)
                }
                Log.info(.session, "delete: id=\(scanId) spool=\(created)")
            } catch {
                Log.error(.session, "delete failed: id=\(scanId) spool=\(created) error=\(Self.describe(error))")
                throw error
            }
        }
        do {
            let spool = try await hostAction(id, under: listing.configuration) { handler, row in
                try await handler.link(row, toSpool: spoolId)
            }
            Log.info(.session, "link: id=\(scanId) spool=\(spool.id)")
            pushLookup(row: id)
            return spool
        } catch {
            Log.error(.session, "link failed: id=\(scanId) spool=\(spoolId) error=\(Self.describe(error))")
            throw error
        }
    }

    /// Takes a saved, marked or added row back to weight entry for a
    /// (re-)weigh.
    public func reopen(row id: FeedRow.ID) {
        updateRow(id) {
            if $0.status.isReopenable, $0.spool != nil { $0.status = .awaitingWeight }
        }
    }

    /// Every spool in Bambuddy, for the host's link picker.
    public func listSpools() async throws -> SpoolListing {
        guard let inventory = await ensureReady() else {
            throw SessionError.notReady(bambuddy.message ?? "Bambuddy not ready")
        }
        let started = configuration
        return SpoolListing(spools: try await inventory.listSpools(), configuration: started)
    }

    /// A host action that ends with the row carrying a spool.
    @discardableResult
    private func hostAction(
        _ id: FeedRow.ID, under listed: Int? = nil, status: FeedRow.Status? = nil,
        _ action: (IntentHandler, FeedRow) async throws -> FeedRow
    ) async throws -> Spool {
        let updated = try await hostUpdate(id, under: listed, status: status, action)
        guard let spool = updated.spool else {
            let error = SessionError.spoolNotFound(updated.tag.uid)
            updateRow(id) { $0.status = .error(Self.describe(error)) }
            throw error
        }
        return spool
    }

    /// Runs a host action against a ready Bambuddy and writes the row back;
    /// `status` shows while it runs. A failure marks the row and is rethrown.
    /// `listed`: the configuration the action's input came from, when not the
    /// current one; its writes are refused once the settings change.
    @discardableResult
    private func hostUpdate(
        _ id: FeedRow.ID, under listed: Int? = nil, status: FeedRow.Status? = nil,
        _ action: (IntentHandler, FeedRow) async throws -> FeedRow
    ) async throws -> FeedRow {
        guard rows.contains(where: { $0.id == id }) else { throw SessionError.rowNotFound }
        guard let inventory = await ensureReady() else {
            throw SessionError.notReady(bambuddy.message ?? "Bambuddy not ready")
        }
        guard let row = rows.first(where: { $0.id == id }) else { throw SessionError.rowNotFound }
        let started = listed ?? configuration
        guard started == configuration else { throw SessionError.staleSpoolList }
        if let status { updateRow(id) { $0.status = status } }
        let guarded = configured(inventory, under: started)
        do {
            let updated = try await action(IntentHandler(inventory: guarded, settings: settings), forWrite(row))
            if outlived(guarded, startedUnder: started) { throw SessionError.settingsChanged }
            replaceRow(updated)
            settleSpool(id, startedUnder: started)
            return rows.first { $0.id == id } ?? updated
        } catch {
            let error = outlived(guarded, startedUnder: started) ? SessionError.settingsChanged : error
            let message = Self.describe(error)
            updateRow(id) {
                $0.status = .error(message)
                // No spool carries the tag (any spool the row knew is gone).
                if case SessionError.spoolNotFound = error {
                    $0.spool = nil
                    $0.createdSpoolId = nil
                }
            }
            throw error
        }
    }

    // MARK: Plumbing

    /// Sends the Flipper a fresh `found` lookup for the row's latest scan; the
    /// Flipper applies it only while that scan is on its screen. `created` is
    /// left out: it marks a spool created on scan.
    private func pushLookup(row id: FeedRow.ID) {
        guard let row = rows.first(where: { $0.id == id }), let spool = row.spool else { return }
        let lookup = LookupBuilder.found(scanId: row.scanId, spool: spool)
        Log.info(.session, "push lookup: id=\(row.scanId) spool=\(spool.id)")
        for observer in pushObservers.values { observer.yield(.lookup(lookup)) }
    }

    /// The inventory for an action under `started`: its writes are refused
    /// once the settings leave `started`.
    private func configured(_ inventory: any SpoolInventory, under started: Int) -> ConfiguredInventory {
        ConfiguredInventory(base: inventory) { await self.isCurrent(started) }
    }

    /// Checked on the actor once the action ends: when the settings left
    /// `started` and no write was begun, what the action read speaks for a
    /// Bambuddy they have left, so it counts for nothing. A write begun there
    /// counts, its spool stale.
    private func outlived(_ guarded: ConfiguredInventory, startedUnder started: Int) -> Bool {
        started != configuration && !guarded.writeBegan
    }

    private func isCurrent(_ started: Int) -> Bool {
        started == configuration
    }

    private func updateRow(_ id: FeedRow.ID, _ change: (inout FeedRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        publish()
    }

    /// Writes back a row changed across an await; a cleared row stays cleared.
    private func replaceRow(_ row: FeedRow) {
        updateRow(row.id) { $0 = row }
    }

    /// The row as a Bambuddy write sees it: a spool from older settings is
    /// left out, so the write looks the tag up again.
    private func forWrite(_ row: FeedRow) -> FeedRow {
        guard staleSpools.contains(row.id) else { return row }
        var row = row
        row.spool = nil
        return row
    }

    /// After a Bambuddy call that ran under `started` set the row's spool:
    /// under the current settings the spool is current; under older ones it
    /// is stale, and a spool created then is not one Link may delete.
    private func settleSpool(_ id: FeedRow.ID, startedUnder started: Int) {
        guard started != configuration else {
            staleSpools.remove(id)
            return
        }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].spool != nil { staleSpools.insert(id) }
        if rows[index].createdSpoolId != nil {
            rows[index].createdSpoolId = nil
            publish()
        }
    }

    private func setBambuddy(_ state: BambuddyState) {
        guard state != bambuddy else { return }
        bambuddy = state
        let line = "bambuddy: \(state.name)" + (state.message.map { " message=\($0)" } ?? "")
        switch state {
        case .unchecked, .ready: Log.info(.session, line)
        case .notConfigured: Log.notice(.session, line)
        case .refused, .unreachable: Log.error(.session, line)
        }
        publish()
    }

    /// The row's scan id for the log; `unknown` once the row is gone.
    private func scanId(of id: FeedRow.ID) -> String {
        rows.first { $0.id == id }?.scanId ?? "unknown"
    }

    private func publish() {
        let current = snapshot
        for observer in observers.values { observer.yield(current) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func removePushObserver(_ id: UUID) {
        pushObservers[id] = nil
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
