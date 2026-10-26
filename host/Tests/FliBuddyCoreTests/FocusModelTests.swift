import Foundation
import Testing
@testable import FliBuddyCore

private typealias FocusModel = FeedViewModel.FocusModel

@Suite("FocusModel")
struct FocusModelTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func aNewWaitingRowTakesFocusWhenNothingIsTouched() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: true)])
        focus.focus(a)

        focus.onRowBecameWaiting(b)

        #expect(focus.focusedRow == b)
        #expect(focus.hintedRow == nil)
    }

    @Test func aNewWaitingRowTakesFocusFromARowThatNoLongerWaits() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: false)])
        focus.focus(a)

        focus.onRowBecameWaiting(b)

        #expect(focus.focusedRow == b)
    }

    @Test func aNewWaitingRowWaitsWithAHintWhileTheFocusedFieldIsTouched() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: true, isTouched: true)])
        focus.focus(a)

        focus.onRowBecameWaiting(b)

        #expect(focus.focusedRow == a)
        #expect(focus.hintedRow == b)
    }

    @Test func aTouchedRowThatIsNotFocusedDoesNotHoldFocus() {
        var focus = FocusModel(rows: [
            .init(id: c, isWaiting: true), .init(id: b, isWaiting: true), .init(id: a, isWaiting: true, isTouched: true),
        ])
        focus.focus(b)

        focus.onRowBecameWaiting(c)

        #expect(focus.focusedRow == c)
        #expect(focus.hintedRow == nil)
    }

    @Test func afterASaveFocusMovesToTheNewestWaitingRow() {
        var focus = FocusModel(rows: [
            .init(id: c, isWaiting: true), .init(id: b, isWaiting: true), .init(id: a, isWaiting: false),
        ])
        focus.focus(a)

        focus.onSaved(a)

        #expect(focus.focusedRow == c)
    }

    @Test func afterASaveTheHintedRowGetsFocusAndLosesItsHint() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: true, isTouched: true)])
        focus.focus(a)
        focus.onRowBecameWaiting(b)
        focus.update(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: false)])

        focus.onSaved(a)

        #expect(focus.focusedRow == b)
        #expect(focus.hintedRow == nil)
    }

    @Test func withNoWaitingRowTheSelectionStays() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: false), .init(id: a, isWaiting: false)])
        focus.focus(a)

        focus.onSaved(a)

        #expect(focus.focusedRow == a)
        #expect(focus.nextWaitingRow() == nil)
    }

    @Test func aSaveOnAnotherRowDoesNotMoveFocus() {
        var focus = FocusModel(rows: [
            .init(id: c, isWaiting: true), .init(id: b, isWaiting: false), .init(id: a, isWaiting: true),
        ])
        focus.focus(a)

        focus.onSaved(b)

        #expect(focus.focusedRow == a)
    }

    @Test func nextWaitingRowIsTheNewestWaitingOne() {
        let focus = FocusModel(rows: [
            .init(id: c, isWaiting: false), .init(id: b, isWaiting: true), .init(id: a, isWaiting: true),
        ])

        #expect(focus.nextWaitingRow() == b)
        #expect(focus.nextWaitingRow(excluding: b) == a)
    }

    @Test func upAndDownMoveWithinTheFeedAndStopAtTheEnds() {
        var focus = FocusModel(rows: [
            .init(id: c, isWaiting: false), .init(id: b, isWaiting: true), .init(id: a, isWaiting: false),
        ])

        focus.moveFocus(.down)
        #expect(focus.focusedRow == c)
        focus.moveFocus(.up)
        #expect(focus.focusedRow == c)
        focus.moveFocus(.down)
        #expect(focus.focusedRow == b)
        focus.moveFocus(.down)
        #expect(focus.focusedRow == a)
        focus.moveFocus(.down)
        #expect(focus.focusedRow == a)
        focus.moveFocus(.up)
        #expect(focus.focusedRow == b)
    }

    @Test func upAndDownInAnEmptyFeedDoNothing() {
        var focus = FocusModel()

        focus.moveFocus(.down)
        focus.moveFocus(.up)

        #expect(focus.focusedRow == nil)
    }

    @Test func focusingTheHintedRowClearsTheHint() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: true, isTouched: true)])
        focus.focus(a)
        focus.onRowBecameWaiting(b)

        focus.moveFocus(.up)

        #expect(focus.focusedRow == b)
        #expect(focus.hintedRow == nil)
    }

    @Test func rowsThatLeaveDropTheirFocusAndHint() {
        var focus = FocusModel(rows: [.init(id: b, isWaiting: true), .init(id: a, isWaiting: true, isTouched: true)])
        focus.focus(a)
        focus.onRowBecameWaiting(b)

        focus.update(rows: [.init(id: b, isWaiting: false)])
        #expect(focus.focusedRow == nil)
        #expect(focus.hintedRow == nil)
    }
}
