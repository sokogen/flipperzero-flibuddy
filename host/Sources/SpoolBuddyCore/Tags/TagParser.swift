import Foundation

/// Turns a `TagDump` into a `ParsedTag`. Pure functions, no I/O; mirrors
/// `tools/bridge/bambu_tag.py` byte for byte.
///
/// Bambu block layout (public Bambu RFID tag guide, to be confirmed on real
/// dumps in Phase 0):
/// - block 1: material variant id (bytes 0-7) + material id (8-15), ASCII
/// - block 2: filament type, ASCII (`PLA`)
/// - block 4: detailed type, ASCII (`PLA Basic`)
/// - block 5: RGBA (0-3), label weight uint16 LE grams (4-5), diameter float32 LE (8-11)
/// - block 6: uint16 LE drying temp, drying hours, bed type, bed temp, nozzle max, nozzle min
///
/// The tray UUID location is not settled, so the parser returns candidates in
/// lookup order: block 9 as raw hex (tag guide), then blocks 4+5 the way the
/// SpoolBuddy daemon reads them (the first 32 hex characters of their ASCII
/// text, else block 4 as raw hex). All-zero values are skipped and duplicates
/// collapsed.
public enum TagParser {
    private static let zeroUuid = String(repeating: "0", count: 32)

    public static func parse(_ dump: TagDump) -> ParsedTag {
        let uid = dump.uid.uppercased()
        guard dump.type == .mfc else { return ParsedTag(kind: .ntag, uid: uid) }

        let missing = Set(dump.missing)
        let blocks = dump.blocks.filter { !missing.contains($0.key / 4) && $0.value.count == 16 }
        var tag = ParsedTag(kind: .bambu, uid: uid, trayUuidCandidates: trayUuidCandidates(blocks))

        if let block1 = blocks[1] {
            tag.variantId = ascii(block1[0..<8])
            tag.materialId = ascii(block1[8..<16])
        }
        tag.material = blocks[2].flatMap { ascii($0[...]) }
        tag.detailedType = blocks[4].flatMap { ascii($0[...]) }
        if let block5 = blocks[5] {
            tag.rgba = Hex.encode(Array(block5[0..<4]))
            tag.labelWeight = nonzero(u16(block5, 4))
            let diameter = Float(bitPattern: u32(block5, 8))
            tag.diameter = diameter == 0 ? nil : Double(diameter)
        }
        if let block6 = blocks[6] {
            tag.dryingTemp = nonzero(u16(block6, 0))
            tag.dryingHours = nonzero(u16(block6, 2))
            tag.bedTemp = nonzero(u16(block6, 6))
            tag.nozzleMax = nonzero(u16(block6, 8))
            tag.nozzleMin = nonzero(u16(block6, 10))
        }
        return tag
    }

    static func trayUuidCandidates(_ blocks: [Int: [UInt8]]) -> [String] {
        var candidates: [String?] = []
        if let block9 = blocks[9] { candidates.append(Hex.encode(block9)) }
        if let block4 = blocks[4], let block5 = blocks[5] { candidates.append(daemonTrayUuid(block4, block5)) }
        var out: [String] = []
        for case let candidate? in candidates where candidate != zeroUuid && !out.contains(candidate) {
            out.append(candidate)
        }
        return out
    }

    /// `_extract_tray_uuid` in the SpoolBuddy daemon: hex digits of the ASCII
    /// text of blocks 4+5, else block 4 as raw hex.
    private static func daemonTrayUuid(_ block4: [UInt8], _ block5: [UInt8]) -> String? {
        let hexDigits = (block4 + block5).filter { isHexDigit($0) }
        if hexDigits.count >= 32 {
            let text = String(decoding: hexDigits.prefix(32), as: UTF8.self).uppercased()
            if text != zeroUuid { return text }
        }
        let fallback = Hex.encode(block4)
        return fallback == zeroUuid ? nil : fallback
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "a")...UInt8(ascii: "f"),
             UInt8(ascii: "A")...UInt8(ascii: "F"): true
        default: false
        }
    }

    /// NUL-terminated printable ASCII, trimmed; `nil` when empty or not text.
    private static func ascii(_ data: ArraySlice<UInt8>) -> String? {
        let text = data.prefix { $0 != 0 }
        guard !text.isEmpty, text.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        let trimmed = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func u16(_ data: [UInt8], _ offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    private static func nonzero(_ value: Int) -> Int? {
        value == 0 ? nil : value
    }
}
