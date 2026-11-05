import Foundation
import Security

/// How the host reaches the Flipper.
public enum TransportKind: String, CaseIterable, Sendable {
    case usb
    case bluetooth

    /// USB on the Mac, Bluetooth where there is no serial port.
    public static var platformDefault: TransportKind {
        #if os(macOS)
        .usb
        #else
        .bluetooth
        #endif
    }

    /// The kinds this platform can use.
    public static var available: [TransportKind] {
        #if os(macOS)
        [.usb, .bluetooth]
        #else
        [.bluetooth]
        #endif
    }
}

/// Host settings. The API key lives in the Keychain; the rest in a
/// `KeyValueStore` (`UserDefaults` in the apps).
public struct Settings: Equatable, Sendable {
    /// Everything on the scale that is not filament: Bambu reusable spool
    /// 215 g + refill core 27 g, remeasured on 2026-10-29 (Phase 0 used 293 g + 32 g = 325 g).
    public static let defaultCoreWeight = 242
    /// Core weights the settings accept, in grams.
    public static let coreWeightRange = 1...5000

    /// Bambuddy root URL, e.g. `http://192.168.1.20:8000`.
    public var baseURL: String
    /// Empty while `apiKeyUnknown`.
    public var apiKey: String {
        // A different key is a key someone typed, scanned or received.
        // Whitespace is not a key: typing it while the key is unknown must
        // not turn "unknown" into "empty" and delete the saved key.
        didSet { if Self.trimmed(apiKey) != Self.trimmed(oldValue) { apiKeyUnknown = false } }
    }
    /// The Keychain could not be read (the iPhone is locked and the item is
    /// not available before the first unlock), so the saved key is not known;
    /// `apiKey` is empty but nothing was cleared. Saving such settings leaves
    /// the Keychain item alone, and the key is not synced, until a different
    /// key is set or the settings are reloaded.
    public var apiKeyUnknown = false
    /// The empty-spool catalog entry recorded on new items (`core_weight_catalog_id`).
    public var catalogEntryId: Int?
    /// `core_weight` of new items in grams. Picking a catalog entry copies its
    /// weight; it may be edited afterwards.
    public var coreWeight: Int
    /// Net/gross preselected when a weight is entered.
    public var defaultMode: Intent.WeightMode
    public var transport: TransportKind
    /// The Flipper's serial device; `nil` uses the first Flipper found.
    public var port: String?
    /// The remembered Bluetooth Flipper; `nil` uses the first one found.
    public var peripheralId: UUID?
    /// Its name when it was chosen, for display.
    public var peripheralName: String?

    public init(
        baseURL: String = "", apiKey: String = "", catalogEntryId: Int? = nil,
        coreWeight: Int = Settings.defaultCoreWeight, defaultMode: Intent.WeightMode = .gross,
        transport: TransportKind = .platformDefault, port: String? = nil,
        peripheralId: UUID? = nil, peripheralName: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.catalogEntryId = catalogEntryId
        self.coreWeight = coreWeight
        self.defaultMode = defaultMode
        self.transport = transport
        self.port = port
        self.peripheralId = peripheralId
        self.peripheralName = peripheralName
    }

    /// What the Flipper link opens for these settings.
    public var transportChoice: TransportChoice {
        switch transport {
        case .usb: .usb(port: port)
        case .bluetooth: .bluetooth(peripheral: peripheralId)
        }
    }

    /// iPhone, iPad and Watch talk HTTPS only (no App Transport Security
    /// exception); the Mac keeps plain HTTP for now.
    public static var requiresHTTPS: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    /// Whether `text` names a plain-HTTP address that `requireHTTPS` refuses.
    public static func isRefusedHTTP(_ text: String, requireHTTPS: Bool = Settings.requiresHTTPS) -> Bool {
        guard requireHTTPS else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: trimmed)?.scheme?.lowercased() == "http"
    }

    /// `text` without a `user:password@` before the host, with or without a
    /// scheme: what logs, errors and the Flipper may show of a URL. A password
    /// may hold an unencoded `@`, `/`, `?` or `#`, so everything up to the
    /// last `@` goes (an `@` in a path costs the host too: better than a leak).
    public static func withoutCredentials(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^(\s*[A-Za-z][A-Za-z0-9+.-]*://)?\S*@"#, with: "$1", options: .regularExpression
        )
    }

    static func trimmed(_ key: String) -> String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The API key without surrounding whitespace; what is saved and sent.
    public var trimmedAPIKey: String { Self.trimmed(apiKey) }

    /// An http(s) base URL and an API key are set.
    public var isConfigured: Bool { (try? makeClient()) != nil }

    /// A client for these settings. `session` is for tests; `requireHTTPS`
    /// refuses an `http://` address (the default where the platform does).
    public func makeClient(session: URLSession? = nil, requireHTTPS: Bool = Settings.requiresHTTPS) throws -> BambuddyClient {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else { throw BambuddyError.invalidBaseURL(Self.withoutCredentials(text)) }
        if Self.isRefusedHTTP(text, requireHTTPS: requireHTTPS) { throw SettingsError.httpsRequired }
        let key = trimmedAPIKey
        let client = try BambuddyClient(baseURL: url, apiKey: key, session: session)
        guard !key.isEmpty else { throw SettingsError.missingAPIKey }
        return client
    }
}

