import Foundation

/// Builds the host's replies within the protocol limits: at most four lines of
/// 40 characters, grams in 0...9999, `error` texts of 1...200 characters.
public enum LookupBuilder {
    public static let maxError = 200
    public static let maxGrams = 9999

    /// A spool Bambuddy knows; the gross default is `Spool.suggestedGross`.
    public static func found(scanId: String, spool: Spool) -> Lookup {
        Lookup(
            scanId: scanId, status: .found, spoolId: spool.id,
            lines: lines(
                spool.subtype ?? spool.material,
                spool.colorName ?? spool.rgba.map { "#\($0)" },
                "\(spool.remaining) g left of \(spool.labelWeight)",
                "core \(spool.coreWeight) g"
            ),
            defaults: Lookup.Defaults(gross: grams(spool.suggestedGross), label: grams(spool.labelWeight), core: grams(spool.coreWeight))
        )
    }

    /// A tag no spool carries. `core` is the configured catalog entry's weight.
    public static func unknown(scanId: String, tag: ParsedTag, core: Int) -> Lookup {
        Lookup(
            scanId: scanId, status: .unknown, prefill: tag.hasPrefill ? true : nil,
            lines: lines(tag.displayLines),
            defaults: Lookup.Defaults(
                label: grams(tag.labelWeight ?? NewSpool.defaultLabelWeight), core: grams(core)
            )
        )
    }

    public static func error(scanId: String, lines shown: [String], error: String) -> Lookup {
        Lookup(scanId: scanId, status: .error, lines: lines(shown), error: message(error))
    }

    public static func result(id: String, ok: Bool, lines shown: [String], error: String? = nil) -> IntentResult {
        IntentResult(id: id, ok: ok, lines: lines(shown), error: ok ? nil : message(error ?? "failed"))
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
