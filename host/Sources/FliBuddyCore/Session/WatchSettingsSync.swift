import Foundation
import Observation

/// The part of `WCSession` the settings sync uses, so the sync logic is
/// tested with a fake. `WatchConnectivitySession` is the real one.
public protocol SessionMessaging: AnyObject, Sendable {
    /// WatchConnectivity works on this device (it does not on iPad).
    var isSupported: Bool { get }
    /// Activation finished; sending before that fails.
    var isActivated: Bool { get }
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

    private let session: any SessionMessaging
    private let debounce: Duration
    private var pending: SettingsSyncPayload?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// `debounce` zero sends each save at once.
    public init(session: any SessionMessaging, debounce: Duration = .zero) {
        self.session = session
        self.debounce = debounce
    }

    public func settingsSaved(_ settings: Settings) {
        pending = SettingsSyncPayload(settings)
        guard debounce > .zero else { return flush() }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
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
        guard let pending else { return }
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
            Log.debug(.sync, "held: reason=\(held)")
            return
        }
        do {
            // The payload carries the API key: only its version is logged.
            try session.updateApplicationContext(pending.dictionary)
            self.pending = nil
            lastError = nil
            Log.info(.sync, "sent: v=\(SettingsSyncPayload.version)")
        } catch {
            lastError = error.localizedDescription
            Log.error(.sync, "send failed: error=\(error.localizedDescription)")
        }
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

    private var handlers: (StateHandler, ContextHandler) {
        lock.withLock { (onStateChange, onContext) }
    }

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let (onStateChange, onContext) = handlers
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
        session.activate(
            onStateChange: { [weak sender] in Task { @MainActor in sender?.sessionStateChanged() } },
            onContext: { _ in }
        )
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
