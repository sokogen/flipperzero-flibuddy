import Foundation

/// The host's New form for an unknown tag: what the tag says, editable. The
/// tag identity, colour value and core weight come along unchanged.
public struct NewSpoolForm: Equatable, Sendable {
    public static let title = "New spool"
    public static let footer = "Material is required. The row asks for a weight once Bambuddy has created the spool."
    /// The iPhone form's footer.
    public static let phoneFooter = "FliBuddy creates the spool in Bambuddy, then asks for its weight."
    /// The Material menu; "Choose…" is the empty material.
    public static let materials = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA"]

    /// Under the title: "NTAG 7-byte · 04112233445566".
    public let subtitle: String
    public var material: String
    public var subtype: String
    public var colorName: String
    public var brand: String
    /// The colour value, from the tag when it has one; the iPhone form has a
    /// colour picker for it.
    public var swatch: Swatch?
    /// Grams, digits only, at most four.
    public var labelWeight: String {
        didSet { labelWeight = FeedViewModel.sanitizeWeight(labelWeight) }
    }

    private var base: NewSpool

    /// Filled in from the tag (material empty when the tag has none), with the
    /// configured core weight and Bambuddy's name for the colour, if any.
    public init(tag: ParsedTag, settings: Settings, colorName: String? = nil) {
        base = NewSpool(
            tag: tag, coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId, colorName: colorName
        )
            ?? NewSpool(
                material: "", labelWeight: tag.labelWeight ?? NewSpool.defaultLabelWeight,
                coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId,
                tagUid: tag.bambuddyTagUid, trayUuid: tag.trayUuid, tagType: tag.kind.bambuddyTagType
            )
        subtitle = switch tag.kind {
        case .ntag: "NTAG \(tag.uid.count / 2)-byte · \(tag.uid)"
        case .bambu: "Bambu tag · \(tag.uid)"
        }
        material = base.material
        subtype = base.subtype ?? ""
        self.colorName = base.colorName ?? ""
        brand = base.brand ?? ""
        swatch = base.rgba.flatMap(Swatch.init(rgba:))
        labelWeight = String(base.labelWeight)
    }

    /// The menu's materials, plus the current one when it is not in the list
    /// (a tag's own material), so the menu always shows the selection.
    public var materialOptions: [String] {
        material.isEmpty || Self.materials.contains(material) ? Self.materials : Self.materials + [material]
    }

    /// Create is enabled.
    public var canCreate: Bool {
        newSpool != nil
    }

    /// The item to create; `nil` without a material or with a label weight
    /// outside 1...9999 g. Bambuddy never gets an item without material.
    public var newSpool: NewSpool? {
        let material = Self.trimmed(material)
        guard !material.isEmpty, let grams = Int(Self.trimmed(labelWeight)), (1...LookupBuilder.maxGrams).contains(grams)
        else { return nil }
        var spool = base
        spool.material = material
        spool.subtype = Self.optional(subtype)
        spool.colorName = Self.optional(colorName)
        spool.brand = Self.optional(brand)
        // An unchanged colour keeps the tag's text as read.
        if swatch != base.rgba.flatMap(Swatch.init(rgba:)) { spool.rgba = swatch?.rgba }
        spool.labelWeight = grams
        return spool
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optional(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}
