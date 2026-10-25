import Foundation

/// Why a line could not be used. Every case means "drop the line and keep going";
/// `unknownType` and `unsupportedVersion` are the ones the protocol says to ignore quietly.
public enum ProtocolError: Error, Equatable, Sendable {
    case unknownType(String)
    case unsupportedVersion(Int)
    /// Not JSON, or a field is missing or has the wrong JSON type.
    case malformed(String)
    /// A field breaks a schema rule (range, pattern, conditional requirement).
    case invalid(String)
    case lineTooLong(Int)
}

/// One NDJSON line between the Flipper and the host (protocol v1), keyed by `t`.
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case scan(Scan)
    case lookup(Lookup)
    case intent(Intent)
    case result(IntentResult)

    public static let version = 1
    /// A line including its terminating "\n" is at most this long.
    public static let maxLineBytes = 8192

    /// The wire value of `t`.
    public var type: String {
        switch self {
        case .hello: "hello"
        case .scan: "scan"
        case .lookup: "lookup"
        case .intent: "intent"
        case .result: "result"
        }
    }

    public static func decode(line: some DataProtocol) throws -> Message {
        do {
            return try JSONDecoder().decode(Message.self, from: Data(line))
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.malformed(String(describing: error))
        }
    }

    public static func decode(line: String) throws -> Message {
        try decode(line: Data(line.utf8))
    }

    /// Compact JSON terminated by "\n", ready to write to the transport.
    public func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(self)
        line.append(0x0A)
        try Self.checkLineLength(line)
        return line
    }

    static func checkLineLength(_ line: Data) throws {
        if line.count > maxLineBytes { throw ProtocolError.lineTooLong(line.count) }
    }
}

extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, v
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        let version = try container.decode(Int.self, forKey: .v)
        guard ["hello", "scan", "lookup", "intent", "result"].contains(type) else {
            throw ProtocolError.unknownType(type)
        }
        guard version == Self.version else { throw ProtocolError.unsupportedVersion(version) }
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "scan": self = .scan(try Scan(from: decoder))
        case "lookup": self = .lookup(try Lookup(from: decoder))
        case "intent": self = .intent(try Intent(from: decoder))
        default: self = .result(try IntentResult(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .t)
        try container.encode(Self.version, forKey: .v)
        switch self {
        case .hello(let payload): try payload.encode(to: encoder)
        case .scan(let payload): try payload.encode(to: encoder)
        case .lookup(let payload): try payload.encode(to: encoder)
        case .intent(let payload): try payload.encode(to: encoder)
        case .result(let payload): try payload.encode(to: encoder)
        }
    }
}

/// First line each side sends. The Flipper sets `fw`, the host sets `os`.
public struct Hello: Codable, Equatable, Sendable {
    public var app: String
    public var fw: String?
    public var os: String?

    public init(app: String, fw: String? = nil, os: String? = nil) {
        self.app = app
        self.fw = fw
        self.os = os
    }

    public func validate() throws {
        try Field.checkText(app, "app", max: 40)
        try fw.map { try Field.checkText($0, "fw", max: 40) }
        try os.map { try Field.checkText($0, "os", max: 40) }
        guard (fw == nil) != (os == nil) else { throw ProtocolError.invalid("hello needs exactly one of fw / os") }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(String.self, forKey: .app)
        fw = try container.decodeIfPresent(String.self, forKey: .fw)
        os = try container.decodeIfPresent(String.self, forKey: .os)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encodeIfPresent(fw, forKey: .fw)
        try container.encodeIfPresent(os, forKey: .os)
    }

    private enum CodingKeys: String, CodingKey {
        case app, fw, os
    }
}

/// Flipper -> host: a tag was read.
public struct Scan: Codable, Equatable, Sendable {
    public var scanId: String
    public var tag: TagDump

    public init(scanId: String, tag: TagDump) {
        self.scanId = scanId
        self.tag = tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanId = try container.decode(String.self, forKey: .scanId)
        tag = try container.decode(TagDump.self, forKey: .tag)
        try Field.checkId(scanId, "scan_id")
    }

    public func encode(to encoder: Encoder) throws {
        try Field.checkId(scanId, "scan_id")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanId, forKey: .scanId)
        try container.encode(tag, forKey: .tag)
    }

    private enum CodingKeys: String, CodingKey {
        case scanId = "scan_id", tag
    }
}

