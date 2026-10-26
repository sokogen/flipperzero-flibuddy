import Foundation
import Testing
@testable import SpoolBuddyCore

private let hostHello = Hello(app: "spoolbuddy-mac/0.1.0", os: "macOS 26.0")

@MainActor
private func makeLink(
    _ transport: FakeTransport, ports: [String] = ["/dev/cu.usbmodemflip_A"],
    opened: LockedBox<[String]> = LockedBox([])
) -> (FlipperLink, Session) {
    let session = Session(settings: testSettings, inventory: FakeInventory(spools: [knownSpool()]))
    let link = FlipperLink(
        session: session, hello: hostHello,
        makeTransport: { path in
            opened.mutate { $0.append(path) }
            return transport
        },
        discoverPorts: { ports },
        retryDelay: .milliseconds(50)
    )
    return (link, session)
}

/// A value shared with `@Sendable` closures in tests.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

@MainActor
@Suite("FlipperLink")
struct FlipperLinkTests {
    @Test func connectingSaysHelloAndFollowsTheHandshake() async {
        let transport = FakeTransport()
        let (link, _) = makeLink(transport)

        link.connect(port: "/dev/cu.usbmodemflip_A")
        defer { link.disconnect() }

        #expect(await eventually { transport.sent == [.hello(hostHello)] })
        #expect(await eventually { link.state == .waitingForHello })
        transport.deliver(.flipperHello)
        #expect(await eventually { if case .connected = link.state { true } else { false } })
        #expect(link.port == "/dev/cu.usbmodemflip_A")
    }

    @Test func aScanIsAnsweredWithALookup() async throws {
        let transport = FakeTransport()
        let (link, session) = makeLink(transport)
        link.connect(port: nil)
        defer { link.disconnect() }
        #expect(await eventually { transport.state == .open })

        transport.deliver(.scan(try fixtureScan()))

        #expect(await eventually { transport.sent.count == 2 })
        #expect(transport.sent.last == .lookup(try fixtureLookup("lookup_found")))
        #expect(await session.rows.count == 1)
    }

    @Test func withoutAChosenPortTheFirstFlipperIsUsed() async {
        let transport = FakeTransport()
        let opened = LockedBox<[String]>([])
        let (link, _) = makeLink(transport, ports: ["/dev/cu.usbmodemflip_B", "/dev/cu.usbmodemflip_C"], opened: opened)

        link.connect(port: nil)
        defer { link.disconnect() }

        #expect(await eventually { opened.value.first == "/dev/cu.usbmodemflip_B" })
        #expect(await eventually { link.port == "/dev/cu.usbmodemflip_B" })
    }

    @Test func noFlipperIsReportedAndRetried() async {
        let transport = FakeTransport()
        let ports = LockedBox<[String]>([])
        let session = Session(settings: testSettings, inventory: nil)
        let link = FlipperLink(
            session: session, hello: hostHello, makeTransport: { _ in transport },
            discoverPorts: { ports.value }, retryDelay: .milliseconds(20)
        )

        link.connect(port: nil)
        defer { link.disconnect() }

        #expect(await eventually { link.problem == FlipperLink.noFlipperFound })
        #expect(link.state == .disconnected)
        ports.mutate { $0 = ["/dev/cu.usbmodemflip_A"] }
        #expect(await eventually { transport.state == .open })
        #expect(await eventually { link.problem == nil })
    }

    @Test func aDroppedLinkReconnects() async {
        let transport = FakeTransport()
        let (link, _) = makeLink(transport)
        link.connect(port: nil)
        defer { link.disconnect() }
        #expect(await eventually { transport.connectCount == 1 && transport.state == .open })

        transport.disconnect()

        #expect(await eventually { transport.connectCount == 2 && transport.state == .open })
        #expect(await eventually { link.state == .waitingForHello })
    }

    @Test func aPortThatWillNotOpenIsReported() async {
        let transport = FakeTransport()
        transport.connectError = TransportError.openFailed(path: "/dev/cu.usbmodemflip_A", errno: 16)
        let (link, _) = makeLink(transport)

        link.connect(port: "/dev/cu.usbmodemflip_A")
        defer { link.disconnect() }

        #expect(await eventually { link.problem != nil })
        #expect(link.state == .disconnected)
        #expect(await eventually { transport.connectCount >= 2 })
    }

    @Test func disconnectingClosesThePortAndStops() async {
        let transport = FakeTransport()
        let (link, _) = makeLink(transport)
        link.connect(port: nil)
        #expect(await eventually { transport.state == .open })

        link.disconnect()

        #expect(transport.state == .closed)
        #expect(link.state == .disconnected)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(transport.connectCount == 1)
    }

    @Test func statusTexts() {
        #expect(FlipperLink.statusText(.disconnected, problem: nil) == "Flipper: not connected")
        #expect(FlipperLink.statusText(.disconnected, problem: "No Flipper found") == "Flipper: No Flipper found")
        #expect(FlipperLink.statusText(.waitingForHello, problem: nil) == "Flipper: waiting for the app")
        #expect(FlipperLink.statusText(.noAnswer, problem: nil) == "Flipper: no answer; open SpoolBuddy on the Flipper")
        #expect(
            FlipperLink.statusText(.connected(Hello(app: "spoolbuddy-fap/0.1.0", fw: "1.5.1")), problem: nil)
                == "Flipper: connected (firmware 1.5.1)"
        )
    }

    @Test func transportErrorsReadWell() {
        #expect(TransportError.openFailed(path: "/dev/cu.x", errno: 16).localizedDescription == "Cannot open /dev/cu.x: Resource busy")
        #expect(TransportError.writeTimedOut.localizedDescription == "Writing to the Flipper timed out")
    }

    @Test func bambuddyStatusTexts() {
        #expect(BambuddyState.ready.statusText == "Bambuddy: ready")
        #expect(BambuddyState.unchecked.statusText == "Bambuddy: not checked yet")
        #expect(BambuddyState.notConfigured.statusText == "Bambuddy: \(BambuddyState.notConfigured.message!)")
        #expect(BambuddyState.unreachable("Bambuddy unreachable: timed out").statusText == "Bambuddy unreachable: timed out")
    }
}
