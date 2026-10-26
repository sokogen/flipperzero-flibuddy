import Foundation

/// One scanned tag in the session feed, with what Bambuddy said about it and
/// the last weight saved for it.
public struct FeedRow: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The Flipper sent the tag; no lookup yet.
        case scanned
        /// Bambuddy knows the spool; a weight can be entered.
        case awaitingWeight
        /// No spool carries the tag. `prefill`: the tag has material, so New is offered.
        case unknown(prefill: Bool)
        case saved
        case created
        case error(String)
    }

    /// Which side saved the last weight or created the item; last write wins.
    public enum Side: String, Equatable, Sendable {
        case flipper
        case host
    }

    /// The Flipper asked the host to finish the tag (`create_on_host` / `link_on_host`).
    public enum HostRequest: Equatable, Sendable {
        case create
        case link
    }

    public struct Weight: Equatable, Sendable {
        public var grams: Int
        public var mode: Intent.WeightMode

        public init(grams: Int, mode: Intent.WeightMode) {
            self.grams = grams
            self.mode = mode
        }
    }

    public let id: UUID
    public var scanId: String
    public var scannedAt: Date
    public var dump: TagDump
    public var tag: ParsedTag
    /// Bambuddy's name for the tag's colour, once the colour map is loaded.
    public var colorName: String?
    public var spool: Spool?
    public var status: Status
    public var weight: Weight?
    public var savedBy: Side?
    public var request: HostRequest?

    public init(
        id: UUID = UUID(), scanId: String, scannedAt: Date = Date(), dump: TagDump,
        spool: Spool? = nil, status: Status = .scanned
    ) {
        self.id = id
        self.scanId = scanId
        self.scannedAt = scannedAt
        self.dump = dump
        self.tag = TagParser.parse(dump)
        self.spool = spool
        self.status = status
    }
}