/// Host -> Flipper: what Bambuddy knows about the scanned tag.
public struct Lookup: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case found
        case unknown
        case error
    }

    /// Weights for the Flipper's Enter weight screen.
    public struct Defaults: Codable, Equatable, Sendable {
        public var gross: Int?
        public var label: Int?
        public var core: Int?

        public init(gross: Int? = nil, label: Int? = nil, core: Int? = nil) {
            self.gross = gross
            self.label = label
            self.core = core
        }

        func validate() throws {
            try Field.checkGrams(gross, "defaults.gross")
            try Field.checkGrams(label, "defaults.label")
            try Field.checkGrams(core, "defaults.core")
        }
    }

    public var scanId: String
    public var status: Status
    public var spoolId: Int?
    /// `unknown` only: the tag has enough data (material) for the Flipper to offer New.
    public var prefill: Bool?
    public var lines: [String]
    public var defaults: Defaults?
    public var error: String?

    public init(
        scanId: String, status: Status, spoolId: Int? = nil, prefill: Bool? = nil,
        lines: [String], defaults: Defaults? = nil, error: String? = nil
    ) {
        self.scanId = scanId
        self.status = status
        self.spoolId = spoolId
        self.prefill = prefill
        self.lines = lines
        self.defaults = defaults
        self.error = error
    }

    public func validate() throws {
        try Field.checkId(scanId, "scan_id")
        try Field.checkLines(lines)
        try defaults?.validate()
        try error.map { try Field.checkText($0, "error", max: 200) }
        if let spoolId, spoolId < 1 { throw ProtocolError.invalid("spool_id") }
        if status == .found, spoolId == nil { throw ProtocolError.invalid("found lookup needs spool_id") }
        if status == .error, error == nil { throw ProtocolError.invalid("error lookup needs error") }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanId = try container.decode(String.self, forKey: .scanId)
        status = try container.decode(Status.self, forKey: .status)
        spoolId = try container.decodeIfPresent(Int.self, forKey: .spoolId)
        prefill = try container.decodeIfPresent(Bool.self, forKey: .prefill)
        lines = try container.decode([String].self, forKey: .lines)
        defaults = try container.decodeIfPresent(Defaults.self, forKey: .defaults)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanId, forKey: .scanId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(spoolId, forKey: .spoolId)
        try container.encodeIfPresent(prefill, forKey: .prefill)
        try container.encode(lines, forKey: .lines)
        try container.encodeIfPresent(defaults, forKey: .defaults)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case scanId = "scan_id", status, spoolId = "spool_id", prefill, lines, defaults, error
    }
}

/// Host -> Flipper: outcome of the intent with the same `id` (the wire `result` message).
public struct IntentResult: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var lines: [String]
    public var error: String?

    public init(id: String, ok: Bool, lines: [String], error: String? = nil) {
        self.id = id
        self.ok = ok
        self.lines = lines
        self.error = error
    }

    public func validate() throws {
        try Field.checkId(id, "id")
        try Field.checkLines(lines)
        try error.map { try Field.checkText($0, "error", max: 200) }
        if !ok, error == nil { throw ProtocolError.invalid("failed result needs error") }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        lines = try container.decode([String].self, forKey: .lines)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ok, forKey: .ok)
        try container.encode(lines, forKey: .lines)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, lines, error
    }
}

/// Schema rules shared by several messages.
enum Field {
    static let maxLines = 4
    static let maxLineLength = 40

    /// `^[A-Za-z0-9_.:-]{1,32}$`
    static func checkId(_ id: String, _ name: String) throws {
        let allowed = id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0))
        }
        guard allowed, (1...32).contains(id.unicodeScalars.count) else { throw ProtocolError.invalid(name) }
    }

    static func checkGrams(_ grams: Int?, _ name: String) throws {
        if let grams, !(0...9999).contains(grams) { throw ProtocolError.invalid(name) }
    }

    static func checkText(_ text: String, _ name: String, max: Int) throws {
        guard (1...max).contains(text.unicodeScalars.count) else { throw ProtocolError.invalid(name) }
    }

    static func checkLines(_ lines: [String]) throws {
        guard lines.count <= maxLines, lines.allSatisfy({ $0.unicodeScalars.count <= maxLineLength }) else {
            throw ProtocolError.invalid("lines")
        }
    }
}
