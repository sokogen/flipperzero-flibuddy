import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The host OS for the `hello` line, e.g. `macOS 26.0` or `iPadOS 26.1`.
public enum PlatformInfo {
    public enum Family: String, Sendable {
        case macOS
        case iOS
        case iPadOS
    }

    /// `family` and the major and minor version.
    public static func describe(_ family: Family, version: OperatingSystemVersion) -> String {
        "\(family.rawValue) \(version.majorVersion).\(version.minorVersion)"
    }

    /// The family this process runs on; iPadOS is told apart by the device idiom.
    @MainActor public static var currentFamily: Family {
        #if os(macOS)
        .macOS
        #elseif canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
        #else
        .iOS
        #endif
    }

    @MainActor public static var current: String {
        describe(currentFamily, version: ProcessInfo.processInfo.operatingSystemVersion)
    }
}
