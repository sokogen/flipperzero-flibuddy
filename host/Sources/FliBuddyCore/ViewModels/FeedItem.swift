import Foundation

/// One feed row as the views show it: Bambuddy's data for a known spool, the
/// tag's own data otherwise.
public struct FeedItem: Identifiable, Equatable, Sendable {
    public let id: FeedRow.ID
    public let scanId: String
    public let scannedAt: Date
    /// Upper-case hex, as read; the row leaves it to Tag details.
    public let uid: String
    /// The tag as Bambuddy keeps it (`ParsedTag.bambuddyTagUid`), and a
    /// Bambu tag's tray UUID: what the Link picker compares spools against.
    public let bambuddyTagUid: String
    public let trayUuid: String?
    /// Material and subtype, e.g. "PLA Basic" or "PETG HF"; a blank tag reads
    /// "NTAG 7-byte UID 04A2…".
    public let title: String
    /// Bambuddy's or the resolved colour name; never the hex, which the
    /// swatch shows instead.
    public let colorName: String?
    /// Bambu's colour code (`10501`): the spool's `material_number`, else
    /// the one the tag names.
    public let colorCode: String?
    /// The colour name and code, "Bambu Green · 10501"; either alone, or empty.
    public let colorLine: String
    public let swatch: Swatch?
    /// "484 g left of 1000" for a known spool, "label 1000 g" for a tag.
    public let remainingText: String
    /// The colour line: "Bambu Green · 10501 · 590 g left of 1000",
    /// "label 1000 g", or empty.
    public let detailText: String
    /// The iPad table's colour column: the colour line, with `archived`
    /// after it for an archived spool ("Jade White · archived").
    public let tableColorText: String
    /// The iPad table's remaining column: "590 g left of 1000", "label
    /// 1000 g"; empty for an archived spool, which says so in the colour column.
    public let tableRemainingText: String
    /// The watch's list title: `title`, a blank tag shortened to "NTAG 04A2…".
    public let watchTitle: String
    /// The watch's list sub line: "590 g left" for a known spool,
    /// "archived" for an archived one, "label 1000 g" for a tag with
    /// material, "Unknown tag" for a tag without.
    public let watchSubText: String
    public let statusText: String
    public let isError: Bool
    public let spoolId: Int?
    /// Filament grams the suggestion starts from: the spool's remaining
    /// grams, which right after Added are its label weight; for a tag
    /// with material and no spool, the label weight.
    public let base: Int?
    /// The spool's core weight (`core_weight`); for an Added row the
    /// settings value just sent; for a tag with material and no spool, the
    /// settings value a spool created from it gets.
    public let core: Int?
    /// The row shows the weight field, mode and Save (Enter weight, Saving…,
    /// or an error on a known spool, which keeps the value for a retry). A
    /// tag no spool carries never does: New adds it first.
    public let isEntry: Bool
    /// Enter weight: the row waits for a weight and may take focus.
    public let isWaiting: Bool
    /// A weight is on its way to Bambuddy; the entry block is disabled.
    public let isSaving: Bool
    /// A saved, marked or added row (Added to Bambuddy asks for no weight);
    /// a tap or click opens it again for a weight.
    public let isReopenable: Bool
    /// The spool was deleted from Bambuddy (here or on the Flipper).
    public let isDeleted: Bool
    /// Under the status of a save the Flipper gave up waiting for.
    public let timeoutNote: String?
    public let statusSymbol: StatusSymbol
    public let statusTint: StatusTint
    /// VoiceOver reads the header as one element, e.g.
    /// "PLA Basic, Bambu Green, 590 grams left of 1000, Enter weight".
    public let accessibilityHeader: String
    /// The lookup is done and found no spool: offer New and Link.
    public let offersUnknownActions: Bool
    /// New (or New… for a tag without material) and Link to existing… on a
    /// tag no spool carries, the prominent one first; Link alone on a spool
    /// added here that the Flipper asked to relink; none on other rows and
    /// while the tag is looked up or saved.
    public let rowActions: [RowAction]
    /// New, unless the Flipper asked to link the tag; the first of
    /// `rowActions`.
    public let prominentRowAction: RowAction?

