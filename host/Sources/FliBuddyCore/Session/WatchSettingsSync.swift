import Foundation
import Observation

/// Where the settings sync stands, for the iPhone's Settings screen. `nil`
/// (see `WatchSettingsSender.state`) when there is no paired watch or nothing to send.
public enum WatchSyncState: Equatable, Sendable {
    /// The last settings went to the watch.
    case sent
    /// A watch is paired but FliBuddy is not installed on it.
    case installApp
    /// The settings wait until the watch app runs.
    case openWatchApp
    /// The last send failed.
    case failed
}

/// The part of `WCSession` the settings sync uses, so the sync logic is
/// tested with a fake. `WatchConnectivitySession` is the real one.
public protocol SessionMessaging: AnyObject, Sendable {
    /// WatchConnectivity works on this device (it does not on iPad).
    var isSupported: Bool { get }
    /// Activation finished; sending before that fails.
    var isActivated: Bool { get }
    /// On the iPhone, a watch is paired with it (the watch app may be missing).
    var isPaired: Bool { get }
    /// The other side has the app: on the iPhone, a paired watch with the
    /// watch app installed.
    var isCounterpartInstalled: Bool { get }
    func updateApplicationContext(_ context: [String: Any]) throws
}

/// iPhone side: sends the settings to the watch after each save. Saves that
/// follow each other within `debounce` (the iPhone applies every change as
/// it is made) send once, the latest. A save the session cannot send yet
/// (not activated, no watch app, a failed send) is held and sent on the next
/// `sessionStateChanged()`; only the latest counts.
@MainActor
@Observable
public final class WatchSettingsSender {
    /// How long `start(for:)` waits for further changes before it sends.
    public static let defaultDebounce: Duration = .milliseconds(500)

    /// Why the last send failed, until one succeeds.
    public private(set) var lastError: String?
    /// The sync for the Settings screen; `nil` without a paired watch, and
    /// until there is something to send.
    public private(set) var state: WatchSyncState?
    /// The settings as they are now. A held send is built from them when it
    /// goes out, so it never carries what was current at an earlier save.
    @ObservationIgnored public var settingsProvider: (@MainActor () -> Settings)?

    private let session: any SessionMessaging
    private let debounce: Duration
    private var pending: SettingsSyncPayload?
    /// The last key the sender saw; an empty key after a non-empty one is a clear.
    private var lastKey = ""
    /// The key was cleared and the watch has not been told yet.
    private var clearPending = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// The reason the last flush was held, so each is logged once.
    private var lastHold: String?
    private var hasSent = false

    /// `debounce` zero sends each save at once.
    public init(session: any SessionMessaging, debounce: Duration = .zero) {
        self.session = session
        self.debounce = debounce
    }

    /// Remembers the key the settings loaded with, without sending: an
    /// unconfigured launch queues nothing, but a later clear must still
    /// propagate.
    public func seed(_ settings: Settings) {
        if !settings.apiKeyUnknown { lastKey = settings.trimmedAPIKey }
    }

    public func settingsSaved(_ settings: Settings) {
        pending = payload(for: settings)
        guard debounce > .zero else { return flush() }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// The payload for `settings`; follows the key: an empty key after a
    /// non-empty one is a clear, sent until it goes out.
    private func payload(for settings: Settings) -> SettingsSyncPayload {
        var payload = SettingsSyncPayload(settings)
        if !settings.apiKeyUnknown {
            let key = settings.trimmedAPIKey
            if !key.isEmpty {
                clearPending = false
            } else if !lastKey.isEmpty {
                clearPending = true
            }
            lastKey = key
            // An empty key is sent only as the user's clear, never as "not known".
            if key.isEmpty { payload.apiKey = clearPending ? "" : nil }
        }
        return payload
    }

    /// Returns once a debounced send has run.
    public func settled() async {
        await debounceTask?.value
    }

    /// The session activated or the watch app was installed.
    public func sessionStateChanged() {
        flush()
    }

    private func flush() {
        if pending != nil, let settings = settingsProvider?() { pending = payload(for: settings) }
        guard let pending else { return refreshState() }
        let held: String? = if !session.isSupported {
            "unsupported"
        } else if !session.isActivated {
            "not activated"
        } else if !session.isCounterpartInstalled {
            "no watch app"
        } else {
            nil
        }
        if let held {
            if held != lastHold { Log.notice(.sync, "held: reason=\(held)") }
            lastHold = held
            return refreshState()
        }
        lastHold = nil
        do {
            // The payload carries the API key: only its version is logged.
            try session.updateApplicationContext(pending.dictionary)
            self.pending = nil
            hasSent = true
            if pending.apiKey == "" { clearPending = false }
            lastError = nil
            Log.info(.sync, "sent: v=\(SettingsSyncPayload.version)")
        } catch {
            lastError = error.localizedDescription
            Log.error(.sync, "send failed: error=\(error.localizedDescription)")
        }
        refreshState()
    }

    private func refreshState() {
        let new: WatchSyncState?
        if !session.isSupported || !session.isPaired {
            new = nil
        } else if lastError != nil {
            new = .failed
        } else if pending == nil {
            new = hasSent ? .sent : nil
        } else if !session.isCounterpartInstalled {
            new = .installApp
        } else {
            new = .openWatchApp
        }
        if state != new { state = new }
    }
}

/// Watch side: stores settings that arrive from the iPhone through
/// `HostModel.apply`, which saves them and reconfigures the session. The
/// watch keeps its own transport and Flipper.
@MainActor
@Observable
public final class WatchSettingsReceiver {
    /// Why the last payload was rejected or could not be saved.
    public private(set) var lastError: String?
    /// When settings last arrived (the watch's Settings footer).
    public private(set) var lastReceived: Date?

