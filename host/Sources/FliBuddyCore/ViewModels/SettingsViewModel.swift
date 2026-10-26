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
            guard catalogEntryId != oldValue, let entry = catalog.first(where: { $0.id == catalogEntryId }) else { return }
            coreWeight = entry.weight
        }
    }
    /// Grams; editable, saved as is.
    public var coreWeight: Int
    public var defaultMode: Intent.WeightMode
    public var transport: TransportKind
    /// `nil` uses the first Flipper found.
    public var port: String?
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

    private var saved: Settings
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    private let discoverFlippers: @MainActor () -> AsyncStream<DiscoveredPeripheral>
    private let bluetoothPower: @MainActor () async -> BLEPowerState
    private let scanDuration: Duration
    private let connectedTransport: @MainActor () -> TransportKind?
    private let apply: @MainActor (Settings) async throws -> Void
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
            qrStatus = .applied("URL and API key read from the QR code; Save to keep them")
        } catch {
            qrStatus = .failed(error.localizedDescription)
        }
    }

    /// Scans a QR code and applies it; a cancelled scan changes nothing.
    public func scanQRCode(with scanner: any QRScanning) async {
        do {
            applyQRPayload(try await scanner.scan())
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
        transport = .bluetooth
        peripheralId = peripheral.id
        peripheralName = peripheral.name
        stopScanning()
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
        }
    }

    @discardableResult
    public func save() async -> Bool {
        if let error = coreWeightError {
            saveError = error
            return false
        }
        let settings = draft
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
}
