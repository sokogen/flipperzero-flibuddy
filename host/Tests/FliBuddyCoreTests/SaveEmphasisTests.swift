import Testing
@testable import FliBuddyCore

@Suite("Save button emphasis")
struct SaveEmphasisTests {
    @Test func saveIsTintedUnlessContrastIsIncreased() {
        // Spec page, "Weight entry": a tinted button, not filled; the weight is the focus.
        #expect(SaveEmphasis.forContrast(increased: false) == .tinted)
        // The tinted fill's text reaches about 3.4:1; Increase Contrast gets the filled button.
        #expect(SaveEmphasis.forContrast(increased: true) == .prominent)
    }
}
