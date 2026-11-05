import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The host OS for the `hello` line, e.g. `macOS 26.0`, `iPadOS 26.1` or `watchOS 26.0`.
public enum PlatformInfo {
    public enum Family: String, Sendable {
        case macOS
        case iOS
        case iPadOS
        case watchOS
    }

    /// `family` and the major and minor version.
    public static func describe(_ family: Family, version: OperatingSystemVersion) -> String {
        "\(family.rawValue) \(version.majorVersion).\(version.minorVersion)"
    }

    /// The family this process runs on; iPadOS is told apart by the device idiom.
    @MainActor public static var currentFamily: Family {
        #if os(macOS)
        .macOS
        #elseif os(watchOS)
        .watchOS
        #elseif canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
        #else
        .iOS
        #endif
    }

    /// The device in the feed's "by iPhone": iPhone, iPad, Watch or Mac.
    public static func deviceName(_ family: Family) -> String {
        switch family {
        case .macOS: "Mac"
        case .iOS: "iPhone"
        case .iPadOS: "iPad"
        case .watchOS: "Watch"
        }
    }

    /// This device's name, telling the iPad from the iPhone.
    @MainActor public static var deviceName: String { deviceName(currentFamily) }

    /// The name known when compiling, where the iPad cannot be told apart
    /// (off the main actor; the views pass `deviceName`).
    public static var compiledDeviceName: String {
        #if os(macOS)
        "Mac"
        #elseif os(watchOS)
        "Watch"
        #else
        "iPhone"
        #endif
    }

    @MainActor public static var current: String {
        describe(currentFamily, version: ProcessInfo.processInfo.operatingSystemVersion)
    }
}
