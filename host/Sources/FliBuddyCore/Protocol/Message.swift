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

/// One NDJSON line between the Flipper and the host (protocol v2), keyed by `t`.
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case scan(Scan)
    case lookup(Lookup)
    case intent(Intent)
    case result(IntentResult)

    public static let version = 2
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
        // `v` first: a peer of another version is ignored whatever it sends.
        let version = try container.decode(Int.self, forKey: .v)
        guard version == Self.version else { throw ProtocolError.unsupportedVersion(version) }
        let type = try container.decode(String.self, forKey: .t)
        guard ["hello", "scan", "lookup", "intent", "result"].contains(type) else {
            throw ProtocolError.unknownType(type)
        }
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
    /// The Flipper's Auto-save new: create an unknown tag with material at once.
    public var autosave: Bool
    public var tag: TagDump

    public init(scanId: String, autosave: Bool = false, tag: TagDump) {
        self.scanId = scanId
        self.autosave = autosave
        self.tag = tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanId = try container.decode(String.self, forKey: .scanId)
        autosave = try container.decode(Bool.self, forKey: .autosave)
        tag = try container.decode(TagDump.self, forKey: .tag)
        try Field.checkId(scanId, "scan_id")
    }

    public func encode(to encoder: Encoder) throws {
        try Field.checkId(scanId, "scan_id")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanId, forKey: .scanId)
        try container.encode(autosave, forKey: .autosave)
        try container.encode(tag, forKey: .tag)
    }

    private enum CodingKeys: String, CodingKey {
        case scanId = "scan_id", autosave, tag
    }
}

/// A Bambuddy spool as the Flipper lays it out (`lookup.spool`, `result.spool`).
public struct SpoolSummary: Codable, Equatable, Sendable {
    public var id: Int
    public var material: String
    public var subtype: String?
    public var colorName: String?
    /// `RRGGBBAA`, upper-case hex.
    public var rgba: String?
    /// Grams of filament left.
    public var remaining: Int
    /// Filament weight per label (a full spool).
    public var label: Int
    /// Empty spool weight.
    public var core: Int
    /// `true` for a spool in Bambuddy's archive; encoded only when true.
    public var archived: Bool

    public init(
        id: Int, material: String, subtype: String? = nil, colorName: String? = nil, rgba: String? = nil,
        remaining: Int, label: Int, core: Int, archived: Bool = false
    ) {
        self.id = id
        self.material = material
        self.subtype = subtype
        self.colorName = colorName
        self.rgba = rgba
        self.remaining = remaining
        self.label = label
        self.core = core
        self.archived = archived
    }

    public func validate() throws {
        if id < 1 { throw ProtocolError.invalid("spool.id") }
        try Field.checkText(material, "spool.material", max: Field.maxName)
        try subtype.map { try Field.checkText($0, "spool.subtype", max: Field.maxName) }
        try colorName.map { try Field.checkText($0, "spool.color_name", max: Field.maxName) }
        try rgba.map { try Field.checkRGBA($0, "spool.rgba") }
        try Field.checkGrams(remaining, "spool.remaining")
        try Field.checkGrams(label, "spool.label")
        try Field.checkGrams(core, "spool.core")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        material = try container.decode(String.self, forKey: .material)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        rgba = try container.decodeIfPresent(String.self, forKey: .rgba)
        remaining = try container.decode(Int.self, forKey: .remaining)
        label = try container.decode(Int.self, forKey: .label)
        core = try container.decode(Int.self, forKey: .core)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(material, forKey: .material)
        try container.encodeIfPresent(subtype, forKey: .subtype)
        try container.encodeIfPresent(colorName, forKey: .colorName)
        try container.encodeIfPresent(rgba, forKey: .rgba)
        try container.encode(remaining, forKey: .remaining)
        try container.encode(label, forKey: .label)
        try container.encode(core, forKey: .core)
        if archived { try container.encode(true, forKey: .archived) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, material, subtype, colorName = "color_name", rgba, remaining, label, core, archived
    }
}

/// What the host parsed from an unknown tag (`lookup.tag_info`); each field
/// only when the tag carries it.
public struct TagInfo: Codable, Equatable, Sendable {
    public var material: String?
    public var subtype: String?
    public var rgba: String?
    public var label: Int?
    /// Bambuddy's name for the colour.
    public var colorName: String?
    /// The filament code from block 1, e.g. `GFA00`.
    public var code: String?
    /// Millimetres as text, e.g. `1.75`.
    public var diameter: String?
    public var nozzleMin: Int?
    public var nozzleMax: Int?