    /// A row's actions, worded the same on every platform.
    public enum RowAction: Hashable, Sendable {
        /// Adds the spool from the tag at its label weight.
        case new
        /// The New form, for a tag without material.
        case newForm
        case link

        public var title: String {
            switch self {
            case .new: "New"
            case .newForm: "New\u{2026}"
            case .link: "Link to existing\u{2026}"
            }
        }
    }

    /// `coreWeight`: the settings' core weight, which a spool created from
    /// the tag gets; the suggestion and readout of a tag without a spool use it.
    public init(_ row: FeedRow, coreWeight: Int? = nil) {
        id = row.id
        scanId = row.scanId
        scannedAt = row.scannedAt
        uid = row.tag.uid
        bambuddyTagUid = row.tag.bambuddyTagUid
        trayUuid = row.tag.trayUuid
        let spool = row.spool
        if let spool {
            title = Self.title(material: spool.material, subtype: spool.subtype)
            watchTitle = title
            colorName = spool.colorName
            remainingText = spool.isArchived ? "archived" : "\(spool.remaining) g left of \(spool.labelWeight)"
            watchSubText = spool.isArchived ? "archived" : "\(spool.remaining) g left"
            base = spool.remaining
            core = spool.coreWeight
        } else {
            if let material = row.tag.material {
                title = Self.title(material: material, subtype: row.tag.detailedType)
                watchTitle = title
            } else if row.tag.kind == .ntag {
                title = Self.blankTitle(uid: row.tag.uid)
                watchTitle = Self.shortBlankTitle(uid: row.tag.uid)
            } else {
                title = "Bambu tag"
                watchTitle = title
            }
            colorName = row.colorName
            remainingText = row.tag.labelWeight.map { "label \($0) g" } ?? ""
            watchSubText = row.tag.hasPrefill ? remainingText : "Unknown tag"
            base = row.tag.hasPrefill ? row.tag.labelWeight ?? NewSpool.defaultLabelWeight : nil
            core = row.tag.hasPrefill ? coreWeight : nil
        }
        colorCode = Self.colorCode(row)
        colorLine = [colorName, colorCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        detailText = [colorLine, remainingText].filter { !$0.isEmpty }.joined(separator: " · ")
        let archived = spool?.isArchived ?? false
        tableColorText = archived ? detailText : colorLine
        tableRemainingText = archived ? "" : remainingText
        swatch = (spool?.rgba ?? row.tag.rgba).flatMap(Swatch.init(rgba:))
        statusText = Self.statusText(row)
        isError = if case .error = row.status { true } else { false }
        spoolId = spool?.id
        offersUnknownActions = spool == nil && row.status != .scanned
        // The Flipper asked to relink the spool it just added: Link, no entry.
        let relinks = Self.relinksAddedSpool(row)
        isEntry = spool != nil && !relinks && Self.isEntryState(row.status)
        isWaiting = spool != nil && !relinks && row.status == .awaitingWeight
        isSaving = row.status == .saving || row.status == .updating
        isReopenable = spool != nil && !relinks && row.status.isReopenable
        isDeleted = row.status == .deleted
        rowActions = if isSaving {
            []
        } else if offersUnknownActions {
            Self.unknownActions(row)
        } else {
            relinks ? [.link] : []
        }
        prominentRowAction = rowActions.first
        timeoutNote = row.status == .savedAfterTimeout ? Self.timeoutNoteText : nil
        (statusSymbol, statusTint) = Self.statusLook(row)
        accessibilityHeader = Self.accessibilityHeader(
            title: title, colorName: colorName, spool: spool,
            labelWeight: row.tag.labelWeight, status: statusText
        )
    }

    public static let timeoutNoteText = "Flipper timed out after 10 s and showed an error; the save went through."

    /// The weight field's pre-filled value for `mode`: `base`, plus the core in gross.
    public func suggestion(mode: Intent.WeightMode) -> Int? {
        base.map { $0 + (mode == .gross ? max(0, core ?? 0) : 0) }
    }

    /// The line under the weight field: what a save of `value` would record.
    public struct Readout: Equatable, Sendable {
        public var text: String
        /// Red: the gross value is below the core weight.
        public var isError: Bool

        /// The iPad table's readout under the status, without the gross
        /// sum: "Saves 590 g left".
        public var short: String {
            text.components(separatedBy: " \u{00B7} ").first ?? text
        }
    }

    /// "Saves 590 g left · 832 − 242 g core" in gross, "Saves 590 g left" in
    /// net, "Type the scale reading" without a value, "Below the core weight
    /// (242 g)" when the gross value is lighter than the core.
    public static func readout(value: Int?, mode: Intent.WeightMode, core: Int?) -> Readout {
        guard let value else { return Readout(text: "Type the scale reading", isError: false) }
        guard mode == .gross else { return Readout(text: "Saves \(value) g left", isError: false) }
        let core = max(0, core ?? 0)
        let net = value - core
        guard net >= 0 else { return Readout(text: "Below the core weight (\(core) g)", isError: true) }
        return Readout(text: "Saves \(net) g left · \(value) \u{2212} \(core) g core", isError: false)
    }

    public func readout(value: Int?, mode: Intent.WeightMode) -> Readout {
        Self.readout(value: value, mode: mode, core: core)
    }

    /// Bambu's colour code for the row: the spool's `material_number`, else
    /// the code the tag's filament and variant ids name.
    public static func colorCode(_ row: FeedRow) -> String? {
        if let number = row.spool?.materialNumber, !number.isEmpty { return number }
        return row.tag.bambuColor?.code
    }

    /// A tag without material, by UID length and the first two bytes:
    /// "NTAG 7-byte UID 04A2…"; the full UID is in Tag details.
    public static func blankTitle(uid: String) -> String {
        let prefix = uid.count > 4 ? "\(uid.prefix(4))\u{2026}" : uid
        return "NTAG \(uid.count / 2)-byte UID \(prefix)"
    }

    /// The watch's shorter blank title: "NTAG 04A2…".
    public static func shortBlankTitle(uid: String) -> String {
        uid.count > 4 ? "NTAG \(uid.prefix(4))\u{2026}" : "NTAG \(uid)"
    }

    /// The weight field's VoiceOver label.
    public static func weightFieldLabel(mode: Intent.WeightMode) -> String {
        mode == .gross ? "Gross weight, grams" : "Net weight, grams"
    }

    /// The word inside the iPhone's weight field, right of the value.
    public static func modeWord(_ mode: Intent.WeightMode) -> String {
        mode == .gross ? "gross" : "net"
    }

    /// "PLA" + "PLA Basic" reads "PLA Basic"; "PETG" + "HF" reads "PETG HF".
    public static func title(material: String, subtype: String?) -> String {
        guard let subtype, !subtype.isEmpty else { return material }
        return subtype.lowercased().hasPrefix(material.lowercased()) ? subtype : "\(material) \(subtype)"
    }

    static func isEntryState(_ status: FeedRow.Status) -> Bool {
        switch status {
        case .awaitingWeight, .saving, .updating, .error: true
        case .scanned, .unknown, .saved, .savedAfterTimeout, .created, .markedNew, .markedEmpty, .deleted: false
        }
    }

    /// A spool this session added (New, or a create on scan) that the
    /// Flipper asked to relink (`link_on_host`, Relink on host): Link deletes
    /// it first, as Bambuddy refuses a tag an active spool carries. Another
    /// known spool cannot be relinked from the host.
    static func relinksAddedSpool(_ row: FeedRow) -> Bool {
        guard let spool = row.spool, row.request == .link else { return false }
        return row.createdSpoolId == spool.id
    }

    /// New (from the tag, or the form for a tag without material) and Link,
    /// the action the Flipper asked for first: New unless it asked to link.
    static func unknownActions(_ row: FeedRow) -> [RowAction] {
        let new: RowAction = row.tag.hasPrefill ? .new : .newForm
        return row.request == .link ? [.link, new] : [new, .link]
    }

    static func statusText(_ row: FeedRow) -> String {
        switch row.status {
        case .scanned: return "Looking up"
        // `where` binds to one pattern only, so each state has its own case.
        case .awaitingWeight where relinksAddedSpool(row), .created where relinksAddedSpool(row):
            return requestText(.link)
        case .awaitingWeight: return "Enter weight"
        case .unknown(let prefill):
            if let request = row.request { return requestText(request) }
            return prefill ? "Not in Bambuddy" : "Not in Bambuddy; tag has no material"
        case .saving: return "Saving\u{2026}"
        case .saved, .savedAfterTimeout:
            let saved = row.spool.map { "Saved \($0.remaining) g left" } ?? "Saved"
            return row.savedBy.map { "\(saved) · \(savedByText($0))" } ?? saved
        case .created: return "Added to Bambuddy"
        case .updating: return "Updating\u{2026}"
        case .markedNew:
            let marked = row.spool.map { "Marked as new · \($0.remaining) g left" } ?? "Marked as new"
            return row.savedBy.map { "\(marked) · \(savedByText($0))" } ?? marked
        case .markedEmpty: return bySide(row, "Marked as empty · archived")
        case .deleted: return bySide(row, "Deleted from Bambuddy")
        case .error(let message): return "Error: \(message)"
        }
    }

    static func statusLook(_ row: FeedRow) -> (StatusSymbol, StatusTint) {
        switch row.status {
        case .scanned, .saving, .updating: (.progress, .secondary)
        case .awaitingWeight where relinksAddedSpool(row), .created where relinksAddedSpool(row):
            (.symbol("dot.radiowaves.left.and.right"), .blue)
        case .awaitingWeight: (.symbol("scalemass"), .blue)
        case .unknown: row.request == nil
            ? (.symbol("questionmark.circle"), .secondary)
            : (.symbol("dot.radiowaves.left.and.right"), .blue)
        case .saved, .savedAfterTimeout: (.symbol("checkmark.circle.fill"), .green)
        case .created: (.symbol("plus.circle.fill"), .green)
        case .markedNew: (.symbol("arrow.counterclockwise.circle.fill"), .green)
        case .markedEmpty: (.symbol("archivebox"), .secondary)
        case .deleted: (.symbol("trash"), .secondary)
        case .error: (.symbol("exclamationmark.triangle.fill"), .red)
        }
    }

    /// `phrase · by host` / `· by Flipper`, or the phrase alone.
    private static func bySide(_ row: FeedRow, _ phrase: String) -> String {
        row.savedBy.map { "\(phrase) · \(savedByText($0))" } ?? phrase
    }

    static func savedByText(_ side: FeedRow.Side) -> String {
        side == .host ? "by host" : "by Flipper"
    }

    static func requestText(_ request: FeedRow.HostRequest) -> String {
        request == .create ? "Flipper asks to create it here" : "Flipper asks to link it here"
    }

    /// Title, colour name, what is left (or the label weight, or "archived")
    /// and the status, grams spelled out; never the hex of an unnamed colour.
    static func accessibilityHeader(
        title: String, colorName: String?, spool: Spool?, labelWeight: Int?, status: String
    ) -> String {
        let amount: String? = if let spool, spool.isArchived {
            "archived"
        } else if let spool {
            "\(spool.remaining) grams left of \(spool.labelWeight)"
        } else {
            labelWeight.map { "label \($0) grams" }
        }
        return [title, colorName, amount, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// What precedes a status phrase: a spinner while something runs, else an SF Symbol.
public enum StatusSymbol: Equatable, Sendable {
    case progress
    case symbol(String)
}

/// The colour that reinforces a status phrase; it never carries meaning alone.
public enum StatusTint: Equatable, Sendable {
    case secondary
    case blue
    case green
    case orange
    case red
    case gray
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

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The colour as Bambuddy stores it: 8 upper-case hex digits, RRGGBBAA.
    public var rgba: String {
        [red, green, blue, alpha]
            .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
    }
}
