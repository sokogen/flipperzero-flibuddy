import Foundation

/// One feed row as the views show it: Bambuddy's data for a known spool, the
/// tag's own data otherwise.
public struct FeedItem: Identifiable, Equatable, Sendable {
    public let id: FeedRow.ID
    public let scanId: String
    public let scannedAt: Date
    /// Upper-case hex, shown under the title.
    public let uid: String
    /// Material and subtype, e.g. "PLA Basic" or "PETG HF"; a blank tag reads
    /// "NTAG 7-byte UID 04A2…".
    public let title: String
    /// Bambuddy's or the resolved colour name; never the hex, which the
    /// swatch shows instead.
    public let colorName: String?
    public let swatch: Swatch?
    /// "484 g left of 1000" for a known spool, "label 1000 g" for a tag.
    public let remainingText: String
    /// The colour column: "Bambu Green · 590 g left of 1000", "label 1000 g",
    /// or empty.
    public let detailText: String
    public let statusText: String
    public let isError: Bool
    /// "by Flipper" / "by host" once a weight was saved or the item created.
    public let savedByText: String?
    /// What the Flipper asked the host to do with the tag, if anything.
    public let requestText: String?
    public let spoolId: Int?
    /// Filament grams the suggestion starts from: the spool's remaining
    /// grams, which right after Created are its label weight.
    public let base: Int?
    /// The spool's core weight (`core_weight`); for a Created row the
    /// settings value just sent.
    public let core: Int?
    /// A spool is known, so a weight can be saved.
    public let canWeigh: Bool
    /// The row shows the weight field, mode and Save (Enter weight, Saving…,
    /// Created, or an error on a known spool, which keeps the value for a retry).
    public let isEntry: Bool
    /// Enter weight or Created: the row waits for a weight and may take focus.
    public let isWaiting: Bool
    /// A weight is on its way to Bambuddy; the entry block is disabled.
    public let isSaving: Bool
    /// A saved row; a click opens it again for a re-weigh.
    public let isReopenable: Bool
    /// Created in Bambuddy: Link to existing… moves the tag and deletes this spool.
    public let isCreated: Bool
    /// Under the status of a save the Flipper gave up waiting for.
    public let timeoutNote: String?
    public let statusSymbol: StatusSymbol
    public let statusTint: StatusTint
    /// VoiceOver reads the header as one element, e.g.
    /// "PLA Basic, Bambu Green, 590 grams left of 1000, Enter weight".
    public let accessibilityHeader: String
    /// The lookup is done and found no spool: offer New and Link.
    public let offersUnknownActions: Bool
    /// The tag carries a material, so the New form starts filled in.
    public let hasPrefill: Bool

    public init(_ row: FeedRow) {
        id = row.id
        scanId = row.scanId
        scannedAt = row.scannedAt
        uid = row.tag.uid
        let spool = row.spool
        if let spool {
            title = Self.title(material: spool.material, subtype: spool.subtype)
            colorName = spool.colorName
            remainingText = "\(spool.remaining) g left of \(spool.labelWeight)"
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
            base = nil
            core = nil
        }
        detailText = [colorName, remainingText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        swatch = (spool?.rgba ?? row.tag.rgba).flatMap(Swatch.init(rgba:))
        statusText = Self.statusText(row)
        isError = if case .error = row.status { true } else { false }
        savedByText = row.savedBy.map(Self.savedByText)
        requestText = row.request.map(Self.requestText)
        spoolId = spool?.id
        canWeigh = spool != nil
        offersUnknownActions = spool == nil && row.status != .scanned
        hasPrefill = row.tag.hasPrefill
        isEntry = spool != nil && Self.isEntryState(row.status)
        isWaiting = spool != nil && (row.status == .awaitingWeight || row.status == .created)
        isSaving = row.status == .saving
        isReopenable = spool != nil && (row.status == .saved || row.status == .savedAfterTimeout)
        isCreated = row.status == .created
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

    /// A tag without material, by UID length and the first two bytes:
    /// "NTAG 7-byte UID 04A2…"; the full UID sits under the title.
    public static func blankTitle(uid: String) -> String {
        let prefix = uid.count > 4 ? "\(uid.prefix(4))\u{2026}" : uid
        return "NTAG \(uid.count / 2)-byte UID \(prefix)"
    }

    /// The weight field's VoiceOver label.
    public static func weightFieldLabel(mode: Intent.WeightMode) -> String {
        mode == .gross ? "Gross weight, grams" : "Net weight, grams"
    }

    /// "PLA" + "PLA Basic" reads "PLA Basic"; "PETG" + "HF" reads "PETG HF".
    public static func title(material: String, subtype: String?) -> String {
        guard let subtype, !subtype.isEmpty else { return material }
        return subtype.lowercased().hasPrefix(material.lowercased()) ? subtype : "\(material) \(subtype)"
    }

    static func isEntryState(_ status: FeedRow.Status) -> Bool {
        switch status {
        case .awaitingWeight, .saving, .created, .error: true
        case .scanned, .unknown, .saved, .savedAfterTimeout: false
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
        case .error(let message): return "Error: \(message)"
        }
    }

    static func statusLook(_ row: FeedRow) -> (StatusSymbol, StatusTint) {
        switch row.status {
        case .scanned, .saving: (.progress, .secondary)
        case .awaitingWeight: (.symbol("scalemass"), .blue)
        case .unknown: row.request == nil
            ? (.symbol("questionmark.circle"), .secondary)
            : (.symbol("dot.radiowaves.left.and.right"), .blue)
        case .saved, .savedAfterTimeout: (.symbol("checkmark.circle.fill"), .green)
        case .created: (.symbol("plus.circle.fill"), .green)
        case .error: (.symbol("exclamationmark.triangle.fill"), .red)
        }
    }

    static func savedByText(_ side: FeedRow.Side) -> String {
        side == .host ? "by host" : "by Flipper"
    }

    static func requestText(_ request: FeedRow.HostRequest) -> String {
        request == .create ? "Flipper asks to create it here" : "Flipper asks to link it here"
    }

    /// Title, colour name, what is left (or the label weight) and the status,
    /// grams spelled out; never the hex of an unnamed colour.
    static func accessibilityHeader(
        title: String, colorName: String?, spool: Spool?, labelWeight: Int?, status: String
    ) -> String {
        let amount: String? = if let spool {
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
}
