import Testing

@testable import FliBuddyCore

struct BambuColorCodeTests {
    @Test func caramelByVariantIdAndByColour() {
        #expect(BambuColorCode.find(filamentId: "GFA01", variantId: "A01-N3", rgba: nil)?.code == "11803")
        let byColour = BambuColorCode.find(filamentId: "GFA01", variantId: nil, rgba: "AE835BFF")
        #expect(byColour?.code == "11803")
        #expect(byColour?.name == "Caramel")
    }

    @Test func unknownIdsFindNothing() {
        #expect(BambuColorCode.find(filamentId: nil, variantId: "A01-N3", rgba: "AE835BFF") == nil)
        #expect(BambuColorCode.find(filamentId: "GFA01", variantId: "A01-ZZ", rgba: "123456FF") == nil)
        #expect(BambuColorCode.find(filamentId: "XXXXX", variantId: "A01-N3", rgba: nil) == nil)
    }

    @Test func aNewSpoolCarriesTheCodeAsMaterialNumber() throws {
        let tag = TagParser.parse(try TagFixtures.bambuReal())
        let spool = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: nil))
        #expect(spool.materialNumber == "17600")
    }
}
