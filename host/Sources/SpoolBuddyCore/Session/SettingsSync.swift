import Foundation

/// The settings the iPhone hands to the watch: what Bambuddy needs, not the
/// transport (each device keeps its own Flipper). Travels as a WatchConnectivity
/// application context, a dictionary of property-list values:
/// `{"v": 1, "baseURL": "...", "apiKey": "...", "coreWeight": 325, "catalogEntryId": 24, "defaultMode": "gross"}`.
/// `catalogEntryId` is left out when no catalog entry is chosen.
public struct SettingsSyncPayload: Equatable, Sendable {
    public static let version = 1

    public var baseURL: String
    public var apiKey: String
    public var coreWeight: Int
    public var catalogEntryId: Int?
    public var defaultMode: Intent.WeightMode

    public init(baseURL: String, apiKey: String, coreWeight: Int, catalogEntryId: Int?, defaultMode: Intent.WeightMode) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.coreWeight = coreWeight
        self.catalogEntryId = catalogEntryId
        self.defaultMode = defaultMode
    }

    /// The synced fields of `settings`.
    public init(_ settings: Settings) {
        self.init(
            baseURL: settings.baseURL, apiKey: settings.apiKey, coreWeight: settings.coreWeight,
            catalogEntryId: settings.catalogEntryId, defaultMode: settings.defaultMode
        )
    }

    /// `settings` with the synced fields replaced; the transport stays.
    public func applied(to settings: Settings) -> Settings {
        var settings = settings
        settings.baseURL = baseURL
        settings.apiKey = apiKey
        settings.coreWeight = coreWeight
        settings.catalogEntryId = catalogEntryId
        settings.defaultMode = defaultMode
        return settings
    }

    private enum Key {
        static let version = "v"
        static let baseURL = "baseURL"
        static let apiKey = "apiKey"
        static let coreWeight = "coreWeight"
        static let catalogEntryId = "catalogEntryId"
        static let defaultMode = "defaultMode"
    }

    public var dictionary: [String: Any] {
        var dictionary: [String: Any] = [
            Key.version: Self.version, Key.baseURL: baseURL, Key.apiKey: apiKey, Key.coreWeight: coreWeight,
            Key.defaultMode: defaultMode.rawValue,
        ]
        dictionary[Key.catalogEntryId] = catalogEntryId
        return dictionary
    }

    /// Reads version 1; any other version, a missing required field or a
    /// value of the wrong type or out of range is rejected.
    public init(dictionary: [String: Any]) throws(SettingsSyncError) {
        let version: Int = try Self.field(Key.version, in: dictionary)
        guard version == Self.version else { throw .unsupportedVersion(version) }
        baseURL = try Self.field(Key.baseURL, in: dictionary)
        apiKey = try Self.field(Key.apiKey, in: dictionary)
        coreWeight = try Self.field(Key.coreWeight, in: dictionary)
        guard Settings.coreWeightRange.contains(coreWeight) else { throw .invalidField(Key.coreWeight) }
        if dictionary[Key.catalogEntryId] == nil {
            catalogEntryId = nil
        } else {
            catalogEntryId = try Self.field(Key.catalogEntryId, in: dictionary) as Int
        }
        let mode: String = try Self.field(Key.defaultMode, in: dictionary)
        guard let defaultMode = Intent.WeightMode(rawValue: mode) else { throw .invalidField(Key.defaultMode) }
        self.defaultMode = defaultMode
    }

    /// `init(dictionary:)` as a `Result`, which can cross actors (the dictionary cannot).
    public static func decode(_ dictionary: [String: Any]) -> Result<SettingsSyncPayload, SettingsSyncError> {
        Result { () throws(SettingsSyncError) in try SettingsSyncPayload(dictionary: dictionary) }
    }

    private static func field<Value>(_ key: String, in dictionary: [String: Any]) throws(SettingsSyncError) -> Value {
        guard let raw = dictionary[key] else { throw .missingField(key) }
        guard let value = raw as? Value, !isBool(raw) || Value.self == Bool.self else { throw .invalidField(key) }
        return value
    }

    /// A boolean bridges to `Int` through `NSNumber`; it is not a number here.
    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

public enum SettingsSyncError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case missingField(String)
    case invalidField(String)
}

extension SettingsSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Settings from the iPhone have version \(version); update SpoolBuddy"
        case .missingField(let key): "Settings from the iPhone lack \(key)"
        case .invalidField(let key): "Settings from the iPhone have an invalid \(key)"
        }
    }
}
