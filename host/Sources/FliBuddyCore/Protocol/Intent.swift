import Foundation

/// Flipper -> host: a user action. Self-contained (repeats the tag) and idempotent by `id`.
public struct Intent: Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case weigh
        case new
        case createOnHost = "create_on_host"
        case linkOnHost = "link_on_host"
    }

    /// Whether `grams` is the filament alone (`net`) or spool plus filament (`gross`).
    public enum WeightMode: String, Codable, Sendable {
        case net
        case gross
    }

    public var id: String
    public var scanId: String
    public var action: Action
    public var grams: Int?
    public var mode: WeightMode?
    public var tag: TagDump

    public init(id: String, scanId: String, action: Action, grams: Int? = nil, mode: WeightMode? = nil, tag: TagDump) {
        self.id = id
        self.scanId = scanId
        self.action = action
        self.grams = grams
        self.mode = mode
        self.tag = tag
    }

    public func validate() throws {
        try Field.checkId(id, "id")
        try Field.checkId(scanId, "scan_id")
        try Field.checkGrams(grams, "grams")
        if action == .weigh, grams == nil || mode == nil {
            throw ProtocolError.invalid("weigh intent needs grams and mode")
        }
        try tag.validate()
    }
}

extension Intent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, scanId = "scan_id", action, grams, mode, tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scanId = try container.decode(String.self, forKey: .scanId)
        action = try container.decode(Action.self, forKey: .action)
        grams = try container.decodeIfPresent(Int.self, forKey: .grams)
        mode = try container.decodeIfPresent(WeightMode.self, forKey: .mode)
        tag = try container.decode(TagDump.self, forKey: .tag)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(scanId, forKey: .scanId)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(grams, forKey: .grams)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encode(tag, forKey: .tag)
    }
}
