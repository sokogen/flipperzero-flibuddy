import Testing
@testable import FliBuddyCore

/// A slice of Bambuddy's `GET /inventory/colors/map`.
let sampleColorMap = ColorMap(
    colors: ["ff9016": "Pumpkin Orange", "ffffff": "White"],
    byMaterial: ["pla matte|ffffff": "Ivory White", "pla basic|ffffff": "Jade White"]
)

@Suite("ColorNameResolver")
struct ColorNameResolverTests {
    private let resolver = ColorNameResolver(sampleColorMap)

    @Test func theMaterialTableComesFirst() {
        #expect(resolver.name(rgba: "FFFFFFFF", detailedType: "PLA Matte") == "Ivory White")
        #expect(resolver.name(rgba: "FFFFFFFF", detailedType: "PLA Basic") == "Jade White")
    }

    @Test func theColourTableIsTheFallback() {
        #expect(resolver.name(rgba: "FF9016FF", detailedType: "PLA Basic") == "Pumpkin Orange")
        #expect(resolver.name(rgba: "FFFFFFFF", detailedType: "PETG HF") == "White")
        #expect(resolver.name(rgba: "FFFFFFFF", detailedType: nil) == "White")
    }

    @Test func anUnknownColourHasNoName() {
        // the real "PLA Pure" spool
        #expect(resolver.name(rgba: "A4DBE8FF", detailedType: "PLA Pure") == nil)
    }

    @Test func theAlphaByteIsIgnored() {
        #expect(resolver.name(rgba: "FF901600", detailedType: nil) == "Pumpkin Orange")
        #expect(resolver.name(rgba: "FF9016", detailedType: nil) == "Pumpkin Orange")
        #expect(resolver.name(rgba: "#FF9016FF", detailedType: nil) == "Pumpkin Orange")
    }

    @Test func lookupsIgnoreCase() {
        #expect(resolver.name(rgba: "ff9016ff", detailedType: nil) == "Pumpkin Orange")
        #expect(resolver.name(rgba: "fFfFfFfF", detailedType: "pla MATTE") == "Ivory White")
        let upper = ColorNameResolver(ColorMap(colors: ["FF9016": "Pumpkin Orange"], byMaterial: ["PLA Matte|FFFFFF": "Ivory White"]))
        #expect(upper.name(rgba: "FF9016FF", detailedType: nil) == "Pumpkin Orange")
        #expect(upper.name(rgba: "FFFFFFFF", detailedType: "PLA Matte") == "Ivory White")
    }

    @Test func noColourOrABrokenOneHasNoName() {
        #expect(resolver.name(rgba: nil, detailedType: "PLA Basic") == nil)
        #expect(resolver.name(rgba: "FFF", detailedType: nil) == nil)
        #expect(resolver.name(rgba: "GGGGGGFF", detailedType: nil) == nil)
        let empty = ColorNameResolver(ColorMap(colors: [:], byMaterial: [:]))
        #expect(empty.name(rgba: "FF9016FF", detailedType: "PLA Basic") == nil)
    }

    @Test func aParsedTagIsNamedByItsColourAndDetailedType() throws {
        let synthetic = TagParser.parse(try TagFixtures.bambu())
        #expect(resolver.name(for: synthetic) == "Jade White")
        let real = TagParser.parse(try TagFixtures.bambuReal())
        #expect(resolver.name(for: real) == nil)
    }
}
