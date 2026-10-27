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
    /// Created, or an error on a known spool, which keeps the value for a
    /// retry). A tag with material and no spool ("Not in Bambuddy", the
    /// Flipper's Auto-save new off) shows it too: Save creates the spool
    /// from the tag, then records the weight.
    public let isEntry: Bool
    /// Save creates the spool before it records the weight.
    public let savesNewSpool: Bool
    /// Enter weight, Created, or Not in Bambuddy for a tag with material:
    /// the row waits for a weight and may take focus.
    public let isWaiting: Bool
    /// A weight is on its way to Bambuddy; the entry block is disabled.
    public let isSaving: Bool
    /// A saved row; a click opens it again for a re-weigh.
    public let isReopenable: Bool
    /// Created in Bambuddy and not weighed yet (also after a failed save or
    /// delete): Link to existing… moves the tag and deletes this spool.
    public let offersLinkExisting: Bool
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
            colorName = spool.colorName
            remainingText = spool.isArchived ? "archived" : "\(spool.remaining) g left of \(spool.labelWeight)"
            base = spool.remaining
            core = spool.coreWeight
        } else {
            if let material = row.tag.material {
                title = Self.title(material: material, subtype: row.tag.detailedType)
            } else {
                title = row.tag.kind == .ntag ? Self.blankTitle(uid: row.tag.uid) : "Bambu tag"
            }
            colorName = row.colorName
            remainingText = row.tag.labelWeight.map { "label \($0) g" } ?? ""
            base = row.tag.hasPrefill ? row.tag.labelWeight ?? NewSpool.defaultLabelWeight : nil
            core = row.tag.hasPrefill ? coreWeight : nil
        }
        colorCode = Self.colorCode(row)
        colorLine = [colorName, colorCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        detailText = [colorLine, remainingText].filter { !$0.isEmpty }.joined(separator: " · ")
        swatch = (spool?.rgba ?? row.tag.rgba).flatMap(Swatch.init(rgba:))
        statusText = Self.statusText(row)
        isError = if case .error = row.status { true } else { false }
        spoolId = spool?.id
        offersUnknownActions = spool == nil && row.status != .scanned
        newAction = row.tag.hasPrefill ? .fromTag : .form
        prominentAction = row.request.map { $0 == .create ? .new : .link }
        savesNewSpool = spool == nil && row.tag.hasPrefill && Self.isNewEntryState(row.status)
        isEntry = (spool != nil && Self.isEntryState(row.status)) || savesNewSpool
        isWaiting = (spool != nil && (row.status == .awaitingWeight || row.status == .created))
            || (savesNewSpool && row.status.isUnknown)
        isSaving = row.status == .saving || row.status == .updating
        isReopenable = spool != nil && [.saved, .savedAfterTimeout, .markedNew, .markedEmpty].contains(row.status)
        offersLinkExisting = spool != nil && row.createdSpoolId == spool?.id
            && (row.status == .created || isError)
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

    /// The weight field's VoiceOver label.
    public static func weightFieldLabel(mode: Intent.WeightMode) -> String {
        mode == .gross ? "Gross weight, grams" : "Net weight, grams"
    }

    /// The word inside the iPhone's weight field, right of the value.
    public static func modeWord(_ mode: Intent.WeightMode) -> String {
        mode == .gross ? "gross" : "net"
    }

    /// New and Link to existing… as the iPhone card lays them out, the
    /// prominent one first: New, unless the Flipper asked to link.
    public var cardActions: [UnknownAction] {
        prominentAction == .link ? [.link, .new] : [.new, .link]
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
            return prefill ? "Not in Bambuddy" : "Not in Bambuddy; tag has no material"
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
