import Foundation

/// What an empty feed says, the first thing missing first: a Bambuddy to
/// talk to, then a Flipper, then a scan (`HostModel.feedEmptyState`). The
/// server states use the Spools tab's words.
public enum FeedEmptyState: Equatable, Sendable {
    /// No Bambuddy URL or API key.
    case noServer
    /// The saved address is `http://` where only `https://` is allowed.
    case needsHTTPS
    /// No Flipper connected (none chosen yet, or it is not found).
    case noFlipper
    case noScans

    /// What the button under the text does.
    public enum Action: Equatable, Sendable {
        case openSettings
        /// Opens Settings and starts Scan for Flipper there.
        case scanForFlipper
    }

    public struct Content: Equatable, Sendable {
        public let title: String
        public let systemImage: String
        public let message: String
        public let action: Action?

        public var actionTitle: String? {
            switch action {
            case .openSettings: SpoolsViewModel.Action.openSettings.title
            case .scanForFlipper: "Scan for Flipper"
            case nil: nil
            }
        }
    }

    public var content: Content {
        switch self {
        case .noServer: Self.content(SpoolsViewModel.Unavailable.connectBambuddy)
        case .needsHTTPS: Self.content(SpoolsViewModel.Unavailable.needsHTTPS)
        case .noFlipper:
            Content(
                title: "Find your Flipper", systemImage: "antenna.radiowaves.left.and.right",
                message: "Open FliBuddy on the Flipper (Apps\u{00A0}\u{2192}\u{00A0}NFC).", action: .scanForFlipper
            )
        case .noScans:
            Content(
                title: "No scans yet", systemImage: "wave.3.right",
                message: "Hold a spool's tag to the Flipper running FliBuddy.", action: nil
            )
        }
    }

    private static func content(_ unavailable: SpoolsViewModel.Unavailable) -> Content {
        Content(
            title: unavailable.title, systemImage: unavailable.systemImage, message: unavailable.message,
            action: .openSettings
        )
    }

    /// `settings` lack a server, then the Flipper is not connected.
    public static func of(settings: Settings, requiresHTTPS: Bool, flipperConnected: Bool) -> FeedEmptyState {
        if Settings.isRefusedHTTP(settings.baseURL, requireHTTPS: requiresHTTPS) { return .needsHTTPS }
        if !settings.namesAServer { return .noServer }
        return flipperConnected ? .noScans : .noFlipper
    }
}

extension Settings {
    /// A URL and an API key are set; a key the locked Keychain could not
    /// read still counts.
    public var namesAServer: Bool {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !url.isEmpty && (apiKeyUnknown || !trimmedAPIKey.isEmpty)
    }
}
