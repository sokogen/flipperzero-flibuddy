import Foundation

/// Bambuddy's colour names (`GET /inventory/colors/map`): `colors` by hex,
/// `byMaterial` by `"<material>|<hex>"`. Keys are lower-case hex without `#`
/// and without alpha, e.g. `"ff9016"` and `"pla matte|ffffff"`.
public struct ColorMap: Decodable, Equatable, Sendable {
    public var colors: [String: String]
    public var byMaterial: [String: String]

    public init(colors: [String: String], byMaterial: [String: String]) {
        self.colors = colors
        self.byMaterial = byMaterial
    }

    private enum CodingKeys: String, CodingKey {
        case colors
        case byMaterial = "by_material"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colors = try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        byMaterial = try container.decodeIfPresent([String: String].self, forKey: .byMaterial) ?? [:]
    }
}

/// Names a tag's colour the way an AMS-added spool is named: the material
/// table first, then the colour table; `nil` when neither knows the colour.
public struct ColorNameResolver: Equatable, Sendable {
    public static let empty = ColorNameResolver(ColorMap(colors: [:], byMaterial: [:]))

    private let colors: [String: String]
    private let byMaterial: [String: String]

    public init(_ map: ColorMap) {
        colors = Self.lowercasedKeys(map.colors)
        byMaterial = Self.lowercasedKeys(map.byMaterial)
    }

    /// `rgba` is 8 hex digits (6 accepted, `#` ignored); the alpha byte never matters.
    public func name(rgba: String?, detailedType: String?) -> String? {
        guard let hex = Self.hex6(rgba) else { return nil }
        if let detailedType, let name = byMaterial["\(detailedType.lowercased())|\(hex)"] { return name }
        return colors[hex]
    }

    public func name(for tag: ParsedTag) -> String? {
        name(rgba: tag.rgba, detailedType: tag.detailedType)
    }

    private static func hex6(_ rgba: String?) -> String? {
        guard var hex = rgba else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.prefix(6).lowercased()
    }

    private static func lowercasedKeys(_ table: [String: String]) -> [String: String] {
        Dictionary(table.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
