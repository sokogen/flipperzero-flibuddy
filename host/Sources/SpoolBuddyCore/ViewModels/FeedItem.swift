import Foundation

/// One feed row as the views show it: Bambuddy's data for a known spool, the
/// tag's own data otherwise.
public struct FeedItem: Identifiable, Equatable, Sendable {
    public let id: FeedRow.ID
    public let scanId: String
    public let scannedAt: Date
    public let uid: String
    /// Material and subtype, e.g. "PLA Basic" or "PETG HF".
    public let title: String
    public let colorName: String?
    public let swatch: Swatch?
    /// "484 g left of 1000" for a known spool, "label 1000 g" for a tag.
    public let remainingText: String
    public let statusText: String
    public let isError: Bool
    /// "by Flipper" / "by host" once a weight was saved or the item created.
    public let savedByText: String?
    /// What the Flipper asked the host to do with the tag, if anything.
    public let requestText: String?
    public let spoolId: Int?
    /// Grams the weight field suggests: the last scale weight, or what the
    /// spool should weigh now.
    public let suggestedGross: Int?
    public let core: Int?
    /// A spool is known, so a weight can be saved.
    public let canWeigh: Bool
    /// The lookup is done and found no spool: offer New and Link.
    public let offersUnknownActions: Bool
    /// The tag carries a material, so the New form starts filled in.
    public let hasPrefill: Bool

    public init(_ row: FeedRow) {
        id = row.id
        scanId = row.scanId
        scannedAt = row.scannedAt
        uid = row.tag.uid
        let spool = row.spool
        if let spool {
            title = Self.title(material: spool.material, subtype: spool.subtype)
            colorName = spool.colorName ?? spool.rgba.map { "#\($0)" }
            remainingText = "\(spool.remaining) g left of \(spool.labelWeight)"
            suggestedGross = spool.suggestedGross
            core = spool.coreWeight
        } else {
            if let material = row.tag.material {
                title = Self.title(material: material, subtype: row.tag.detailedType)
            } else {
                title = row.tag.kind == .ntag ? "NTAG" : "Bambu tag"
            }
            colorName = row.colorName ?? row.tag.rgba.map { "#\($0)" }
            remainingText = row.tag.labelWeight.map { "label \($0) g" } ?? ""
            suggestedGross = nil
            core = nil
        }
        swatch = (spool?.rgba ?? row.tag.rgba).flatMap(Swatch.init(rgba:))
        statusText = Self.statusText(row)
        isError = if case .error = row.status { true } else { false }
        savedByText = row.savedBy.map { $0 == .host ? "by host" : "by Flipper" }
        requestText = row.request.map { $0 == .create ? "Flipper asks to create it here" : "Flipper asks to link it here" }
        spoolId = spool?.id
        canWeigh = spool != nil
        offersUnknownActions = spool == nil && row.status != .scanned
        hasPrefill = row.tag.hasPrefill
    }

    /// The weight field's hint for `mode`.
    public func suggested(_ mode: Intent.WeightMode) -> Int? {
        guard let suggestedGross else { return nil }
        return mode == .gross ? suggestedGross : max(0, suggestedGross - (core ?? 0))
    }

    /// "PLA" + "PLA Basic" reads "PLA Basic"; "PETG" + "HF" reads "PETG HF".
    public static func title(material: String, subtype: String?) -> String {
        guard let subtype, !subtype.isEmpty else { return material }
        return subtype.lowercased().hasPrefix(material.lowercased()) ? subtype : "\(material) \(subtype)"
    }

    static func statusText(_ row: FeedRow) -> String {
        switch row.status {
        case .scanned: "Looking up"
        case .awaitingWeight: "Enter weight"
        case .unknown(prefill: true): "Not in Bambuddy"
        case .unknown(prefill: false): "Not in Bambuddy; tag has no material"
        case .saved:
            if let weight = row.weight { "Saved \(weight.grams) g \(weight.mode.rawValue)" } else { "Saved" }
        case .created: "Created in Bambuddy"
        case .error(let message): "Error: \(message)"
        }
    }
}

/// A filament colour from 8 hex digits (RRGGBBAA), components in 0...1.
public struct Swatch: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init?(rgba: String) {
        let hex = rgba.hasPrefix("#") ? String(rgba.dropFirst()) : rgba
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else { return nil }
        red = Double((value >> 24) & 0xFF) / 255
        green = Double((value >> 16) & 0xFF) / 255
        blue = Double((value >> 8) & 0xFF) / 255
        alpha = Double(value & 0xFF) / 255
    }
}
