import Foundation
import Testing
@testable import FliBuddyCore

private func tag(_ name: String) throws -> ParsedTag {
    TagParser.parse(try fixtureScan(name).tag)
}

@Suite("NewSpoolForm")
struct NewSpoolFormTests {
    @Test func theSheetIsTitledByTheTag() throws {
        #expect(NewSpoolForm.title == "New spool")
        #expect(NewSpoolForm(tag: try tag("scan_ntag"), settings: testSettings).subtitle == "NTAG 7-byte · 04112233445566")
        #expect(NewSpoolForm(tag: try tag("scan_mfc"), settings: testSettings).subtitle == "Bambu tag · 5A3C9E21")
        #expect(
            NewSpoolForm.footer
                == "Material is required. The row asks for a weight once Bambuddy has created the spool."
        )
    }

    @Test func theMaterialMenuOffersTheSpecList() throws {
        #expect(NewSpoolForm.materials == ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA"])
        var form = NewSpoolForm(tag: try tag("scan_ntag"), settings: testSettings)
        // "Choose…" is the empty material
        #expect(form.material == "")
        #expect(form.materialOptions == NewSpoolForm.materials)
        #expect(!form.canCreate)
        form.material = "PETG"
        #expect(form.materialOptions == NewSpoolForm.materials)
        #expect(form.canCreate)
    }

    @Test func aMaterialOffTheListStaysSelectable() throws {
        var form = NewSpoolForm(tag: try tag("scan_ntag"), settings: testSettings)
        form.material = "PLA-CF"
        #expect(form.materialOptions == NewSpoolForm.materials + ["PLA-CF"])
        #expect(form.newSpool?.material == "PLA-CF")
    }

    @Test func theLabelWeightDefaultsTo1000AndTakesDigitsOnly() throws {
        var form = NewSpoolForm(tag: try tag("scan_ntag"), settings: testSettings)
        #expect(form.labelWeight == "1000")
        form.labelWeight = "75x0"
        #expect(form.labelWeight == "750")
        form.labelWeight = "123456"
        #expect(form.labelWeight == "1234")
        form.labelWeight = ""
        form.material = "PLA"
        #expect(!form.canCreate)
    }

    @Test func theLabelWeightComesFromTheTagWhenItHasOne() throws {
        let bambu = try tag("scan_mfc")
        let form = NewSpoolForm(tag: bambu, settings: testSettings)
        #expect(form.labelWeight == String(try #require(bambu.labelWeight)))
        #expect(form.canCreate)
    }
}
