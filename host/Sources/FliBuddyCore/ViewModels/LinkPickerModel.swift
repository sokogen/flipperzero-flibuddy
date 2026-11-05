import Foundation

/// The Link to existing spool sheet for one row: the spools matching the
/// filter, how each reads, and what linking the pick would do. The view keeps
/// the query, `FeedViewModel` the pick, and the view builds this from them.
public struct LinkPickerModel: Equatable, Sendable {
    public static let title = "Link to existing spool"
    public static let placeholder = "material, color, brand or note"
    /// The iPhone sheet's title and search prompt.
    public static let phoneTitle = "Link to existing"
    public static let phonePlaceholder = "Material, color, brand or note"
    /// The iPhone alert's confirming button.
    public static let moveButton = "Move link"

    /// The iPhone's question before a link moves away from another tag.
    public struct MoveAlert: Equatable, Sendable {
        public let title: String
        public let message: String
    }

    /// The row's UID as shown under its title.
    public let uid: String
    public let query: String
    public let selection: Spool.ID?
    /// Every candidate except the row's own spool, filtered by the query.
    public let matches: [Spool]
    private let spoolCount: Int
    private let tagUid: String
    private let trayUuid: String?

    public init(item: FeedItem, spools: [Spool], query: String = "", selection: Spool.ID? = nil) {
        uid = item.uid
        tagUid = item.bambuddyTagUid
        trayUuid = item.trayUuid
        self.query = query
        self.selection = selection
        let others = spools.filter { $0.id != item.spoolId }
        spoolCount = others.count
        matches = Self.filter(others, query: query)
    }

    /// "Tag 04A2…" under the title.
    public var tagLine: String { "Tag \(uid)" }

    /// Spools where every word of `query` appears in the material, subtype,
    /// colour, brand or note, ignoring case and diacritics.
    public static func filter(_ spools: [Spool], query: String) -> [Spool] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return spools }
        return spools.filter { spool in
            let fields = [spool.material, spool.subtype, spool.colorName, spool.brand, spool.note].compactMap { $0 }
            return words.allSatisfy { word in
                fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }

    /// "Charcoal · Bambu Lab · 1000 g left", without the parts the spool lacks.
    public static func subtitle(_ spool: Spool) -> String {
        [spool.colorName, spool.brand, "\(spool.remaining) g left"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// "Tag 04AABBCCDDEEFF" for a spool that already carries a tag.
    public static func badge(_ spool: Spool) -> String? {
        tag(of: spool).map { "Tag \($0)" }
    }

    /// Shown instead of the list when nothing matches.
    public var emptyText: String? {
        guard matches.isEmpty else { return nil }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty || spoolCount == 0 { return "No spools in Bambuddy." }
        return "No spools match \u{201C}\(words)\u{201D}."
    }

    /// The pick, while the filter shows it.
    public var selectedSpool: Spool? {
        matches.first { $0.id == selection }
    }

    /// The pick carries a different tag, which the link moves to this one.
    public var warning: String? {
        movedLink.map { "\($0). Linking moves it to \(uid)." }
    }

    /// The iPad's inline form of the warning, under the list; ✓ then moves the link.
    public var padWarning: String? {
        movedLink.map { "\($0). Saving moves the link to \(uid)." }
    }

    /// The iPhone asks before Link moves another tag's link here.
    public var moveAlert: MoveAlert? {
        movedLink.map {
            MoveAlert(title: $0, message: "Move the link to \(uid)? The old tag will no longer identify this spool.")
        }
    }

    /// "<title> <colour> is linked to tag <tag>" when the pick carries a
    /// different tag.
    private var movedLink: String? {
        guard let spool = selectedSpool, let other = Self.tag(of: spool), !carriesThisTag(spool) else { return nil }
        let name = [FeedItem.title(material: spool.material, subtype: spool.subtype), spool.colorName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(name) is linked to tag \(other)"
    }

    public var linkTitle: String {
        warning == nil ? "Link" : Self.moveButton
    }

    /// Link needs a pick the filter still shows.
    public var canLink: Bool {
        selectedSpool != nil
    }

    private static func tag(of spool: Spool) -> String? {
        [spool.tagUid, spool.trayUuid].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Bambuddy keeps a Bambu tag's UID in the AMS form; see
    /// `ParsedTag.bambuddyTagUid`.
    private func carriesThisTag(_ spool: Spool) -> Bool {
        if let tag = spool.tagUid, tag.uppercased() == tagUid { return true }
        if let tray = spool.trayUuid, let trayUuid, tray.uppercased() == trayUuid.uppercased() { return true }
        return false
    }
}
