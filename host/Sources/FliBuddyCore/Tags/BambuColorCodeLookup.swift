extension BambuColorCode {
    private static let byKey: [String: BambuColorCode] = Dictionary(
        all.map { ("\($0.filamentId)|\($0.colorId)", $0) }, uniquingKeysWith: { first, _ in first }
    )

    /// The colour a Bambu tag names: by filament id and the colour part of
    /// the variant id (`A01-N3` -> `N3`), else by filament id and colour.
    public static func find(filamentId: String?, variantId: String?, rgba: String?) -> BambuColorCode? {
        guard let filamentId, !filamentId.isEmpty else { return nil }
        if let variantId, let dash = variantId.lastIndex(of: "-") {
            let colorId = String(variantId[variantId.index(after: dash)...])
            if let match = byKey["\(filamentId)|\(colorId)"] { return match }
        }
        guard let rgba, rgba.count >= 6 else { return nil }
        let rgb = rgba.prefix(6).uppercased()
        return all.first { $0.filamentId == filamentId && $0.rgb == rgb }
    }
}

extension ParsedTag {
    /// Bambu's code and name for the tag's colour (`11803`, `Caramel`).
    public var bambuColor: BambuColorCode? {
        BambuColorCode.find(filamentId: materialId, variantId: variantId, rgba: rgba)
    }
}
