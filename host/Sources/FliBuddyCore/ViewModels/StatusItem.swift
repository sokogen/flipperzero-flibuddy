import Foundation

/// One item of the status bar: a short phrase with its symbol and tint, the
/// action offered next to it, and the full story for the tooltip.
public struct StatusItem: Equatable, Sendable {
    /// What the button next to the phrase does. `HostModel.perform(_:)` runs
    /// all but `settings`, which the view opens.
    public enum Action: Equatable, Sendable {
        case connect
        case check
        case retry
        case settings

        public var title: String {
            switch self {
            case .connect: "Connect"
            case .check: "Check"
            case .retry: "Retry"
            case .settings: "Settings"
            }
        }
    }

    public var text: String
    public var symbol: StatusSymbol
    public var tint: StatusTint
    public var action: Action?
    /// The reason behind a short phrase (an error, the port, the firmware).
    public var detail: String?

    public init(text: String, symbol: StatusSymbol, tint: StatusTint, action: Action? = nil, detail: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.action = action
        self.detail = detail
    }
}

extension FlipperLink {
    /// The Flipper half of the status bar. Not finding a Flipper is
    /// "searching" (the link keeps retrying); any other reason the link is
    /// down is shown as it is. A stopped link offers Connect.
    public static func statusItem(
        _ state: LinkState, choice: TransportChoice?, port: String?, problem: String?, isActive: Bool
    ) -> StatusItem {
        guard isActive else {
            return StatusItem(
                text: "Flipper nearby, not connected", symbol: .symbol("antenna.radiowaves.left.and.right"),
                tint: .orange, action: .connect, detail: problem
            )
        }
        switch state {
        case .disconnected where problem != nil && !notFoundProblems.contains(problem ?? ""):
            return StatusItem(
                text: problem ?? "", symbol: .symbol("antenna.radiowaves.left.and.right.slash"), tint: .orange,
                detail: problem
            )
        case .disconnected, .waitingForHello:
            return StatusItem(text: "No Flipper \u{00B7} searching", symbol: .progress, tint: .gray, detail: problem)
        case .noAnswer:
            return StatusItem(text: "Open FliBuddy on the Flipper", symbol: .symbol("app.dashed"), tint: .orange)
        case .connected(let hello):
            let firmware = hello.fw.map { "firmware \($0)" }
            if case .bluetooth = choice {
                return StatusItem(
                    text: "Flipper \u{00B7} Bluetooth", symbol: .symbol("antenna.radiowaves.left.and.right"),
                    tint: .green, detail: firmware
                )
            }
            let detail = [port, firmware].compactMap { $0 }.joined(separator: " \u{00B7} ")
            return StatusItem(
                text: "Flipper \u{00B7} USB", symbol: .symbol("cable.connector"), tint: .green,
                detail: detail.isEmpty ? nil : detail
            )
        }
    }

    /// Problems that only mean no Flipper is there yet.
    private static let notFoundProblems: Set<String> = [
        noFlipperFound, TransportError.peripheralNotFound.localizedDescription,
    ]

    public var statusItem: StatusItem {
        Self.statusItem(state, choice: choice, port: port, problem: problem, isActive: isActive)
    }
}

extension BambuddyState {
    /// The Bambuddy half of the status bar. A check under way spins whatever
    /// the last state was; a colour map that failed to load only matters
    /// once Bambuddy is ready.
    public func statusItem(colorNamesProblem: String? = nil, isChecking: Bool = false) -> StatusItem {
        if isChecking {
            return StatusItem(text: "Checking Bambuddy\u{2026}", symbol: .progress, tint: .gray)
        }
        let lock = StatusSymbol.symbol("lock.trianglebadge.exclamationmark")
        switch self {
        case .unchecked:
            return StatusItem(
                text: "Bambuddy \u{00B7} not checked", symbol: .symbol("server.rack"), tint: .gray, action: .check
            )
        case .notConfigured:
            return StatusItem(
                text: "Bambuddy not set up", symbol: .symbol("server.rack"), tint: .orange, action: .settings,
                detail: message
            )
        case .ready:
            if let colorNamesProblem {
                return StatusItem(
                    text: "Bambuddy ready \u{00B7} colour names unavailable", symbol: .symbol("paintpalette"),
                    tint: .orange, detail: colorNamesProblem
                )
            }
            return StatusItem(text: "Bambuddy ready", symbol: .symbol("server.rack"), tint: .green)
        case .unreachable(let reason):
            return StatusItem(
                text: "Bambuddy unreachable", symbol: .symbol("wifi.exclamationmark"), tint: .red, action: .retry,
                detail: reason
            )
        case .refused(.permissionMissing):
            return StatusItem(
                text: "API key lacks inventory permission", symbol: lock, tint: .red, action: .settings,
                detail: message
            )
        case .refused(.unauthorized):
            return StatusItem(
                text: "Bambuddy rejected the API key", symbol: lock, tint: .red, action: .settings, detail: message
            )
        case .refused(.spoolmanMode):
            return StatusItem(
                text: "Bambuddy is in Spoolman mode", symbol: .symbol("nosign"), tint: .red, action: .retry,
                detail: message
            )
        }
    }
}
