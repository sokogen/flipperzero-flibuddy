import Foundation
import Observation

/// Reads one QR code, e.g. with the camera; throws `CancellationError` when
/// the user gives up.
@MainActor
public protocol QRScanning {
    func scan() async throws -> String
}

/// The Settings screen: an editable copy of the settings, the catalog entry
/// picker, the transport settings (USB port, Bluetooth Flipper scan) and the
/// connection test. `save()` hands the draft to `apply`, which stores it and
/// reconfigures the session; `revert()` goes back to what was saved.
///
/// With `appliesOnChange` (iPhone, iPad) there is no Save: a picker change,
/// a chosen or forgotten Flipper and a read QR code apply at once, the text
/// fields (URL, API key, core weight) on `commit()`. Each change applies on
/// top of the settings applied last, in order, so a field still being typed
/// is left out of a picker's change.
@MainActor
@Observable
public final class SettingsViewModel {
    /// The last Test connection.
    public enum Connection: Equatable, Sendable {
        case testing
        /// Internal inventory with the permissions FliBuddy needs.
        case ready
        /// No answer, with the reason ("no answer within 5 s").
        case unreachable(String)
        /// Bambuddy answered no (Spoolman mode, the API key), or the settings
        /// cannot make a client.
        case failed(String)
    }

    /// The outcome of the last Bambuddy QR code.
    public enum QRStatus: Equatable, Sendable {
        case applied(String)
        case failed(String)
    }

    /// Editing the URL or the API key drops the test result, which was about the old ones.
    public var baseURL: String {
        didSet { if baseURL != oldValue { endpointEdited() } }
    }
    public var apiKey: String {
        didSet { if apiKey != oldValue { endpointEdited() } }
    }
    /// Picks the entry from `catalog`; choosing a different entry copies its
    /// weight into `coreWeight` once.
    public var catalogEntryId: Int? {
        didSet {
            guard catalogEntryId != oldValue else { return }
            let id = catalogEntryId
            guard let entry = catalog.first(where: { $0.id == id }) else {
                return applyChange { $0.catalogEntryId = id }
            }
            coreWeight = entry.weight
            applyChange {
                $0.catalogEntryId = id
                $0.coreWeight = entry.weight
            }
        }
    }
    /// Grams; editable, saved as is.
    public var coreWeight: Int

    /// The iPhone's core weight field: digits only, at most four, written
    /// to `coreWeight` as typed so a commit on focus loss sees the number;
    /// an empty field is 0 (out of range, so it is not applied) and stays
    /// empty while it is edited.
    public var coreWeightText: String {
        get { coreWeightIsBlank && coreWeight == 0 ? "" : String(coreWeight) }
        set {
            let grams = FeedViewModel.grams(from: newValue)
            coreWeightIsBlank = grams == nil
            coreWeight = grams ?? 0
        }
    }
    private var coreWeightIsBlank = false
    public var defaultMode: Intent.WeightMode {
        didSet {
            guard defaultMode != oldValue else { return }
            applyChange { [defaultMode] in $0.defaultMode = defaultMode }
        }
    }
    public var transport: TransportKind {
        didSet {
            guard transport != oldValue else { return }
            applyChange { [transport] in $0.transport = transport }
        }
    }
    /// `nil` uses the first Flipper found.
    public var port: String? {
        didSet {
            guard port != oldValue else { return }
            applyChange { [port] in $0.port = port }
        }
    }
    /// The chosen Bluetooth Flipper; `nil` uses the first one found.
    public private(set) var peripheralId: UUID?
    public private(set) var peripheralName: String?

    public private(set) var catalog: [CatalogEntry] = []
    public private(set) var catalogError: String?
    public private(set) var ports: [String] = []
    /// Flippers found by the running or last scan, each once.
    public private(set) var discovered: [DiscoveredPeripheral] = []
    public private(set) var isScanning = false
    /// Why the last scan could not run (Bluetooth off or not allowed).
    public private(set) var scanProblem: String?
    public private(set) var connection: Connection?
    public private(set) var saveError: String?
    public private(set) var qrStatus: QRStatus?

