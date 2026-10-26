import Foundation

/// Turns a `TagDump` into a `ParsedTag`. Pure functions, no I/O; mirrors
/// `tools/bridge/bambu_tag.py` byte for byte.
///
/// Bambu block layout (public Bambu RFID tag guide, confirmed on real dumps in
/// Phase 0):
/// - block 1: material variant id (bytes 0-7) + material id (8-15), ASCII
/// - block 2: filament type, ASCII (`PLA`)
/// - block 4: detailed type, ASCII (`PLA Basic`)
/// - block 5: RGBA (0-3), label weight uint16 LE grams (4-5), diameter float32 LE (8-11)
/// - block 6: uint16 LE drying temp, drying hours, bed type, bed temp, nozzle max, nozzle min
/// - block 9: tray UUID, raw hex. Phase 0 matched it byte for byte with the
///   `tray_uuid` an AMS reported to Bambuddy; all zero means none.
public enum TagParser {
    public static func parse(_ dump: TagDump) -> ParsedTag {
        let uid = dump.uid.uppercased()
        guard dump.type == .mfc else { return ParsedTag(kind: .ntag, uid: uid) }

        let missing = Set(dump.missing)
        let blocks = dump.blocks.filter { !missing.contains($0.key / 4) && $0.value.count == 16 }
        var tag = ParsedTag(kind: .bambu, uid: uid, trayUuid: trayUuid(blocks))

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

    /// Block 9 as upper-case hex; `nil` when missing or all zero.
    static func trayUuid(_ blocks: [Int: [UInt8]]) -> String? {
        guard let block9 = blocks[9], block9.contains(where: { $0 != 0 }) else { return nil }
        return Hex.encode(block9)
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
