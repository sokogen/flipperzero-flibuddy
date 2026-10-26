import Foundation
import Observation

/// The Settings screen: an editable copy of the settings, the catalog entry
/// picker, the port picker and the connection test. `save()` hands the draft
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
    /// `nil` uses the first Flipper found.
    public var port: String?

    public private(set) var catalog: [CatalogEntry] = []
    public private(set) var catalogError: String?
    public private(set) var ports: [String] = []
    public private(set) var connection: Connection?
    public private(set) var saveError: String?

    private var saved: Settings
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    private let apply: @MainActor (Settings) async throws -> Void

    public init(
        settings: Settings,
        makeInventory: @escaping @Sendable (Settings) throws -> any SpoolInventory = { try $0.makeClient() },
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() },
        apply: @escaping @MainActor (Settings) async throws -> Void
    ) {
        saved = settings
        baseURL = settings.baseURL
        apiKey = settings.apiKey
        catalogEntryId = settings.catalogEntryId
        coreWeight = settings.coreWeight
        defaultMode = settings.defaultMode
        port = settings.port
        self.makeInventory = makeInventory
        self.discoverPorts = discoverPorts
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
        settings.port = port
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
