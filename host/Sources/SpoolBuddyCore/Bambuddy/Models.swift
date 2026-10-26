import Foundation

/// A Bambuddy inventory spool (`SpoolResponse`, internal inventory mode),
/// limited to the fields the host reads. Unknown fields are ignored.
public struct Spool: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var material: String
    public var subtype: String?
    public var colorName: String?
    /// 8 hex chars; not validated, Bambuddy keeps legacy values as they are.
    public var rgba: String?
    public var brand: String?
    /// Grams of filament on a full spool.
    public var labelWeight: Int
    /// Grams of the empty spool.
    public var coreWeight: Int
    public var coreWeightCatalogId: Int?
    /// Grams used; fractional.
    public var weightUsed: Double
    /// Last gross scale weight in grams.
    public var lastScaleWeight: Int?
    public var tagUid: String?
    public var trayUuid: String?
    public var tagType: String?
    public var dataOrigin: String?
    public var note: String?

    public init(
        id: Int, material: String, subtype: String? = nil, colorName: String? = nil,
        rgba: String? = nil, brand: String? = nil, labelWeight: Int, coreWeight: Int,
        coreWeightCatalogId: Int? = nil, weightUsed: Double, lastScaleWeight: Int? = nil,
        tagUid: String? = nil, trayUuid: String? = nil, tagType: String? = nil,
        dataOrigin: String? = nil, note: String? = nil
    ) {
        self.id = id
        self.material = material
        self.subtype = subtype
        self.colorName = colorName
        self.rgba = rgba
        self.brand = brand
        self.labelWeight = labelWeight
        self.coreWeight = coreWeight
        self.coreWeightCatalogId = coreWeightCatalogId
        self.weightUsed = weightUsed
        self.lastScaleWeight = lastScaleWeight
        self.tagUid = tagUid
        self.trayUuid = trayUuid
        self.tagType = tagType
        self.dataOrigin = dataOrigin
        self.note = note
    }

    /// Grams of filament left, never negative.
    public var remaining: Int { WeightMath.remaining(label: labelWeight, used: weightUsed) }

    /// The gross weight to suggest: the last scale weight, or what the spool
    /// should weigh now (remaining + core) when it was never weighed.
    public var suggestedGross: Int { lastScaleWeight ?? remaining + coreWeight }
}

/// An empty-spool catalog entry (`GET /inventory/catalog`).
public struct CatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    /// Grams of the empty spool.
    public var weight: Int

    public init(id: Int, name: String, weight: Int) {
        self.id = id
        self.name = name
        self.weight = weight
    }
}

/// Response of `POST /spoolbuddy/scale/update-spool-weight`.
public struct WeightUpdate: Codable, Equatable, Sendable {
    /// Grams used after the update, when Bambuddy reports it.
    public var weightUsed: Double?

    public init(weightUsed: Double?) {
        self.weightUsed = weightUsed
    }
}

/// Body of `POST /inventory/spools` for a new, full item. Absent fields are
/// omitted so Bambuddy applies its own defaults.
public struct NewSpool: Encodable, Equatable, Sendable {
    public static let defaultLabelWeight = 1000
    public static let bambuBrand = "Bambu Lab"
    public static let dataOrigin = "flipper"

    public var material: String
    public var subtype: String?
    public var colorName: String?
    public var rgba: String?
    public var brand: String?
    public var labelWeight: Int
    public var coreWeight: Int
    public var coreWeightCatalogId: Int?
    public var weightUsed: Int = 0
    public var nozzleTempMin: Int?
    public var nozzleTempMax: Int?
    public var tagUid: String?
    public var trayUuid: String?
    public var tagType: String?
    public var dataOrigin: String = NewSpool.dataOrigin

    public init(
        material: String, subtype: String? = nil, colorName: String? = nil, rgba: String? = nil,
        brand: String? = nil, labelWeight: Int, coreWeight: Int, coreWeightCatalogId: Int? = nil,
        nozzleTempMin: Int? = nil, nozzleTempMax: Int? = nil,
        tagUid: String? = nil, trayUuid: String? = nil, tagType: String? = nil
    ) {
        self.material = material
        self.subtype = subtype
        self.colorName = colorName
        self.rgba = rgba
        self.brand = brand
        self.labelWeight = labelWeight
        self.coreWeight = coreWeight
        self.coreWeightCatalogId = coreWeightCatalogId
        self.nozzleTempMin = nozzleTempMin
        self.nozzleTempMax = nozzleTempMax
        self.tagUid = tagUid
        self.trayUuid = trayUuid
        self.tagType = tagType
    }

    /// A new item from a parsed tag, with the core weight of the configured
    /// catalog entry. `nil` when the tag carries no material.
    public init?(tag: ParsedTag, coreWeight: Int, coreWeightCatalogId: Int?) {
        guard let material = tag.material else { return nil }
        self.init(
            material: material,
            subtype: tag.detailedType,
            colorName: tag.rgba.map { "#\($0)" },
            rgba: tag.rgba,
            brand: tag.kind == .bambu ? Self.bambuBrand : nil,
            labelWeight: tag.labelWeight ?? Self.defaultLabelWeight,
            coreWeight: coreWeight,
            coreWeightCatalogId: coreWeightCatalogId,
            nozzleTempMin: tag.nozzleMin,
            nozzleTempMax: tag.nozzleMax,
            tagUid: tag.bambuddyTagUid,
            trayUuid: tag.trayUuid,
            tagType: tag.kind.bambuddyTagType
        )
    }
}

/// Body of `PATCH /inventory/spools/{id}/link-tag`.
public struct TagLink: Encodable, Equatable, Sendable {
    public var tagUid: String
    /// Exactly 32 hex chars when present.
    public var trayUuid: String?
    public var tagType: String?
    public var dataOrigin: String = NewSpool.dataOrigin

    public init(tagUid: String, trayUuid: String?, tagType: String?) {
        self.tagUid = tagUid
        self.trayUuid = trayUuid
        self.tagType = tagType
    }

    /// Links the tag's UID (in the form Bambuddy stores) and its tray UUID.
    public init(tag: ParsedTag) {
        self.init(tagUid: tag.bambuddyTagUid, trayUuid: tag.trayUuid, tagType: tag.kind.bambuddyTagType)
    }
}

extension ParsedTag.Kind {
    /// Bambuddy's `tag_type` value.
    public var bambuddyTagType: String {
        switch self {
        case .bambu: "bambulab"
        case .ntag: "ntag"
        }
    }
}