public enum SettingsError: Error, Equatable, Sendable {
    case missingAPIKey
    /// An `http://` address where only `https://` is allowed.
    case httpsRequired
}

extension SettingsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Enter a Bambuddy API key"
        case .httpsRequired: "FliBuddy needs an https:// address."
        }
    }
}

/// Loads and saves `Settings`: the API key through a `SecretStore`, the rest in
/// a `KeyValueStore`.
public struct SettingsStore: Sendable {
    public static let apiKeyAccount = "bambuddy-api-key"
    private enum Key {
        static let baseURL = "bambuddy.baseURL"
        static let catalogEntryId = "bambuddy.catalogEntryId"
        static let coreWeight = "bambuddy.coreWeight"
        static let version = "settings.version"
        static let defaultMode = "weight.defaultMode"
        static let transport = "flipper.transport"
        static let port = "flipper.port"
        static let peripheralId = "flipper.peripheralId"
        static let peripheralName = "flipper.peripheralName"
    }

    /// The layout of the stored settings. 1: the core weight default moved
    /// from 325 g (Phase 0) to 242 g, and the default is no longer stored.
    static let currentVersion = 1

    private let defaults: any KeyValueStore
    private let secrets: any SecretStore

    public init(defaults: any KeyValueStore = UserDefaults.standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// Saved settings; defaults for anything never saved. An unreadable
    /// Keychain item loads as an unknown API key (`apiKeyUnknown`), not as an
    /// empty one.
    public func load() -> Settings {
        migrate()
        var settings = Settings()
        settings.baseURL = defaults.string(forKey: Key.baseURL) ?? settings.baseURL
        do {
            settings.apiKey = try secrets.secret(for: Self.apiKeyAccount) ?? ""
        } catch {
            settings.apiKeyUnknown = true
            Log.error(.settings, "keychain read failed: \(SecretStoreError.logDescription(error))")
        }
        settings.catalogEntryId = defaults.object(forKey: Key.catalogEntryId) as? Int
        settings.coreWeight = defaults.object(forKey: Key.coreWeight) as? Int ?? settings.coreWeight
        settings.defaultMode = defaults.string(forKey: Key.defaultMode)
            .flatMap(Intent.WeightMode.init(rawValue:)) ?? settings.defaultMode
        settings.transport = defaults.string(forKey: Key.transport)
            .flatMap(TransportKind.init(rawValue:)) ?? settings.transport
        settings.port = defaults.string(forKey: Key.port)
        settings.peripheralId = defaults.string(forKey: Key.peripheralId).flatMap(UUID.init(uuidString:))
        settings.peripheralName = defaults.string(forKey: Key.peripheralName)
        Log.info(.settings, "load: \(Self.summary(settings))")
        return settings
    }

    /// Brings settings stored by an earlier version up to date, once.
    private func migrate() {
        let version = defaults.object(forKey: Key.version) as? Int ?? 0
        guard version < Self.currentVersion else { return }
        // The Phase 0 default, kept by installs that never chose a catalog entry:
        // it becomes the current default so later changes of it reach them.
        if defaults.object(forKey: Key.catalogEntryId) as? Int == nil,
           defaults.object(forKey: Key.coreWeight) as? Int == 325 {
            defaults.removeObject(forKey: Key.coreWeight)
            Log.info(.settings, "migrated core weight 325 to the default \(Settings.defaultCoreWeight)")
        }
        defaults.set(Self.currentVersion, forKey: Key.version)
    }

    /// Saves everything; an empty API key removes the Keychain item. An
    /// unknown API key (`apiKeyUnknown`) leaves the item as it is.
    public func save(_ settings: Settings) throws {
        if !settings.apiKeyUnknown {
            let key = settings.trimmedAPIKey
            do {
                try secrets.setSecret(key.isEmpty ? nil : key, for: Self.apiKeyAccount)
            } catch {
                Log.error(.settings, "keychain write failed: \(SecretStoreError.logDescription(error))")
                throw error
            }
        }
        defaults.set(settings.baseURL, forKey: Key.baseURL)
        if let id = settings.catalogEntryId {
            defaults.set(id, forKey: Key.catalogEntryId)
        } else {
            defaults.removeObject(forKey: Key.catalogEntryId)
        }
        // The default without a catalog entry is not stored, so a later
        // change of the default reaches this install.
        if settings.coreWeight == Settings.defaultCoreWeight, settings.catalogEntryId == nil {
            defaults.removeObject(forKey: Key.coreWeight)
        } else {
            defaults.set(settings.coreWeight, forKey: Key.coreWeight)
        }
        defaults.set(Self.currentVersion, forKey: Key.version)
        defaults.set(settings.defaultMode.rawValue, forKey: Key.defaultMode)
        defaults.set(settings.transport.rawValue, forKey: Key.transport)
        set(settings.port, Key.port)
        set(settings.peripheralId?.uuidString, Key.peripheralId)
        set(settings.peripheralName, Key.peripheralName)
        Log.info(.settings, "save: \(Self.summary(settings))")
    }

    /// The settings for the log: whether there is an API key, never the key.
    static func summary(_ settings: Settings) -> String {
        let empty = settings.trimmedAPIKey.isEmpty
        let key = settings.apiKeyUnknown ? "unknown" : empty ? "absent" : "present"
        return "url=\(Settings.withoutCredentials(settings.baseURL)) key=\(key) catalog=\(settings.catalogEntryId.map(String.init) ?? "none") "
            + "core=\(settings.coreWeight) mode=\(settings.defaultMode.rawValue) transport=\(settings.transport.rawValue)"
    }

    /// Stores `value`, or removes the key for `nil`.
    private func set(_ value: String?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Where settings other than the API key are kept: `UserDefaults` in the app,
/// memory in tests. The accessors `SettingsStore` uses, with `UserDefaults`'
/// signatures. Implementations must be thread-safe.
public protocol KeyValueStore: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func object(forKey key: String) -> Any?
    /// `nil` removes the key.
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// Values in memory, for tests and previews. Unlike a `UserDefaults` suite it
/// leaves no plist in ~/Library/Preferences.
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.withLock { values[key] as? String }
    }

    public func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    public func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    public func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }

