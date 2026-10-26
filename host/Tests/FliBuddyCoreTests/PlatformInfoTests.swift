import Foundation
import Testing
@testable import FliBuddyCore

@Suite("PlatformInfo")
struct PlatformInfoTests {
    @Test(arguments: [
        (PlatformInfo.Family.macOS, "macOS 26.1"),
        (.iOS, "iOS 26.1"),
        (.iPadOS, "iPadOS 26.1"),
        (.watchOS, "watchOS 26.1"),
    ])
    func namesTheFamilyAndVersion(family: PlatformInfo.Family, expected: String) {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 3)
        #expect(PlatformInfo.describe(family, version: version) == expected)
    }

    @MainActor
    @Test func theCurrentFamilyMatchesTheBuild() {
        #if os(macOS)
        #expect(PlatformInfo.currentFamily == .macOS)
        #else
        #expect(PlatformInfo.currentFamily != .macOS)
        #endif
    }

    @MainActor
    @Test func theCurrentDescriptionStartsWithTheFamily() {
        let description = PlatformInfo.current
        #expect(description.hasPrefix(PlatformInfo.currentFamily.rawValue + " "))
        #expect(description.count <= 40)
    }
}