    /// Changes apply as they are made; there is no Save.
    public let appliesOnChange: Bool

    private var saved: Settings
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    private let discoverFlippers: @MainActor () -> AsyncStream<DiscoveredPeripheral>
    private let bluetoothPower: @MainActor () async -> BLEPowerState
    private let scanDuration: Duration
    private let connectedTransport: @MainActor () -> TransportKind?
    private let apply: @MainActor (Settings) async throws -> Void
    /// The last applied change; each one waits for the one before it.
    private var applying: Task<Void, Never>?
    /// Set while one edit sets several fields that apply as one change.
    private var holdsApply = false
    private var scanTask: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?
    /// Bumped by every scan start and stop; a stale scan changes nothing.
    private var scanGeneration = 0
    /// Bumped by every edit of the URL or the API key; a test of older ones changes nothing.
    private var endpointGeneration = 0
    /// Bumped by every catalog load; only the latest one sets `catalog` and `catalogError`.
    private var catalogLoads = 0

    /// `discoverFlippers` streams Flippers advertising over Bluetooth; a scan
    /// stops by itself after `scanDuration`, or at once when `bluetoothPower`
    /// says the radio cannot be used. `connectedTransport` is how the Flipper
    /// is connected now, `nil` when it is not.
    public init(
        settings: Settings,
        makeInventory: @escaping @Sendable (Settings) throws -> any SpoolInventory = { try $0.makeClient() },
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() },
        discoverFlippers: @escaping @MainActor () -> AsyncStream<DiscoveredPeripheral> = { FlipperLink.defaultScan() },
        bluetoothPower: @escaping @MainActor () async -> BLEPowerState = { await FlipperLink.defaultPowerState() },
        scanDuration: Duration = .seconds(15),
        connectedTransport: @escaping @MainActor () -> TransportKind? = { nil },
        appliesOnChange: Bool = false,
        apply: @escaping @MainActor (Settings) async throws -> Void
    ) {
        saved = settings
        baseURL = settings.baseURL
        apiKey = settings.apiKey
        catalogEntryId = settings.catalogEntryId
        coreWeight = settings.coreWeight
        defaultMode = settings.defaultMode
        transport = settings.transport
        port = settings.port
        peripheralId = settings.peripheralId
        peripheralName = settings.peripheralName
        self.makeInventory = makeInventory
        self.discoverPorts = discoverPorts
        self.discoverFlippers = discoverFlippers
        self.bluetoothPower = bluetoothPower
        self.scanDuration = scanDuration
        self.connectedTransport = connectedTransport
        self.appliesOnChange = appliesOnChange
        self.apply = apply
    }

    /// The settings as edited.
    public var draft: Settings {
        var settings = saved
        settings.baseURL = baseURL
        settings.apiKey = apiKey
        settings.catalogEntryId = catalogEntryId
        settings.coreWeight = coreWeight
        settings.defaultMode = defaultMode
        settings.transport = transport
        settings.port = port
        settings.peripheralId = peripheralId
        settings.peripheralName = peripheralName
        return settings
    }

    public var hasChanges: Bool { draft != saved }

    /// The line next to Revert and Save.
    public var saveStatusText: String { hasChanges ? "Unsaved changes" : "All changes saved" }
    public var canSave: Bool { hasChanges }
    public var canRevert: Bool { hasChanges }

    /// The key was read again after it was unknown: shows it in the field,
    /// unless a different one is being typed. Called when the host's settings
    /// change.
    public func adoptRestoredAPIKey(_ restored: Settings) {
        guard saved.apiKeyUnknown, !restored.apiKeyUnknown, apiKey == saved.apiKey else { return }
        saved.apiKey = restored.apiKey
        saved.apiKeyUnknown = false
        apiKey = restored.apiKey
    }

    /// Puts every field back to the saved settings and drops the results that
    /// were about the edited ones.
    public func revert() {
        baseURL = saved.baseURL
        apiKey = saved.apiKey
        // Picking an entry copies its weight, so the saved weight goes in after it.
        catalogEntryId = saved.catalogEntryId
        coreWeight = saved.coreWeight
        defaultMode = saved.defaultMode
        transport = saved.transport
        port = saved.port
        peripheralId = saved.peripheralId
        peripheralName = saved.peripheralName
        connection = nil
        saveError = nil
        qrStatus = nil
    }

    /// Why the core weight cannot be saved; `nil` when it is in range.
    public var coreWeightError: String? {
        let range = Settings.coreWeightRange
        return range.contains(coreWeight) ? nil : "Core weight must be \(range.lowerBound)–\(range.upperBound) g"
    }

    /// Runs the session's startup check against the draft, then loads the
    /// catalog (`GET /inventory/catalog`); the test passes only when both do.
    /// A test that ends after the URL or the API key changed shows nothing
    /// and keeps the catalog.
    public func testConnection() async {
        connection = .testing
        Log.info(.settings, "test connection: url=\(baseURL)")
        let tested = endpointGeneration
        let inventory: any SpoolInventory
        do {
            inventory = try makeInventory(draft)
        } catch {
            endTest(.failed(Session.describe(error)))
            return
        }
        let state: BambuddyState
        do {
            state = try await Session.state(spoolmanEnabled: inventory.spoolmanEnabled())
        } catch BambuddyError.network(let reason) {
            if tested == endpointGeneration { endTest(.unreachable(reason)) } else { testDropped() }
            return
        } catch {
            state = Session.state(after: error)
        }
        guard tested == endpointGeneration else { return testDropped() }
        guard state.isReady else {
            endTest(.failed(state.message ?? "Bambuddy not ready"))
            return
        }
        do {
            try await fetchCatalog(from: inventory, editedSince: tested)
            endTest(.ready)
        } catch is CancellationError {
            testDropped()
        } catch BambuddyError.network(let reason) {
            endTest(.unreachable(reason))
        } catch {
            endTest(.failed(Session.state(after: error).message ?? Session.describe(error)))
        }
    }

    private func endTest(_ result: Connection) {
        connection = result
        switch result {
        case .testing: break
        case .ready: Log.info(.settings, "test connection: ready")
        case .unreachable(let reason): Log.error(.settings, "test connection: unreachable reason=\(reason)")
        case .failed(let message): Log.error(.settings, "test connection: failed message=\(message)")
        }
    }

    private func testDropped() {
        Log.debug(.settings, "test connection: dropped, the URL or API key was edited")
    }

    private func endpointEdited() {
        endpointGeneration += 1
        connection = nil
    }

    /// The line next to Test connection.
    public var connectionResult: StatusItem { Self.result(connection) }

    public static func result(_ connection: Connection?) -> StatusItem {
        let failed = StatusSymbol.symbol("xmark.circle.fill")
        return switch connection {
        case nil: StatusItem(text: "Not tested", symbol: .symbol("circle.dashed"), tint: .gray)
        case .testing: StatusItem(text: "Testing\u{2026}", symbol: .progress, tint: .gray)
        case .ready:
            StatusItem(
                text: "Ready \u{00B7} inventory access OK", symbol: .symbol("checkmark.circle.fill"), tint: .green
            )
        case .unreachable(let reason): StatusItem(text: "Unreachable: \(reason)", symbol: failed, tint: .red)
        case .failed(let message): StatusItem(text: message, symbol: failed, tint: .red)
        }
    }

    public func loadCatalog() async {
        let inventory: any SpoolInventory
        do {
            inventory = try makeInventory(draft)
        } catch {
            catalogLoads += 1
            catalogError = Session.describe(error)
            Log.error(.settings, "catalog failed: error=\(Session.describe(error))")
            return
        }
        try? await fetchCatalog(from: inventory, editedSince: endpointGeneration)
    }

    /// Loads the catalog; a failure is kept in `catalogError` and rethrown.
    /// An answer for a URL or API key edited since `generation` is dropped
    /// and reported as `CancellationError`. Loads overlap when Settings opens,
    /// Test connection and Reload run together; one that ends after a newer
    /// one started still returns its own answer but leaves `catalog` and
    /// `catalogError` to the newer one.
    private func fetchCatalog(from inventory: any SpoolInventory, editedSince generation: Int) async throws {
        catalogLoads += 1
        let load = catalogLoads
        let loaded: Result<[CatalogEntry], any Error>
        do {
            loaded = .success(try await inventory.catalog())
        } catch {
            loaded = .failure(error)
        }
        switch loaded {
        case .success(let entries): Log.info(.settings, "catalog: entries=\(entries.count)")
        case .failure(let error): Log.error(.settings, "catalog failed: error=\(Session.describe(error))")
        }
        guard generation == endpointGeneration else { throw CancellationError() }
        let latest = load == catalogLoads
        switch loaded {
        case .success(let entries):
            if latest {
                catalog = entries
                catalogError = nil
            }
        case .failure(let error):
            if latest { catalogError = Session.describe(error) }
            throw error
        }
    }

    /// Takes the URL and API key from a scanned Bambuddy QR code; anything
    /// else leaves the fields as they are and says why.
    public func applyQRPayload(_ text: String) {
        do {
            let payload = try APIKeyQRPayload.parse(text)
            baseURL = payload.baseURL
            apiKey = payload.apiKey
            connection = nil
            qrStatus = .applied(Self.qrApplied)
            applyChange {
                $0.baseURL = payload.baseURL
                $0.apiKey = payload.apiKey
            }
        } catch {
            qrStatus = .failed(error.localizedDescription)
        }
    }

    static let qrApplied = "Filled from the QR code."

    /// Scans a QR code, applies it and tests the connection it names; a
    /// cancelled scan changes nothing.
    public func scanQRCode(with scanner: any QRScanning) async {
        do {
            applyQRPayload(try await scanner.scan())
            if case .applied = qrStatus { await testConnection() }
        } catch is CancellationError {
            qrStatus = nil
        } catch {
            qrStatus = .failed(error.localizedDescription)
        }
    }

    /// Flipper ports present now, plus the chosen one if it is unplugged.
    public func refreshPorts() {
        var found = discoverPorts()
        if let port, !found.contains(port) { found.append(port) }
        ports = found
    }

    /// The transport kinds the picker offers.
    public var availableTransports: [TransportKind] { TransportKind.available }

    /// The USB port picker exists (macOS only).
    public var showsUSB: Bool { availableTransports.contains(.usb) }

    /// Starts a fresh Bluetooth scan; `discovered` fills as Flippers answer.
    public func scanForFlippers() {
        stopScanning()
        discovered = []
        scanProblem = nil
        isScanning = true
        let current = scanGeneration
        let stream = discoverFlippers()
        let power = bluetoothPower
        // A scan with the radio off finds nothing; say why instead.
        Task { [weak self] in
            guard let problem = await power().problem, let self, current == self.scanGeneration else { return }
            self.stopScanning()
            self.scanProblem = problem.localizedDescription
        }
        scanTask = Task { [weak self] in
            for await peripheral in stream {
                guard let self, current == self.scanGeneration else { return }
                self.found(peripheral)
            }
            guard let self, current == self.scanGeneration else { return }
            self.isScanning = false
        }
        let duration = scanDuration
        scanTimer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, current == self.scanGeneration else { return }
            self.stopScanning()
        }
    }

    public func stopScanning() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTimer?.cancel()
        scanTask = nil
        scanTimer = nil
        isScanning = false
    }

    /// Lists a Flipper once; a repeated answer updates its name and signal.
    private func found(_ peripheral: DiscoveredPeripheral) {
        if let index = discovered.firstIndex(where: { $0.id == peripheral.id }) {
            discovered[index] = peripheral
        } else {
            discovered.append(peripheral)
        }
    }

    /// Remembers `peripheral` as the Bluetooth Flipper and ends the scan.
    public func choosePeripheral(_ peripheral: DiscoveredPeripheral) {
        holdsApply = true
        transport = .bluetooth
        holdsApply = false
        peripheralId = peripheral.id
        peripheralName = peripheral.name
        stopScanning()
        applyChange {
            $0.transport = .bluetooth
            $0.peripheralId = peripheral.id
            $0.peripheralName = peripheral.name
        }
    }

    /// The Flipper section's status line.
    public var connectionLine: String { Self.connectionLine(connectedTransport()) }

    public static func connectionLine(_ kind: TransportKind?) -> String {
        switch kind {
        case .usb: "Connected over USB"
        case .bluetooth: "Connected over Bluetooth"
        case nil: "No Flipper paired"
        }
    }

    /// The Bluetooth Flipper row: the chosen one, else the scan or the first found.
    public var bluetoothFlipperText: String {
        peripheralName ?? (isScanning ? "Searching\u{2026}" : "First found")
    }

    /// The current transport remembers a Flipper (a USB port, a Bluetooth peripheral).
    public var canForget: Bool {
        switch transport {
        case .usb: port != nil
        case .bluetooth: peripheralId != nil
        }
    }

    /// Goes back to using the first Flipper found over the current transport.
    public func forget() {
        switch transport {
        case .usb:
            port = nil
        case .bluetooth:
            peripheralId = nil
            peripheralName = nil
            applyChange {
                $0.peripheralId = nil
                $0.peripheralName = nil
            }
        }
    }

    @discardableResult
    public func save() async -> Bool {
        if let error = coreWeightError {
            saveError = error
            return false
        }
        return await store(draft)
    }

    private func store(_ settings: Settings) async -> Bool {
        do {
            try await apply(settings)
            saved = settings
            saveError = nil
            return true
        } catch {
            saveError = Session.describe(error)
            return false
        }
    }

    /// The text fields (URL, API key, core weight) were committed: Return,
    /// or leaving the field. Applies them with `appliesOnChange`; a core
    /// weight out of range stays unapplied and shows `coreWeightError`.
    public func commit() {
        let url = baseURL
        let key = apiKey
        let weight = coreWeightError == nil ? coreWeight : nil
        applyChange {
            $0.baseURL = url
            $0.apiKey = key
            if let weight { $0.coreWeight = weight }
        }
    }

    /// Returns once every change made so far has been applied.
    public func settled() async {
        await applying?.value
    }

    /// With `appliesOnChange`, queues `change` to apply on top of the
    /// settings applied last; a change that changes nothing is skipped.
    /// The task holds the model until it is done: the iPad drops the screen
    /// (and the model) on leaving Settings, and a change made just before
    /// must still be applied. The finished task keeps no reference.
    private func applyChange(_ change: @escaping @MainActor (inout Settings) -> Void) {
        guard appliesOnChange, !holdsApply else { return }
        let previous = applying
        applying = Task {
            await previous?.value
            var settings = saved
            change(&settings)
            guard settings != saved else { return }
            if await store(settings) {
                Log.info(.settings, "applied on change")
            } else {
                Log.error(.settings, "apply on change failed: error=\(saveError ?? "")")
            }
        }
    }

    // MARK: iPhone and iPad texts

    /// The Bambuddy section's footer on the iPhone: what Scan QR code does,
    /// the last read, or why there is no Scan.
    public static func qrFooter(cameraAvailable: Bool, status: QRStatus?) -> (text: String, tint: StatusTint) {
        guard cameraAvailable else { return ("This device has no camera. Type the URL and API key instead.", .gray) }
        return switch status {
        case nil: ("Scan the QR code Bambuddy shows when you create an API key.", .gray)
        case .applied(let message): (message, .green)
        case .failed(let message): (message, .red)
        }
    }

    /// The iPhone's Flipper row: the chosen Flipper's name.
    public var flipperRowTitle: String {
        peripheralName ?? (connectedTransport() == nil ? "No Flipper paired" : "Flipper")
    }

    /// The iPhone's Flipper row value: the scan, else the link.
    public var flipperRowState: StatusItem {
        if isScanning { return StatusItem(text: "Searching\u{2026}", symbol: .progress, tint: .gray) }
        return switch connectedTransport() {
        case .bluetooth:
            StatusItem(text: "Bluetooth", symbol: .symbol("antenna.radiowaves.left.and.right"), tint: .green)
        case .usb: StatusItem(text: "USB", symbol: .symbol("cable.connector"), tint: .green)
        case nil:
            StatusItem(text: "Not connected", symbol: .symbol("antenna.radiowaves.left.and.right.slash"), tint: .gray)
        }
    }
}