    /// Everything stored, like `UserDefaults.dictionaryRepresentation()`.
    public func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { values }
    }
}

/// Where secrets (the API key) are kept: the Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    /// `nil` deletes the secret.
    func setSecret(_ value: String?, for account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Security framework `OSStatus`.
    case status(Int32)

    /// `status=-25300 (The specified item could not be found in the keychain.)`
    /// for a Keychain error, the error's description otherwise.
    static func logDescription(_ error: any Error) -> String {
        guard case SecretStoreError.status(let status) = error else { return Session.describe(error) }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "no description"
        return "status=\(status) (\(message))"
    }
}

/// Generic-password items in the login Keychain.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "FliBuddy"
    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func secret(for account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.status(status) }
        migrateAccessibility(of: account)
        return String(decoding: data, as: UTF8.self)
    }

    /// The accessibility of new items: readable after the first unlock, so a
    /// launch in the background (Bluetooth restoration) while the iPhone is
    /// locked can read the API key. Not backed up to other devices.
    static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    /// A new item (`SecItemAdd`).
    func newItem(_ value: String, for account: String) -> [String: Any] {
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = Self.accessible
        return item
    }

    /// Which items the migration finds (the ones still `WhenUnlocked`, the
    /// default before 1.0) and what it changes on them.
    func accessibilityMigration(for account: String) -> (match: [String: Any], update: [String: Any]) {
        var match = query(account)
        match[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked as String
        return (match, [kSecAttrAccessible as String: Self.accessible])
    }

    /// Moves an item saved by an earlier version to `accessible`. It only
    /// matches items that still need it, so once done it finds nothing; it
    /// runs after a successful read, the one moment the item is available.
    /// A failure is logged and the item stays readable while unlocked.
    private func migrateAccessibility(of account: String) {
        let (match, update) = accessibilityMigration(for: account)
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess: Log.info(.settings, "keychain item migrated to available after first unlock")
        case errSecItemNotFound: break
        default: Log.error(.settings, "keychain migration failed: \(SecretStoreError.logDescription(SecretStoreError.status(status)))")
        }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        guard let value else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
            return
        }
        let status = SecItemUpdate(
            query(account) as CFDictionary,
            [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: Self.accessible] as CFDictionary
        )
        if status == errSecItemNotFound {
            let added = SecItemAdd(newItem(value, for: account) as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecretStoreError.status(added) }
        } else if status != errSecSuccess {
            throw SecretStoreError.status(status)
        }
    }
}

/// Secrets in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func secret(for account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        lock.withLock { values[account] = value }
    }
}