    public init(
        material: String? = nil, subtype: String? = nil, rgba: String? = nil, label: Int? = nil,
        colorName: String? = nil, code: String? = nil, diameter: String? = nil,
        nozzleMin: Int? = nil, nozzleMax: Int? = nil
    ) {
        self.material = material
        self.subtype = subtype
        self.rgba = rgba
        self.label = label
        self.colorName = colorName
        self.code = code
        self.diameter = diameter
        self.nozzleMin = nozzleMin
        self.nozzleMax = nozzleMax
    }

    public var isEmpty: Bool {
        material == nil && subtype == nil && rgba == nil && label == nil && colorName == nil && code == nil
            && diameter == nil && nozzleMin == nil && nozzleMax == nil
    }

    static let maxCode = 16

    public func validate() throws {
        try material.map { try Field.checkText($0, "tag_info.material", max: Field.maxName) }
        try subtype.map { try Field.checkText($0, "tag_info.subtype", max: Field.maxName) }
        try rgba.map { try Field.checkRGBA($0, "tag_info.rgba") }
        try Field.checkGrams(label, "tag_info.label")
        try colorName.map { try Field.checkText($0, "tag_info.color_name", max: Field.maxName) }
        try code.map { try Field.checkText($0, "tag_info.code", max: Self.maxCode) }
        if let diameter, !Self.isDiameter(diameter) { throw ProtocolError.invalid("tag_info.diameter") }
        for (value, name) in [(nozzleMin, "tag_info.nozzle_min"), (nozzleMax, "tag_info.nozzle_max")] {
            if let value, !(0...999).contains(value) { throw ProtocolError.invalid(name) }
        }
    }

