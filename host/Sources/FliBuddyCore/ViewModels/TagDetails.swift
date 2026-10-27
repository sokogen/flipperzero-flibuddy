import Foundation

/// The technical facts of a row's tag and spool, which the feed row leaves
/// out: what the Tag details view lists on every platform. A fact is there
/// only when it is known.
public struct TagDetails: Equatable, Sendable {
    public struct Fact: Equatable, Identifiable, Sendable {
        public var label: String
        public var value: String
        /// UIDs and ids: monospaced, selectable for copying.
        public var isIdentifier: Bool

        public var id: String { label }

        public init(label: String, value: String, isIdentifier: Bool = false) {
            self.label = label
            self.value = value
            self.isIdentifier = isIdentifier
        }
    }

    /// The row's title, e.g. "PLA Basic".
    public let title: String
    public let facts: [Fact]

    public init(_ row: FeedRow) {
        let item = FeedItem(row)
        let tag = row.tag
        let spool = row.spool
        title = item.title
        var facts: [Fact] = []
        func add(_ label: String, _ value: String?, identifier: Bool = false) {
            guard let value, !value.isEmpty else { return }
            facts.append(Fact(label: label, value: value, isIdentifier: identifier))
        }
        add("UID", tag.uid, identifier: true)
        add("Bambuddy tag UID", tag.bambuddyTagUid == tag.uid.uppercased() ? nil : tag.bambuddyTagUid, identifier: true)
        add("Tray UUID", tag.trayUuid, identifier: true)
        add("Colour", item.colorName)
        add("Colour code", item.colorCode)
        add("Filament ID", tag.materialId, identifier: true)
        add("RGBA", (spool?.rgba ?? tag.rgba).flatMap { $0.isEmpty ? nil : "#\($0)" }, identifier: true)
        add("Diameter", tag.diameter.flatMap(Self.diameter))
        add("Nozzle", Self.nozzle(min: tag.nozzleMin, max: tag.nozzleMax))
        add("Label weight", (spool?.labelWeight ?? tag.labelWeight).map { "\($0) g" })
        add("Core weight", spool.map { "\($0.coreWeight) g" })
        add("Spool", spool.map { $0.isArchived ? "#\($0.id) · archived" : "#\($0.id)" })
        self.facts = facts
    }

    /// The watch's Details section: colour name, colour code, UID, filament
    /// id, diameter, nozzle range and spool, in that order, each when known.
    public var watchFacts: [Fact] {
        Self.watchLabels.compactMap { label in facts.first { $0.label == label } }
    }

    static let watchLabels = ["Colour", "Colour code", "UID", "Filament ID", "Diameter", "Nozzle", "Spool"]

    /// The value of the fact labelled `label`, if the row has it.
    public func value(_ label: String) -> String? {
        facts.first { $0.label == label }?.value
    }

    /// "1.75 mm"; `nil` for no diameter.
    public static func diameter(_ millimetres: Double) -> String? {
        millimetres > 0 ? String(format: "%.2f mm", millimetres) : nil
    }

    /// "190–230 °C", or the one temperature the tag gives.
    public static func nozzle(min: Int?, max: Int?) -> String? {
        switch (min, max) {
        case let (min?, max?) where min != max: "\(min)\u{2013}\(max) °C"
        case let (min?, _): "\(min) °C"
        case let (nil, max?): "\(max) °C"
        case (nil, nil): nil
        }
    }
}
