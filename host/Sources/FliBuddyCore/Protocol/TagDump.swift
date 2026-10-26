import Foundation

/// Raw tag dump as read by the Flipper (the `tag` object of `scan` and `intent`).
///
/// `blocks` / `pages` hold decoded bytes keyed by block or page number. An `mfc`
/// tag always carries `blocks` on the wire, empty when no sector was read; an
/// `ntag` tag carries non-empty `pages` and no `blocks`. `missing` is empty when
/// every sector was read.
public struct TagDump: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mfc
        case ntag
    }

    public var type: Kind
    /// Upper-case hex, 4, 7 or 10 bytes.
    public var uid: String
    public var sak: UInt8
    /// Upper-case hex, 2 bytes.
    public var atqa: String
    /// MIFARE Classic data blocks 0-63, 16 bytes each. Sector trailers are never present.
    public var blocks: [Int: [UInt8]]
    /// MIFARE Classic sectors 0-15 that failed authentication or reading.
    public var missing: [Int]
    /// NTAG pages 0-230, 4 bytes each.
    public var pages: [Int: [UInt8]]

    public init(
        type: Kind, uid: String, sak: UInt8, atqa: String,
        blocks: [Int: [UInt8]] = [:], missing: [Int] = [], pages: [Int: [UInt8]] = [:]
    ) {
        self.type = type
        self.uid = uid
        self.sak = sak
        self.atqa = atqa
        self.blocks = blocks
        self.missing = missing
        self.pages = pages
    }

    public func validate() throws {
        try Hex.check(uid, byteCounts: [4, 7, 10], field: "tag.uid")
        try Hex.check(atqa, byteCounts: [2], field: "tag.atqa")
        switch type {
        case .mfc:
            guard pages.isEmpty else { throw ProtocolError.invalid("mfc tag with pages") }
        case .ntag:
            guard !pages.isEmpty else { throw ProtocolError.invalid("ntag tag without pages") }
            guard blocks.isEmpty, missing.isEmpty else { throw ProtocolError.invalid("ntag tag with blocks or missing") }
        }
        for (number, bytes) in blocks where !(0...63).contains(number) || bytes.count != 16 {
            throw ProtocolError.invalid("tag.blocks[\(number)]")
        }
        for (number, bytes) in pages where !(0...230).contains(number) || bytes.count != 4 {
            throw ProtocolError.invalid("tag.pages[\(number)]")
        }
        guard missing.allSatisfy({ (0...15).contains($0) }), Set(missing).count == missing.count else {
            throw ProtocolError.invalid("tag.missing")
        }
    }
}

extension TagDump: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, uid, sak, atqa, blocks, missing, pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(Kind.self, forKey: .type)
        uid = try container.decode(String.self, forKey: .uid)
        sak = try container.decode(UInt8.self, forKey: .sak)
        atqa = try container.decode(String.self, forKey: .atqa)
        blocks = try Self.decodeHexMap(container, .blocks, bytes: 16)
        pages = try Self.decodeHexMap(container, .pages, bytes: 4)
        missing = try container.decodeIfPresent([Int].self, forKey: .missing) ?? []
        // Presence matters for the schema even when the value is empty.
        if type == .mfc, !container.contains(.blocks) { throw ProtocolError.invalid("mfc tag without blocks") }
        if type == .ntag, container.contains(.blocks) { throw ProtocolError.invalid("ntag tag with blocks") }
        if container.contains(.pages), pages.isEmpty { throw ProtocolError.invalid("tag.pages is empty") }
        if type == .ntag, container.contains(.missing) { throw ProtocolError.invalid("ntag tag with missing") }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(uid, forKey: .uid)
        try container.encode(sak, forKey: .sak)
        try container.encode(atqa, forKey: .atqa)
        if type == .mfc { try container.encode(Self.hexMap(blocks), forKey: .blocks) }
        if !missing.isEmpty { try container.encode(missing, forKey: .missing) }
        if !pages.isEmpty { try container.encode(Self.hexMap(pages), forKey: .pages) }
    }

    private static func decodeHexMap(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, bytes: Int
    ) throws -> [Int: [UInt8]] {
        guard let raw = try container.decodeIfPresent([String: String].self, forKey: key) else { return [:] }
        var map: [Int: [UInt8]] = [:]
        for (name, hex) in raw {
            // Decimal without leading zeros, as the schema's propertyNames pattern.
            guard let number = Int(name), String(number) == name else {
                throw ProtocolError.invalid("tag.\(key.stringValue) key \(name)")
            }
            map[number] = try Hex.decode(hex, byteCount: bytes, field: "tag.\(key.stringValue)[\(name)]")
        }
        return map
    }

    private static func hexMap(_ map: [Int: [UInt8]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map.map { (String($0.key), Hex.encode($0.value)) })
    }
}

/// Upper-case hex without separators, as used on the wire.
enum Hex {
    static func encode(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ hex: String, byteCount: Int, field: String) throws -> [UInt8] {
        let utf8 = Array(hex.utf8)
        guard utf8.count == byteCount * 2 else { throw ProtocolError.invalid(field) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else {
                throw ProtocolError.invalid(field)
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    static func check(_ hex: String, byteCounts: Set<Int>, field: String) throws {
        let count = hex.utf8.count
        guard count % 2 == 0, byteCounts.contains(count / 2) else { throw ProtocolError.invalid(field) }
        _ = try decode(hex, byteCount: count / 2, field: field)
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
