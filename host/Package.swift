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

// `swift run` starts a bare executable without an app bundle; macOS reads the
// Bluetooth usage description from an Info.plist embedded in the binary, and
// without one touching CoreBluetooth ends the process.
let macInfoPlistPath = Context.packageDirectory + "/Sources/FliBuddyMac/Info.plist"
let macLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", macInfoPlistPath],
        .when(platforms: [.macOS])
    ),
]

let package = Package(
    name: "FliBuddy",
    // `.v26` needs tools version 6.2; the string form works with 6.0.
    platforms: [.macOS(.v14), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "FliBuddyCore", targets: ["FliBuddyCore"]),
        .library(name: "FliBuddyUI", targets: ["FliBuddyUI"]),
        .executable(name: "FliBuddyMac", targets: ["FliBuddyMac"]),
    ],
    targets: [
        .target(name: "FliBuddyCore"),
        // SwiftUI views shared by the macOS and iOS apps.
        .target(name: "FliBuddyUI", dependencies: ["FliBuddyCore"]),
        .executableTarget(
            name: "FliBuddyMac", dependencies: ["FliBuddyCore", "FliBuddyUI"],
            exclude: ["Info.plist"], linkerSettings: macLinkerSettings
        ),
        .testTarget(
            name: "FliBuddyCoreTests",
            dependencies: ["FliBuddyCore"],
            swiftSettings: testSwiftSettings
        ),
    ]
)
