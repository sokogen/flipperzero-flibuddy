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

/// Host settings. The API key lives in the Keychain; the rest in `UserDefaults`.
public struct Settings: Equatable, Sendable {
    /// Everything on the scale that is not filament: Bambu reusable spool
    /// 293 g + refill core 32 g, measured in Phase 0.
    public static let defaultCoreWeight = 325
    /// Core weights the settings accept, in grams.
    public static let coreWeightRange = 1...5000

    /// Bambuddy root URL, e.g. `http://192.168.1.20:8000`.
    public var baseURL: String
    public var apiKey: String
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

    /// An http(s) base URL and an API key are set.
    public var isConfigured: Bool { (try? makeClient()) != nil }

    /// A client for these settings. `session` is for tests.
    public func makeClient(session: URLSession? = nil) throws -> BambuddyClient {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else { throw BambuddyError.invalidBaseURL(text) }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try BambuddyClient(baseURL: url, apiKey: key, session: session)
        guard !key.isEmpty else { throw SettingsError.missingAPIKey }
        return client
    }
}

public enum SettingsError: Error, Equatable, Sendable {
    case missingAPIKey
}

extension SettingsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Enter a Bambuddy API key"
        }
    }
}

/// Loads and saves `Settings`: the API key through a `SecretStore`, the rest in
/// `UserDefaults`.
public struct SettingsStore: @unchecked Sendable {
    public static let apiKeyAccount = "bambuddy-api-key"
    private enum Key {
        static let baseURL = "bambuddy.baseURL"
        static let catalogEntryId = "bambuddy.catalogEntryId"
        static let coreWeight = "bambuddy.coreWeight"
        static let defaultMode = "weight.defaultMode"
        static let transport = "flipper.transport"
        static let port = "flipper.port"
        static let peripheralId = "flipper.peripheralId"
        static let peripheralName = "flipper.peripheralName"
    }

    // UserDefaults is thread-safe.
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// Saved settings; defaults for anything never saved. An unreadable
    /// Keychain item loads as no API key.
    public func load() -> Settings {
        var settings = Settings()
        settings.baseURL = defaults.string(forKey: Key.baseURL) ?? settings.baseURL
        settings.apiKey = ((try? secrets.secret(for: Self.apiKeyAccount)) ?? nil) ?? ""
        settings.catalogEntryId = defaults.object(forKey: Key.catalogEntryId) as? Int
        settings.coreWeight = defaults.object(forKey: Key.coreWeight) as? Int ?? settings.coreWeight
        settings.defaultMode = defaults.string(forKey: Key.defaultMode)
            .flatMap(Intent.WeightMode.init(rawValue:)) ?? settings.defaultMode
        settings.transport = defaults.string(forKey: Key.transport)
            .flatMap(TransportKind.init(rawValue:)) ?? settings.transport
        settings.port = defaults.string(forKey: Key.port)
        settings.peripheralId = defaults.string(forKey: Key.peripheralId).flatMap(UUID.init(uuidString:))
        settings.peripheralName = defaults.string(forKey: Key.peripheralName)
        return settings
    }

    /// Saves everything; an empty API key removes the Keychain item.
    public func save(_ settings: Settings) throws {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try secrets.setSecret(key.isEmpty ? nil : key, for: Self.apiKeyAccount)
        defaults.set(settings.baseURL, forKey: Key.baseURL)
        if let id = settings.catalogEntryId {
            defaults.set(id, forKey: Key.catalogEntryId)
        } else {
            defaults.removeObject(forKey: Key.catalogEntryId)
        }
        defaults.set(settings.coreWeight, forKey: Key.coreWeight)
        defaults.set(settings.defaultMode.rawValue, forKey: Key.defaultMode)
        defaults.set(settings.transport.rawValue, forKey: Key.transport)
        set(settings.port, Key.port)
        set(settings.peripheralId?.uuidString, Key.peripheralId)
        set(settings.peripheralName, Key.peripheralName)
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

/// Where secrets (the API key) are kept: the Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    /// `nil` deletes the secret.
    func setSecret(_ value: String?, for account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Security framework `OSStatus`.
    case status(Int32)
}

/// Generic-password items in the login Keychain.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "SpoolBuddy"
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
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        guard let value else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
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
