import Foundation
import Testing
@testable import FliBuddyCore

@Suite("BambuddyDate")
struct BambuddyDateTests {
    private let noon = Date(timeIntervalSince1970: 1_792_929_600) // 2026-10-25T12:00:00Z

    @Test func aTimeWithoutAZoneIsUTC() {
        // Bambuddy stores naive UTC; its web app appends "Z" before parsing.
        #expect(BambuddyDate.parse("2026-10-25T12:00:00") == noon)
        #expect(BambuddyDate.parse("2026-10-25T12:00:00.250000") == noon.addingTimeInterval(0.25))
    }

    @Test func aTimeWithAZoneKeepsIt() {
        #expect(BambuddyDate.parse("2026-10-25T12:00:00Z") == noon)
        #expect(BambuddyDate.parse("2026-10-25T14:00:00+02:00") == noon)
        #expect(BambuddyDate.parse("2026-10-25T12:00:00.5Z") == noon.addingTimeInterval(0.5))
    }

    @Test func anythingElseIsNoDate() {
        #expect(BambuddyDate.parse("") == nil)
        #expect(BambuddyDate.parse("yesterday") == nil)
        #expect(BambuddyDate.parse("2026-10-25") == nil)
    }

    @Test func writesWhatBambuddySends() {
        #expect(BambuddyDate.string(from: noon) == "2026-10-25T12:00:00")
        #expect(BambuddyDate.parse(BambuddyDate.string(from: noon)) == noon)
    }
}
