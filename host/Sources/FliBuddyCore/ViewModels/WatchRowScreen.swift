import Foundation

/// Which body the watch's row detail shows under its header (watch spec,
/// "Row detail"): the weight entry, the saved result, an unknown tag, or a
/// spinner while the row is looked up or created.
public enum WatchRowScreen: Equatable, Sendable {
    /// The crown entry.
    case entry
    /// Saved, Timeout, Added to Bambuddy, Marked as new / empty: the result
    /// and Weigh again.
    case saved
    /// No spool and no entry: the phrase, a hint where the phone or Mac has
    /// to act, and the design's one New button for a tag with material.
    case unknown(hint: String?, offersNew: Bool)
    /// A spinner and the phrase.
    case busy(String)

    public static let creatingText = "Creating in Bambuddy\u{2026}"
    public static let createHint = "Create it on the iPhone."
    public static let linkHint = "Link it on the iPhone."
    public static let turnTheCrownText = "Turn the crown"

    /// `isCreating`: New on the watch is on its way to Bambuddy.
    public init(_ item: FeedItem, isCreating: Bool) {
        if isCreating {
            self = .busy(Self.creatingText)
        } else if item.isEntry {
            self = .entry
        } else if item.isReopenable {
            self = .saved
        } else if item.statusSymbol == .progress {
            self = .busy(item.statusText)
        } else {
            // A link request wins: the Flipper asked for something only the
            // phone or the Mac can do.
            let hint: String? = if item.isDeleted {
                nil
            } else if item.prominentRowAction == .link {
                Self.linkHint
            } else if item.rowActions.contains(.newForm) {
                Self.createHint
            } else {
                nil
            }
            self = .unknown(hint: hint, offersNew: item.rowActions.contains(.new))
        }
    }

    /// The entry's one line under the weight: a host error, else the row's
    /// error, else `Turn the crown` without a value, else what a save
    /// records (without the gross sum, which does not fit the watch).
    public static func entryLine(
        _ item: FeedItem, value: Int?, mode: Intent.WeightMode, hostError: String?
    ) -> FeedItem.Readout {
        if let hostError { return FeedItem.Readout(text: "Error: \(hostError)", isError: true) }
        if item.isError { return FeedItem.Readout(text: item.statusText, isError: true) }
        guard let value else { return FeedItem.Readout(text: turnTheCrownText, isError: false) }
        let readout = item.readout(value: value, mode: mode)
        return FeedItem.Readout(text: readout.short, isError: readout.isError)
    }

    /// The saved screen's big number, `590 g`: what is left on the spool.
    public static func remainingText(_ item: FeedItem) -> String? {
        guard item.spoolId != nil else { return nil }
        return item.base.map { "\($0) g" }
    }
}
