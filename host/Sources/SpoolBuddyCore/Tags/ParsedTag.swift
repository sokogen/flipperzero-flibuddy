import Foundation

/// Spool facts read from a tag dump by `TagParser`. Mirrors `ParsedTag` in
/// `tools/bridge/bambu_tag.py`; fields the tag does not carry (or carries as
/// zero) are `nil`.
public struct ParsedTag: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Bambu Lab MIFARE Classic tag.
        case bambu
        case ntag
    }

    /// Flipper screen limits for `lookup.lines`.
    public static let maxLines = 4
    public static let maxLineLength = 40

    public var kind: Kind
    /// Upper-case hex.
    public var uid: String
    /// Block 9, 32 upper-case hex chars; `nil` when missing or all zero.
    public var trayUuid: String?
    public var material: String?
    public var detailedType: String?
    public var variantId: String?
    public var materialId: String?
    /// 8 upper-case hex chars.
    public var rgba: String?
    /// Grams.
    public var labelWeight: Int?
    /// Millimetres.
    public var diameter: Double?
    public var dryingTemp: Int?
    public var dryingHours: Int?
    public var bedTemp: Int?
    public var nozzleMax: Int?
    public var nozzleMin: Int?

    public init(
        kind: Kind, uid: String, trayUuid: String? = nil,
        material: String? = nil, detailedType: String? = nil,
        variantId: String? = nil, materialId: String? = nil,
        rgba: String? = nil, labelWeight: Int? = nil, diameter: Double? = nil,
        dryingTemp: Int? = nil, dryingHours: Int? = nil, bedTemp: Int? = nil,
        nozzleMax: Int? = nil, nozzleMin: Int? = nil
    ) {
        self.kind = kind
        self.uid = uid
        self.trayUuid = trayUuid
        self.material = material
        self.detailedType = detailedType
        self.variantId = variantId
        self.materialId = materialId
        self.rgba = rgba
        self.labelWeight = labelWeight
        self.diameter = diameter
        self.dryingTemp = dryingTemp
        self.dryingHours = dryingHours
        self.bedTemp = bedTemp
        self.nozzleMax = nozzleMax
        self.nozzleMin = nozzleMin
    }

    /// Enough data to create a spool from the tag (needs `material`).
    public var hasPrefill: Bool { material != nil }

    /// Up to four lines of at most 40 characters for `lookup.lines`.
    public var displayLines: [String] {
        var lines: [String]
        switch kind {
        case .ntag:
            lines = ["NTAG", "UID \(uid)"]
        case .bambu:
            lines = [detailedType ?? material ?? "Bambu tag"]
            if let rgba { lines.append("#\(rgba)") }
            if let labelWeight { lines.append("label \(labelWeight) g") }
            if lines.count == 1 { lines.append("UID \(uid)") }
        }
        return lines.prefix(Self.maxLines).map { String($0.prefix(Self.maxLineLength)) }
    }
}
