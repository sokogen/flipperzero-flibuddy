// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Command Line Tools ship the swift-testing macro plugin one directory too deep
// for its @loader_path/.. rpath, so `@Test` fails with "plugin for module
// 'TestingMacros' not found". Toolchain/clt-testing-plugin mirrors the expected
// layout with symlinks into the CLT; point the compiler at it when building with
// DEVELOPER_DIR=/Library/Developer/CommandLineTools. See README.md.
let cltTestingPluginPath = Context.packageDirectory + "/Toolchain/clt-testing-plugin/testing"
let usesCommandLineTools = Context.environment["DEVELOPER_DIR"]?.hasPrefix("/Library/Developer/CommandLineTools") == true
let testSwiftSettings: [SwiftSetting] = usesCommandLineTools
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginPath])]
    : []

let package = Package(
    name: "SpoolBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpoolBuddyCore", targets: ["SpoolBuddyCore"]),
        .executable(name: "SpoolBuddyMac", targets: ["SpoolBuddyMac"]),
    ],
    targets: [
        .target(name: "SpoolBuddyCore"),
        .executableTarget(name: "SpoolBuddyMac", dependencies: ["SpoolBuddyCore"]),
        .testTarget(
            name: "SpoolBuddyCoreTests",
            dependencies: ["SpoolBuddyCore"],
            // Fixtures is a symlink to ../../../protocol/fixtures (see README.md).
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings
        ),
    ]
)