    /// `^[0-9]{1,2}\.[0-9]{1,2}$`, as in the schema.
    static func isDiameter(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { (1...2).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        material = try container.decodeIfPresent(String.self, forKey: .material)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        rgba = try container.decodeIfPresent(String.self, forKey: .rgba)
        label = try container.decodeIfPresent(Int.self, forKey: .label)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        diameter = try container.decodeIfPresent(String.self, forKey: .diameter)
        nozzleMin = try container.decodeIfPresent(Int.self, forKey: .nozzleMin)
        nozzleMax = try container.decodeIfPresent(Int.self, forKey: .nozzleMax)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(material, forKey: .material)
        try container.encodeIfPresent(subtype, forKey: .subtype)
        try container.encodeIfPresent(rgba, forKey: .rgba)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(colorName, forKey: .colorName)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(diameter, forKey: .diameter)
        try container.encodeIfPresent(nozzleMin, forKey: .nozzleMin)
        try container.encodeIfPresent(nozzleMax, forKey: .nozzleMax)
    }

    private enum CodingKeys: String, CodingKey {
        case material, subtype, rgba, label, colorName = "color_name", code, diameter
        case nozzleMin = "nozzle_min", nozzleMax = "nozzle_max"
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
    /// `found` only: the spool, whose `id` is `spoolId`.
    public var spool: SpoolSummary?
    /// `found` only: the host created the spool from this scan (autosave).
    /// Encoded only when true.
    public var created: Bool
    /// `unknown` only: the tag has enough data (material) for the Flipper to offer New.
    public var prefill: Bool?
    /// `unknown` only: what the tag carries.
    public var tagInfo: TagInfo?
    public var lines: [String]
    public var defaults: Defaults?
    public var error: String?

    public init(
        scanId: String, status: Status, spoolId: Int? = nil, spool: SpoolSummary? = nil, created: Bool = false,
        prefill: Bool? = nil, tagInfo: TagInfo? = nil, lines: [String], defaults: Defaults? = nil,
        error: String? = nil
    ) {
        self.scanId = scanId
        self.status = status
        self.spoolId = spoolId
        self.spool = spool
        self.created = created
        self.prefill = prefill
        self.tagInfo = tagInfo
        self.lines = lines
        self.defaults = defaults
        self.error = error
    }

    /// The schema's rules, including which fields each status allows.
    public func validate() throws {
        try Field.checkId(scanId, "scan_id")
        try Field.checkLines(lines)
        try defaults?.validate()
        try spool?.validate()
        try tagInfo?.validate()
        try error.map { try Field.checkText($0, "error", max: 200) }
        if let spoolId, spoolId < 1 { throw ProtocolError.invalid("spool_id") }
        switch status {
        case .found:
            guard let spoolId else { throw ProtocolError.invalid("found lookup needs spool_id") }
            if let spool, spool.id != spoolId { throw ProtocolError.invalid("spool.id differs from spool_id") }
            if prefill != nil || tagInfo != nil { throw ProtocolError.invalid("found lookup with prefill or tag_info") }
        case .unknown:
            if spoolId != nil || spool != nil || created {
                throw ProtocolError.invalid("unknown lookup with spool_id, spool or created")
            }
        case .error:
            if error == nil { throw ProtocolError.invalid("error lookup needs error") }
            if spoolId != nil || spool != nil || created || prefill != nil || tagInfo != nil {
                throw ProtocolError.invalid("error lookup with spool or tag fields")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanId = try container.decode(String.self, forKey: .scanId)
        status = try container.decode(Status.self, forKey: .status)
        spoolId = try container.decodeIfPresent(Int.self, forKey: .spoolId)
        spool = try container.decodeIfPresent(SpoolSummary.self, forKey: .spool)
        // A `created: false` sent explicitly is allowed only where `created` is.
        let sentCreated = try container.decodeIfPresent(Bool.self, forKey: .created)
        created = sentCreated ?? false
        prefill = try container.decodeIfPresent(Bool.self, forKey: .prefill)
        tagInfo = try container.decodeIfPresent(TagInfo.self, forKey: .tagInfo)
        lines = try container.decode([String].self, forKey: .lines)
        defaults = try container.decodeIfPresent(Defaults.self, forKey: .defaults)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if sentCreated != nil, status != .found { throw ProtocolError.invalid("created outside a found lookup") }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanId, forKey: .scanId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(spoolId, forKey: .spoolId)
        try container.encodeIfPresent(spool, forKey: .spool)
        if created { try container.encode(true, forKey: .created) }
        try container.encodeIfPresent(prefill, forKey: .prefill)
        try container.encodeIfPresent(tagInfo, forKey: .tagInfo)
        try container.encode(lines, forKey: .lines)
        try container.encodeIfPresent(defaults, forKey: .defaults)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case scanId = "scan_id", status, spoolId = "spool_id", spool, created, prefill, tagInfo = "tag_info", lines,
             defaults, error
    }
}

/// Host -> Flipper: outcome of the intent with the same `id` (the wire `result` message).
public struct IntentResult: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var lines: [String]
    /// `ok` only: the spool after the action.
    public var spool: SpoolSummary?
    public var error: String?

    public init(id: String, ok: Bool, lines: [String], spool: SpoolSummary? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.lines = lines
        self.spool = spool
        self.error = error
    }

    public func validate() throws {
        try Field.checkId(id, "id")
        try Field.checkLines(lines)
        try spool?.validate()
        try error.map { try Field.checkText($0, "error", max: 200) }
        if !ok, error == nil { throw ProtocolError.invalid("failed result needs error") }
        if !ok, spool != nil { throw ProtocolError.invalid("failed result with spool") }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        lines = try container.decode([String].self, forKey: .lines)
        spool = try container.decodeIfPresent(SpoolSummary.self, forKey: .spool)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ok, forKey: .ok)
        try container.encode(lines, forKey: .lines)
        try container.encodeIfPresent(spool, forKey: .spool)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, lines, spool, error
    }
}

/// Schema rules shared by several messages.
enum Field {
    static let maxLines = 4
    static let maxLineLength = 40
    /// Material, subtype and colour name in `spool` / `tag_info`.
    static let maxName = 40

    /// `^[A-Za-z0-9_.:-]{1,32}$`
    static func checkId(_ id: String, _ name: String) throws {
        let allowed = id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0))
        }
        guard allowed, (1...32).contains(id.unicodeScalars.count) else { throw ProtocolError.invalid(name) }
    }

    /// `^[0-9A-F]{8}$`
    static func checkRGBA(_ rgba: String, _ name: String) throws {
        guard isRGBA(rgba) else { throw ProtocolError.invalid(name) }
    }

    static func isRGBA(_ text: String) -> Bool {
        text.utf8.count == 8 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }
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
