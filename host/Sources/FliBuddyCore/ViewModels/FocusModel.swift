import Foundation

extension FeedViewModel {
    /// Which row has the keyboard: the newest row that waits for a weight
    /// takes focus, unless the focused row's field holds a typed value, in
    /// which case the new row only gets a hint. After a save focus moves on to
    /// the newest waiting row; with none left it stays where it is.
    public struct FocusModel: Equatable, Sendable {
        public enum Direction: Sendable {
            case up
            case down
        }

        public struct Row: Equatable, Sendable {
            public var id: FeedRow.ID
            /// Enter weight: the row waits for a weight. A tag no spool
            /// carries and an Added row never take focus.
            public var isWaiting: Bool
            /// The user typed in the row's field.
            public var isTouched: Bool

            public init(id: FeedRow.ID, isWaiting: Bool, isTouched: Bool = false) {
                self.id = id
                self.isWaiting = isWaiting
                self.isTouched = isTouched
            }
        }

        /// The feed, newest first.
        public private(set) var rows: [Row]
        public private(set) var focusedRow: FeedRow.ID?
        /// A waiting row that did not take focus because the user was typing.
        public private(set) var hintedRow: FeedRow.ID?

        public init(rows: [Row] = []) {
            self.rows = rows
        }

        /// New rows, states or drafts; focus and hint on rows that are gone are
        /// dropped, a hint on a row that no longer waits too.
        public mutating func update(rows: [Row]) {
            self.rows = rows
            if let focusedRow, row(focusedRow) == nil { self.focusedRow = nil }
            if let hintedRow, row(hintedRow)?.isWaiting != true { self.hintedRow = nil }
        }

        /// The user (or the model) put the keyboard on `id`.
        public mutating func focus(_ id: FeedRow.ID?) {
            focusedRow = id
            if id != nil, hintedRow == id { hintedRow = nil }
        }

        /// The newest row that waits for a weight, other than `excluded`.
        public func nextWaitingRow(excluding excluded: FeedRow.ID? = nil) -> FeedRow.ID? {
            rows.first { $0.isWaiting && $0.id != excluded }?.id
        }

        /// `id` started waiting (a scan, a rescan, a reopen): it takes
        /// focus unless the focused row is touched; then it is hinted.
        public mutating func onRowBecameWaiting(_ id: FeedRow.ID) {
            if let focusedRow, focusedRow != id, row(focusedRow)?.isTouched == true {
                hintedRow = id
            } else {
                focus(id)
            }
        }

        /// `id` was saved: if it had focus, focus moves to the newest waiting
        /// row; with none, the selection stays on `id`.
        public mutating func onSaved(_ id: FeedRow.ID) {
            if hintedRow == id { hintedRow = nil }
            guard focusedRow == id || focusedRow == nil else { return }
            focus(nextWaitingRow(excluding: id) ?? id)
        }

        /// ⌘↑ / ⌘↓: the previous or next row, stopping at the ends. Nothing
        /// focused: the top row.
        public mutating func moveFocus(_ direction: Direction) {
            guard !rows.isEmpty else { return }
            guard let focusedRow, let index = rows.firstIndex(where: { $0.id == focusedRow }) else {
                focus(rows[0].id)
                return
            }
            let next = direction == .up ? max(0, index - 1) : min(rows.count - 1, index + 1)
            focus(rows[next].id)
        }

        private func row(_ id: FeedRow.ID) -> Row? {
            rows.first { $0.id == id }
        }
    }
}
