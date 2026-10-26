import Foundation
import Testing
@testable import SpoolBuddyCore

@Suite("SettingsSyncPayload")
struct SettingsSyncTests {
    private static let payload = SettingsSyncPayload(
        baseURL: "http://192.168.1.20:8000", apiKey: "bb_key", coreWeight: 325, catalogEntryId: 24, defaultMode: .gross
    )

    /// The Technical Details example.
    private static var dictionary: [String: Any] { [
        "v": 1, "baseURL": "http://192.168.1.20:8000", "apiKey": "bb_key", "coreWeight": 325,
        "catalogEntryId": 24, "defaultMode": "gross",
    ] }

    /// A property-list value for test arguments, which must be `Sendable`.
    enum Value: Sendable, CustomTestStringConvertible {
        case int(Int)
        case string(String)
        case bool(Bool)

        var any: Any {
            switch self {
            case .int(let value): value
            case .string(let value): value
            case .bool(let value): value
            }
        }

        var testDescription: String { "\(any)" }
    }

    @Test func encodesTheVersionedDictionary() {
        let encoded = Self.payload.dictionary
        #expect(encoded["v"] as? Int == 1)
        #expect(encoded["baseURL"] as? String == "http://192.168.1.20:8000")
        #expect(encoded["apiKey"] as? String == "bb_key")
        #expect(encoded["coreWeight"] as? Int == 325)
        #expect(encoded["catalogEntryId"] as? Int == 24)
        #expect(encoded["defaultMode"] as? String == "gross")
        #expect(encoded.count == 6)
        // WatchConnectivity takes property-list types only.
        #expect(PropertyListSerialization.propertyList(encoded, isValidFor: .binary))
    }

    @Test func decodesTheExample() throws {
        #expect(try SettingsSyncPayload(dictionary: Self.dictionary) == Self.payload)
    }

    @Test(arguments: [
        payload,
        SettingsSyncPayload(baseURL: "", apiKey: "", coreWeight: 1, catalogEntryId: nil, defaultMode: .net),
    ])
    func roundTrips(_ payload: SettingsSyncPayload) throws {
        #expect(try SettingsSyncPayload(dictionary: payload.dictionary) == payload)
    }

    @Test func noCatalogEntryLeavesTheKeyOut() {
        var payload = Self.payload
        payload.catalogEntryId = nil
        #expect(payload.dictionary["catalogEntryId"] == nil)
        #expect(payload.dictionary.count == 5)
    }

    @Test func survivesAPropertyListRoundTrip() throws {
        // What arrives on the watch went through serialization: numbers are NSNumber.
        let data = try PropertyListSerialization.data(fromPropertyList: Self.payload.dictionary, format: .binary, options: 0)
        let decoded = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(try SettingsSyncPayload(dictionary: decoded) == Self.payload)
    }

    @Test(arguments: [0, 2, 99])
    func rejectsOtherVersions(_ version: Int) {
        var dictionary = Self.dictionary
        dictionary["v"] = version
        #expect(throws: SettingsSyncError.unsupportedVersion(version)) { try SettingsSyncPayload(dictionary: dictionary) }
    }

    @Test(arguments: ["v", "baseURL", "apiKey", "coreWeight", "defaultMode"])
    func rejectsAMissingField(_ key: String) {
        var dictionary = Self.dictionary
        dictionary[key] = nil
        #expect(throws: SettingsSyncError.missingField(key)) { try SettingsSyncPayload(dictionary: dictionary) }
    }

    @Test func theCatalogEntryIsOptional() throws {
        var dictionary = Self.dictionary
        dictionary["catalogEntryId"] = nil
        #expect(try SettingsSyncPayload(dictionary: dictionary).catalogEntryId == nil)
    }

    @Test(arguments: [
        ("baseURL", Value.int(5)),
        ("apiKey", .bool(true)),
        ("coreWeight", .string("325")),
        ("coreWeight", .bool(true)),
        ("coreWeight", .int(0)),
        ("coreWeight", .int(5001)),
        ("catalogEntryId", .string("24")),
        ("defaultMode", .string("tare")),
        ("v", .string("1")),
        ("v", .bool(true)),
    ])
    func rejectsAnInvalidField(_ key: String, _ value: Value) {
        var dictionary = Self.dictionary
        dictionary[key] = value.any
        #expect(throws: SettingsSyncError.invalidField(key)) { try SettingsSyncPayload(dictionary: dictionary) }
    }

    @Test func decodeWrapsTheResult() {
        #expect(SettingsSyncPayload.decode(Self.dictionary) == .success(Self.payload))
        #expect(SettingsSyncPayload.decode([:]) == .failure(.missingField("v")))
    }

    @Test func takesTheSyncedFieldsFromTheSettings() {
        var settings = testSettings
        settings.transport = .bluetooth
        settings.peripheralId = UUID()
        let payload = SettingsSyncPayload(settings)
        #expect(payload == SettingsSyncPayload(
            baseURL: "http://bambuddy.test:8000", apiKey: "bb_test", coreWeight: 250, catalogEntryId: 3, defaultMode: .gross
        ))
    }

    @Test func applyingKeepsTheTransport() {
        let flipper = UUID()
        let watch = Settings(transport: .bluetooth, peripheralId: flipper, peripheralName: "Flipper Anmaa1")
        let applied = Self.payload.applied(to: watch)
        #expect(applied.baseURL == "http://192.168.1.20:8000")
        #expect(applied.apiKey == "bb_key")
        #expect(applied.coreWeight == 325)
        #expect(applied.catalogEntryId == 24)
        #expect(applied.defaultMode == .gross)
        #expect(applied.transport == .bluetooth)
        #expect(applied.peripheralId == flipper)
        #expect(applied.peripheralName == "Flipper Anmaa1")
    }

    @Test func errorsReadForPeople() {
        #expect(SettingsSyncError.unsupportedVersion(2).localizedDescription.contains("2"))
        #expect(SettingsSyncError.missingField("apiKey").localizedDescription.contains("apiKey"))
        #expect(SettingsSyncError.invalidField("coreWeight").localizedDescription.contains("coreWeight"))
    }
}