    private let host: HostModel
    /// Keeps the WatchConnectivity delegate alive (`WCSession` holds it weakly).
    @ObservationIgnored fileprivate var connection: AnyObject?

    public init(host: HostModel) {
        self.host = host
    }

    public func receive(_ result: Result<SettingsSyncPayload, SettingsSyncError>) async {
        let payload: SettingsSyncPayload
        switch result {
        case .success(let value): payload = value
        case .failure(let error):
            lastError = error.localizedDescription
            Log.error(.sync, "rejected: error=\(error.localizedDescription)")
            return
        }
        Log.info(.sync, "received: v=\(SettingsSyncPayload.version)")
        lastReceived = .now
        let settings = payload.applied(to: host.settings)
        do {
            // The context is delivered again on every activation.
            if settings != host.settings {
                try await host.apply(settings)
                Log.info(.sync, "applied")
            } else {
                Log.info(.sync, "unchanged")
            }
            lastError = nil
        } catch {
            lastError = Session.describe(error)
            Log.error(.sync, "apply failed: error=\(Session.describe(error))")
        }
    }
}

#if canImport(WatchConnectivity)
import WatchConnectivity

/// `SessionMessaging` on the default `WCSession`. Delegate callbacks arrive on
/// a background queue; contexts are decoded there and handed on as a
/// `Sendable` result. Checked on devices, not unit-tested.
public final class WatchConnectivitySession: NSObject, SessionMessaging, WCSessionDelegate, @unchecked Sendable {
    public typealias StateHandler = @Sendable () -> Void
    public typealias ContextHandler = @Sendable (Result<SettingsSyncPayload, SettingsSyncError>) -> Void

    private let session = WCSession.default
    private let lock = NSLock()
    private var onStateChange: StateHandler = {}
    private var onContext: ContextHandler = { _ in }

    override public init() {
        super.init()
    }

    /// Activates the session where it is supported. `onStateChange` runs after
    /// activation and when the watch app is installed or removed; `onContext`
    /// gets each context from the other side, including the last one received
    /// while the app was not running.
    public func activate(onStateChange: @escaping StateHandler, onContext: @escaping ContextHandler) {
        lock.withLock {
            self.onStateChange = onStateChange
            self.onContext = onContext
        }
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    public var isSupported: Bool { WCSession.isSupported() }
    public var isActivated: Bool { session.activationState == .activated }

    public var isPaired: Bool {
        #if os(iOS)
        session.isPaired
        #else
        true
        #endif
    }

    public var isCounterpartInstalled: Bool {
        #if os(iOS)
        session.isPaired && session.isWatchAppInstalled
        #else
        session.isCompanionAppInstalled
        #endif
    }

    public func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }

    /// What the session knows about the other side, for the log.
    private func watchFacts(_ session: WCSession) -> String {
        #if os(iOS)
        "paired=\(session.isPaired) watch_app_installed=\(session.isWatchAppInstalled)"
        #else
        "companion_installed=\(session.isCompanionAppInstalled)"
        #endif
    }

    private var handlers: (StateHandler, ContextHandler) {
        lock.withLock { (onStateChange, onContext) }
    }

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let (onStateChange, onContext) = handlers
        Log.notice(.sync, "activation: state=\(state.rawValue) error=\(error.map { Session.describe($0) } ?? "none") \(watchFacts(session))")
        onStateChange()
        let context = session.receivedApplicationContext
        if !context.isEmpty { onContext(SettingsSyncPayload.decode(context)) }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handlers.1(SettingsSyncPayload.decode(applicationContext))
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: activate for the new one.
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        Log.notice(.sync, "watch state: \(watchFacts(session))")
        handlers.0()
    }
    #endif
}

extension WatchSettingsSender {
    /// Sends `host`'s saved settings to the watch now and after every save.
    /// Keep the returned sender alive as long as `host`.
    public static func start(for host: HostModel) -> WatchSettingsSender {
        let session = WatchConnectivitySession()
        let sender = WatchSettingsSender(session: session, debounce: defaultDebounce)
        host.onSettingsSaved = { [weak sender] in sender?.settingsSaved($0) }
        sender.settingsProvider = { [weak host] in host?.settings ?? Settings() }
        host.watchSyncState = { [weak sender] in sender?.state }
        session.activate(
            onStateChange: { [weak sender] in Task { @MainActor in sender?.sessionStateChanged() } },
            onContext: { _ in }
        )
        // Even when nothing is sent yet, a later clear must propagate. Reading
        // the key again (`reloadSettings`) saves, which queues the send.
        sender.seed(host.settings)
        // A watch app installed after the last save still gets the settings.
        if host.settings.isConfigured { sender.settingsSaved(host.settings) }
        return sender
    }
}

extension WatchSettingsReceiver {
    /// Applies settings from the iPhone to `host` as they arrive. Keep the
    /// returned receiver alive as long as `host`.
    public static func start(for host: HostModel) -> WatchSettingsReceiver {
        let session = WatchConnectivitySession()
        let receiver = WatchSettingsReceiver(host: host)
        session.activate(
            onStateChange: {},
            onContext: { [weak receiver] result in Task { @MainActor in await receiver?.receive(result) } }
        )
        receiver.connection = session
        return receiver
    }
}
#endif
