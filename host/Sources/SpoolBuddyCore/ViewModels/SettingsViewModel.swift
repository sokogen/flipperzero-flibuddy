import Foundation
import Observation

/// The Settings screen: an editable copy of the settings, the catalog entry
/// picker, the transport settings (USB port, Bluetooth Flipper scan) and the
/// connection test. `save()` hands the draft
/// to `apply`, which stores it and reconfigures the session.
@MainActor
@Observable
public final class SettingsViewModel {
    public enum Connection: Equatable, Sendable {
        case testing
        case ok(String)
        case failed(String)
    }

    public var baseURL: String
    public var apiKey: String
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
    public private(set) var connection: Connection?
    public private(set) var saveError: String?

    private var saved: Settings
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    private let discoverFlippers: @MainActor () -> AsyncStream<DiscoveredPeripheral>
    private let scanDuration: Duration
    private let apply: @MainActor (Settings) async throws -> Void
    private var scanTask: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?
    /// Bumped by every scan start and stop; a stale scan changes nothing.
    private var scanGeneration = 0

    /// `discoverFlippers` streams Flippers advertising over Bluetooth; a scan
    /// stops by itself after `scanDuration`.
    public init(
        settings: Settings,
        makeInventory: @escaping @Sendable (Settings) throws -> any SpoolInventory = { try $0.makeClient() },
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() },
        discoverFlippers: @escaping @MainActor () -> AsyncStream<DiscoveredPeripheral> = { FlipperLink.defaultScan() },
        scanDuration: Duration = .seconds(15),
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
        self.scanDuration = scanDuration
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

    /// Why the core weight cannot be saved; `nil` when it is in range.
    public var coreWeightError: String? {
        let range = Settings.coreWeightRange
        return range.contains(coreWeight) ? nil : "Core weight must be \(range.lowerBound)–\(range.upperBound) g"
    }

    /// Runs the session's startup check against the draft; loads the catalog when it passes.
    public func testConnection() async {
        connection = .testing
        let settings = draft
        let inventory: any SpoolInventory
        do {
            inventory = try makeInventory(settings)
        } catch {
            connection = .failed(Session.describe(error))
            return
        }
        let state = await Session.check(inventory)
        guard state.isReady else {
            connection = .failed(state.message ?? "Bambuddy not ready")
            return
        }
        connection = .ok("Connected; internal inventory")
        await loadCatalog(from: inventory)
    }

    public func loadCatalog() async {
        do {
            await loadCatalog(from: try makeInventory(draft))
        } catch {
            catalogError = Session.describe(error)
        }
    }

    private func loadCatalog(from inventory: any SpoolInventory) async {
        do {
            catalog = try await inventory.catalog()
            catalogError = nil
        } catch {
            catalogError = Session.describe(error)
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
        isScanning = true
        let current = scanGeneration
        let stream = discoverFlippers()
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

    /// Goes back to using the first Flipper found.
    public func forgetPeripheral() {
        peripheralId = nil
        peripheralName = nil
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
