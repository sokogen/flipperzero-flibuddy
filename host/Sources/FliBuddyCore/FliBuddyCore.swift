import Foundation

/// Identity sent in the host `hello`: the platform's app name and the
/// bundle's version, e.g. `flibuddy-ios/1.0.0`.
public enum FliBuddyCore {
    /// The app name per platform; the iPad runs the iOS app.
    public static func appName(_ family: PlatformInfo.Family) -> String {
        switch family {
        case .macOS: "flibuddy-mac"
        case .iOS, .iPadOS: "flibuddy-ios"
        case .watchOS: "flibuddy-watch"
        }
    }

    /// `CFBundleShortVersionString`; `dev` without one (swift test, a bare binary).
    public static func version(info: [String: Any]?) -> String {
        let text = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "dev" : text
    }

    /// The `hello` `app` field, cut to the protocol's 40 characters.
    public static func app(_ family: PlatformInfo.Family, info: [String: Any]?) -> String {
        String("\(appName(family))/\(version(info: info))".prefix(Hello.maxField))
    }

    /// The running app's version.
    public static var version: String { version(info: Bundle.main.infoDictionary) }
}

/// Pages the apps link to (privacy policy, support); published with the
/// project's GitHub Pages.
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://sokogen.github.io/flipperzero-flibuddy/privacy/")!
    public static let support = URL(string: "https://sokogen.github.io/flipperzero-flibuddy/support/")!
}
