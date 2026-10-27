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
    /// grams, which right after Created are its label weight; for a tag
    /// with material and no spool, the label weight.
    public let base: Int?
    /// The spool's core weight (`core_weight`); for a Created row the
    /// settings value just sent; for a tag with material and no spool, the
    /// settings value a spool created from it gets.
    public let core: Int?
    /// The row shows the weight field, mode and Save (Enter weight, Saving…,
    /// or an error on a known spool, which keeps the value for a retry). A
    /// New spool or a Created row shows it only once revealed (`revealsEntry`).
    public let isEntry: Bool
    /// A New spool (a tag with material and no spool, the Flipper's Auto-save
    /// new off) or a Created row: the weight is optional, and the entry
    /// shows only after Save with weight… / Set weight… reveals it.
    public let revealsEntry: Bool
    /// Save creates the spool before it records the weight: a New spool's
    /// revealed entry.
    public let savesNewSpool: Bool
    /// Enter weight, or a revealed New spool or Created entry: the row waits
    /// for a weight and may take focus.
    public let isWaiting: Bool
    /// A weight is on its way to Bambuddy; the entry block is disabled.
    public let isSaving: Bool
    /// A saved row; a click opens it again for a re-weigh.
    public let isReopenable: Bool
    /// Created in Bambuddy and not weighed yet (also after a failed save or
    /// delete): Link to existing… moves the tag and deletes this spool.
    public let offersLinkExisting: Bool
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
    /// What New does on an unknown row.
    public let newAction: NewAction
    /// The action the Flipper asked for, shown prominent.
    public let prominentAction: UnknownAction?
    /// What the row offers besides the weight entry, the prominent one
    /// first; none while a weight or an update is on its way.
    public let rowActions: [RowAction]
    /// Save as new on a New spool, Set weight… on a Created row, else the
    /// action the Flipper asked for; none while the entry is shown.
    public let prominentRowAction: RowAction?

    /// New on an unknown row: the form for a tag without material, one step
    /// from the tag's own data otherwise (the retry after a failed create on
    /// scan).
    public enum NewAction: Equatable, Sendable {
        case form
        case fromTag

        public var title: String {
            self == .form ? "New\u{2026}" : "New"
        }
    }

    public enum UnknownAction: Equatable, Sendable {
        case new
        case link
    }

    /// A row's actions, worded the same on every platform.
    public enum RowAction: Equatable, Sendable {
        /// Creates the spool from the tag, full.
        case saveAsNew
        /// Reveals the entry; its Save creates the spool and records the weight.
        case saveWithWeight
        /// Reveals a Created row's entry; its Save records the weight.
        case setWeight
        /// The New form, for a tag without material.
        case newForm
        case link

        public var title: String {
            switch self {
            case .saveAsNew: "Save as new"
            case .saveWithWeight: "Save with weight\u{2026}"
            case .setWeight: "Set weight\u{2026}"
            case .newForm: "New\u{2026}"
            case .link: "Link to existing\u{2026}"
            }
        }

        /// The watch's shorter button titles.
        public var watchTitle: String {
            switch self {
            case .saveWithWeight: "With weight"
            case .setWeight: "Set weight"
            case .saveAsNew, .newForm, .link: title
            }
        }
    }

    /// `coreWeight`: the settings' core weight, which a spool created from
    /// the tag gets; the suggestion and readout of a tag without a spool use it.
    /// `entryRevealed`: Save with weight… / Set weight… showed the entry of
    /// a row that `revealsEntry`.
    public init(_ row: FeedRow, coreWeight: Int? = nil, entryRevealed: Bool = false) {
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
        newAction = row.tag.hasPrefill ? .fromTag : .form
        prominentAction = row.request.map { $0 == .create ? .new : .link }
        let isNewSpool = Self.isNewSpool(row)
        revealsEntry = Self.revealsEntry(row)
        let revealed = revealsEntry && entryRevealed
        savesNewSpool = isNewSpool && revealed
        isEntry = revealsEntry ? revealed : spool != nil && Self.isEntryState(row.status)
        isWaiting = (spool != nil && row.status == .awaitingWeight)
            || (revealed && (row.status == .created || row.status.isUnknown))
        isSaving = row.status == .saving || row.status == .updating
        isReopenable = spool != nil && [.saved, .savedAfterTimeout, .markedNew, .markedEmpty].contains(row.status)
        offersLinkExisting = spool != nil && row.createdSpoolId == spool?.id
            && (row.status == .created || isError)
        isDeleted = row.status == .deleted
        (rowActions, prominentRowAction) = Self.rowActions(
            row, isNewSpool: isNewSpool, revealed: revealed, offersUnknown: offersUnknownActions,
            offersLink: offersLinkExisting, isSaving: isSaving
        )
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

    /// "Saves 590 g left · 915 − 325 g core" in gross, "Saves 590 g left" in
    /// net, "Type the scale reading" without a value, "Below the core weight
    /// (325 g)" when the gross value is lighter than the core.
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

    /// The iPhone card's full-width button over its capsules: the prominent
    /// action of a New spool or Created card.
    public var cardLeadAction: RowAction? {
        revealsEntry ? prominentRowAction : nil
    }

    /// The iPhone card's 44 pt capsules: under the lead button, or under
    /// Save on a revealed entry, or the row's actions as two equal capsules.
    public var cardCapsuleActions: [RowAction] {
        rowActions.filter { $0 != cardLeadAction }
    }

    /// The prominent capsule: the first, on a row with neither a lead button
    /// nor an entry (New…, or the action the Flipper asked for).
    public var cardProminentCapsule: RowAction? {
        cardLeadAction == nil && !isEntry ? cardCapsuleActions.first : nil
    }

    /// The iPad table's footnote buttons under the status: Link to existing…
    /// of a New spool or Created row, which has no room beside the pills or
    /// the entry.
    public var tableStatusActions: [RowAction] {
        revealsEntry || isEntry ? rowActions.filter { $0 == .link } : []
    }

    /// The iPad table's pills in the trailing column, unless the entry is there.
    public var tableTrailingActions: [RowAction] {
        isEntry ? [] : rowActions.filter { !tableStatusActions.contains($0) }
    }

    /// The tinted pill: the prominent action, else the first pill; none when
    /// the prominent one sits under the status.
    public var tableProminentAction: RowAction? {
        guard let prominent = prominentRowAction else { return tableTrailingActions.first }
        return tableTrailingActions.contains(prominent) ? prominent : nil
    }

    /// Cancel (Esc on the Mac) beside a revealed entry: hides it without saving.
    public var offersCancel: Bool {
        revealsEntry && isEntry
    }

    /// "PLA" + "PLA Basic" reads "PLA Basic"; "PETG" + "HF" reads "PETG HF".
    public static func title(material: String, subtype: String?) -> String {
        guard let subtype, !subtype.isEmpty else { return material }
        return subtype.lowercased().hasPrefix(material.lowercased()) ? subtype : "\(material) \(subtype)"
    }

    static func isEntryState(_ status: FeedRow.Status) -> Bool {
        switch status {
        case .awaitingWeight, .saving, .created, .updating, .error: true
        case .scanned, .unknown, .saved, .savedAfterTimeout, .markedNew, .markedEmpty, .deleted: false
        }
    }

    /// A New spool or a Created row, whose entry shows only when revealed.
    public static func revealsEntry(_ row: FeedRow) -> Bool {
        isNewSpool(row) || isCreated(row)
    }

    /// A tag with material and no spool, not yet looked up again or deleted:
    /// also while the save that creates it runs, and after it (or a create
    /// on scan) fails.
    static func isNewSpool(_ row: FeedRow) -> Bool {
        row.spool == nil && row.tag.hasPrefill && isNewEntryState(row.status)
    }

    /// Created in Bambuddy, also while its weight saves and after that, or
    /// a Link, fails.
    static func isCreated(_ row: FeedRow) -> Bool {
        guard let spool = row.spool else { return false }
        if row.status == .created { return true }
        guard row.createdSpoolId == spool.id else { return false }
        return switch row.status {
        case .saving, .error: true
        default: false
        }
    }

    /// The row's actions, prominent first, and the prominent one.
    static func rowActions(
        _ row: FeedRow, isNewSpool: Bool, revealed: Bool, offersUnknown: Bool, offersLink: Bool, isSaving: Bool
    ) -> ([RowAction], RowAction?) {
        guard !isSaving else { return ([], nil) }
        let link: [RowAction] = offersLink || offersUnknown ? [.link] : []
        if revealed { return (link, nil) }
        let actions: [RowAction]
        let preferred: RowAction?
        if isNewSpool {
            actions = [.saveAsNew, .saveWithWeight] + link
            preferred = .saveAsNew
        } else if isCreated(row) {
            actions = [.setWeight] + link
            preferred = .setWeight
        } else if offersUnknown {
            actions = [row.tag.hasPrefill ? .saveAsNew : .newForm] + link
            preferred = nil
        } else {
            return ([], nil)
        }
        let asked: RowAction? = switch row.request {
        case .link: .link
        case .create: actions.first
        case nil: nil
        }
        guard let prominent = asked ?? preferred else { return (actions, nil) }
        return ([prominent] + actions.filter { $0 != prominent }, prominent)
    }

    /// A tag with material and no spool: the weight entry stays through the
    /// save that creates the spool, and after it fails.
    static func isNewEntryState(_ status: FeedRow.Status) -> Bool {
        switch status {
        case .unknown, .saving, .error: true
        case .scanned, .awaitingWeight, .saved, .savedAfterTimeout, .created, .updating, .markedNew, .markedEmpty,
             .deleted: false
        }
    }

    static func statusText(_ row: FeedRow) -> String {
        switch row.status {
        case .scanned: return "Looking up"
        case .awaitingWeight: return "Enter weight"
        case .unknown(let prefill):
            if let request = row.request { return requestText(request) }
            return prefill ? "New spool" : "Not in Bambuddy; tag has no material"
        case .saving: return "Saving\u{2026}"
        case .saved, .savedAfterTimeout:
            let saved = row.spool.map { "Saved \($0.remaining) g left" } ?? "Saved"
            return row.savedBy.map { "\(saved) · \(savedByText($0))" } ?? saved
        case .created: return "Created in Bambuddy"
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
        case .awaitingWeight: (.symbol("scalemass"), .blue)
        case .unknown(let prefill): if row.request != nil {
            (.symbol("dot.radiowaves.left.and.right"), .blue)
        } else {
            (.symbol(prefill ? "plus.circle" : "questionmark.circle"), .secondary)
        }
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
