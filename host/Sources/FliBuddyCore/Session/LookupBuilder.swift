import Foundation

/// Builds the host's replies within the protocol limits: at most four lines of
/// 40 characters, grams in 0...9999, `error` texts of 1...200 characters, and
/// `spool` / `tag_info` names of 1...40 characters with `RRGGBBAA` colours.
/// Bambuddy's data is not trusted to fit: a reply that broke the schema could
/// not be sent, and the link would drop.
public enum LookupBuilder {
    public static let maxError = 200
    public static let maxGrams = 9999

    /// A spool Bambuddy knows; the gross default is `Spool.suggestedGross`.
    /// `created`: the spool was created from this scan (autosave).
    public static func found(scanId: String, spool: Spool, created: Bool = false) -> Lookup {
        Lookup(
            scanId: scanId, status: .found, spoolId: spool.id, spool: summary(spool), created: created,
            lines: lines(
                FeedItem.title(material: spool.material, subtype: spool.subtype),
                spool.colorName ?? spool.rgba.map { "#\($0)" },
                spool.isArchived ? "archived" : "\(spool.remaining) g left of \(spool.labelWeight)",
                "core \(spool.coreWeight) g"
            ),
            defaults: Lookup.Defaults(gross: grams(spool.suggestedGross), label: grams(spool.labelWeight), core: grams(spool.coreWeight))
        )
    }

    /// A tag no spool carries. `core` is the configured catalog entry's weight.
    /// `colorName` is Bambuddy's name for the tag's colour, when known.
    public static func unknown(scanId: String, tag: ParsedTag, core: Int, colorName: String? = nil) -> Lookup {
        Lookup(
            scanId: scanId, status: .unknown, prefill: tag.hasPrefill ? true : nil,
            tagInfo: tagInfo(tag, colorName: colorName),
            lines: lines(tag.displayLines),
            defaults: Lookup.Defaults(
                label: grams(tag.labelWeight ?? NewSpool.defaultLabelWeight), core: grams(core)
            )
        )
    }

    public static func error(scanId: String, lines shown: [String], error: String) -> Lookup {
        Lookup(scanId: scanId, status: .error, lines: lines(shown), error: message(error))
    }

    /// `spool` goes out with a successful result only.
    public static func result(
        id: String, ok: Bool, lines shown: [String], error: String? = nil, spool: Spool? = nil
    ) -> IntentResult {
        IntentResult(
            id: id, ok: ok, lines: lines(shown), spool: ok ? spool.flatMap(summary) : nil,
            error: ok ? nil : message(error ?? "failed")
        )
    }

    /// The wire `spool` object; `nil` for a spool without a material to show.
    public static func summary(_ spool: Spool) -> SpoolSummary? {
        guard spool.id >= 1, let material = name(spool.material) else { return nil }
        return SpoolSummary(
            id: spool.id, material: material, subtype: name(spool.subtype), colorName: name(spool.colorName),
            rgba: rgba(spool.rgba), remaining: grams(spool.remaining), label: grams(spool.labelWeight),
            core: grams(spool.coreWeight), archived: spool.isArchived
        )
    }

    /// The wire `tag_info` object; `nil` for a tag without spool data.
    public static func tagInfo(_ tag: ParsedTag, colorName: String? = nil) -> TagInfo? {
        let info = TagInfo(
            material: name(tag.material), subtype: name(tag.bambuddySubtype), rgba: rgba(tag.rgba),
            label: tag.labelWeight.map(grams), colorName: name(colorName),
            code: tag.bambuColor.map { clip($0.code, TagInfo.maxCode) },
            filamentId: name(tag.materialId).map { clip($0, TagInfo.maxCode) },
            diameter: tag.diameter.flatMap(diameter), nozzleMin: tag.nozzleMin.flatMap(temperature),
            nozzleMax: tag.nozzleMax.flatMap(temperature)
        )
        return info.isEmpty ? nil : info
    }

    /// `1.75` for 1.75 mm; `nil` for a value the wire cannot carry.
    static func diameter(_ millimetres: Double) -> String? {
        guard millimetres > 0, millimetres < 100 else { return nil }
        return String(format: "%.2f", millimetres)
    }

    static func temperature(_ celsius: Int) -> Int? {
        (1...999).contains(celsius) ? celsius : nil
    }

    /// Non-empty lines, at most four, each cut to 40 characters.
    public static func lines(_ candidates: String?...) -> [String] {
        lines(candidates.compactMap { $0 })
    }

    public static func lines(_ candidates: [String]) -> [String] {
        candidates.filter { !$0.isEmpty }.prefix(Field.maxLines).map { clip($0, Field.maxLineLength) }
    }

    static func grams(_ value: Int) -> Int {
        min(maxGrams, max(0, value))
    }

    /// A name cut to 40 characters; `nil` when empty.
    static func name(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return clip(text, Field.maxName)
    }

    /// Upper-case `RRGGBBAA`; anything else is left out.
    static func rgba(_ text: String?) -> String? {
        guard let upper = text?.uppercased(), Field.isRGBA(upper) else { return nil }
        return upper
    }

    /// An `error` field: never empty, at most 200 characters.
    static func message(_ text: String) -> String {
        text.isEmpty ? "failed" : clip(text, maxError)
    }

    /// The schema counts code points, so cut by Unicode scalars.
    private static func clip(_ text: String, _ limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(limit))
        return String(scalars)
    }
}
