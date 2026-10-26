import Foundation
import Testing
@testable import FliBuddyCore

@Suite struct FliBuddyGATTTests {
    /// The scan response's manufacturer data from the FAP (`ble_wire_mfg_data`):
    /// the test company id 0xFFFF, little-endian, then the name.
    private func manufacturerData(_ name: String, companyID: [UInt8] = [0xFF, 0xFF]) -> Data {
        Data(companyID) + Data(name.utf8)
    }

    @Test func nameIsReadFromTheManufacturerData() {
        #expect(FliBuddyGATT.name(manufacturerData: manufacturerData("Mars")) == "Mars")
        #expect(FliBuddyGATT.name(manufacturerData: manufacturerData("M")) == "M")
    }

    @Test func manufacturerDataOfAnotherCompanyHasNoName() {
        #expect(FliBuddyGATT.name(manufacturerData: manufacturerData("Mars", companyID: [0x4C, 0x00])) == nil)
        #expect(FliBuddyGATT.name(manufacturerData: manufacturerData("Mars", companyID: [0xFF, 0x00])) == nil)
    }

    @Test func manufacturerDataWithoutANameHasNone() {
        #expect(FliBuddyGATT.name(manufacturerData: nil) == nil)
        #expect(FliBuddyGATT.name(manufacturerData: Data()) == nil)
        #expect(FliBuddyGATT.name(manufacturerData: Data([0xFF])) == nil)
        #expect(FliBuddyGATT.name(manufacturerData: Data([0xFF, 0xFF])) == nil)
    }

    @Test func manufacturerDataThatIsNotUTF8HasNoName() {
        #expect(FliBuddyGATT.name(manufacturerData: Data([0xFF, 0xFF, 0xC3, 0x28])) == nil)
    }

    @Test func displayNamePrefersThePeripheralName() {
        let name = FliBuddyGATT.displayName(
            peripheralName: "Mars", localName: "Venus", manufacturerData: manufacturerData("Pluto"))
        #expect(name == "Mars")
    }

    @Test func displayNameFallsBackToTheLocalName() {
        let name = FliBuddyGATT.displayName(
            peripheralName: nil, localName: "Venus", manufacturerData: manufacturerData("Pluto"))
        #expect(name == "Venus")
    }

    @Test func displayNameFallsBackToTheManufacturerData() {
        let name = FliBuddyGATT.displayName(
            peripheralName: nil, localName: nil, manufacturerData: manufacturerData("Pluto"))
        #expect(name == "Pluto")
    }

    @Test func displayNameIsFlipperWithoutAnyName() {
        #expect(FliBuddyGATT.displayName(peripheralName: nil, localName: nil, manufacturerData: nil) == "Flipper")
        let foreign = manufacturerData("Pluto", companyID: [0x4C, 0x00])
        #expect(FliBuddyGATT.displayName(peripheralName: nil, localName: nil, manufacturerData: foreign) == "Flipper")
    }
}
