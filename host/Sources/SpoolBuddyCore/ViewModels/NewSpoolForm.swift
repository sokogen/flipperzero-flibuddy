import Foundation

/// The host's New form for an unknown tag: what the tag says, editable. The
/// tag identity, colour value and core weight come along unchanged.
public struct NewSpoolForm: Equatable, Sendable {
    public var material: String
    public var subtype: String
    public var colorName: String
    public var brand: String
    /// Grams, as typed.
    public var labelWeight: String

    private var base: NewSpool

    /// Filled in from the tag (material empty when the tag has none), with the
    /// core weight of the configured catalog entry.
    public init(tag: ParsedTag, settings: Settings) {
        base = NewSpool(tag: tag, coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId)
            ?? NewSpool(
                material: "", labelWeight: tag.labelWeight ?? NewSpool.defaultLabelWeight,
                coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId,
                tagUid: tag.uid, trayUuid: tag.trayUuid, tagType: tag.kind.bambuddyTagType
            )
        material = base.material
        subtype = base.subtype ?? ""
        colorName = base.colorName ?? ""
        brand = base.brand ?? ""
        labelWeight = String(base.labelWeight)
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
