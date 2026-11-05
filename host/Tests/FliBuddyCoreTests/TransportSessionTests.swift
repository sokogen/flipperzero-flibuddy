import Foundation
import Testing
@testable import FliBuddyCore

@Suite struct TransportSessionTests {
    private let hostHello = Hello(app: "flibuddy-mac/0.1.0", os: "macOS 26.0")
    private let flipperHello = Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1")

    /// `otherVersion`: the protocol version the fake Flipper reports, set
    /// before the session runs so a short hello timeout cannot fire first.
    private func start(
        helloTimeout: Duration = .seconds(30), otherVersion: Int? = nil
    ) async -> (FakeTransport, TransportSession, Collector<SessionEvent>, Task<Void, Error>) {
        let transport = FakeTransport()
        transport.otherVersion = otherVersion
        let session = TransportSession(transport: transport, hello: hostHello, helloTimeout: helloTimeout)
        let events = await Collector.draining(session.events)
        let run = Task { try await session.run() }
        // Lines delivered before run() connects would be lost.
        _ = await eventually { await session.state != .disconnected }
        return (transport, session, events, run)
    }

    @Test func theHandshakeIsLogged() async throws {
        let sink = try await capturingLog {
            let (transport, session, _, run) = await start()
            defer { run.cancel() }
            #expect(await eventually { await session.state == .waitingForHello })
            transport.deliver(.hello(flipperHello))
            #expect(await eventually { await session.state == .connected(flipperHello) })
            transport.disconnect()
            try await run.value
        }

        #expect(sink.events == [
            "link hello sent: app=flibuddy-mac/0.1.0 os=macOS 26.0",
            "link hello received: app=flibuddy-fap/0.1.0 fw=1.5.1",
        ])
    }

    @Test func aHelloTimeoutIsLogged() async throws {
        let sink = await capturingLog {
            let (transport, session, _, run) = await start(helloTimeout: .milliseconds(50))
            defer { run.cancel() }
            #expect(await eventually { await session.state == .noAnswer })
            transport.disconnect()
        }

        #expect(sink.events("link hello timeout:") == ["link hello timeout: after=50ms"])
        #expect(sink.lines.last?.level == .notice)
    }

    @Test func aSilentFlipperOfAnotherVersionSaysWhichVersionItSpeaks() async throws {
        let sink = await capturingLog {
            let (transport, session, events, run) = await start(helloTimeout: .milliseconds(50), otherVersion: 1)
            defer { run.cancel() }
            #expect(await eventually { await session.state == .otherVersion(1) })
            #expect(await eventually { await events.items == [.state(.waitingForHello), .state(.otherVersion(1))] })

            // a Flipper of this version that says hello after all connects
            transport.deliver(.hello(flipperHello))
            #expect(await eventually { await session.state == .connected(flipperHello) })
            transport.disconnect()
        }

        #expect(sink.events("link hello timeout:") == ["link hello timeout: after=50ms peer_version=1"])
    }

    @Test func defaultHelloTimeoutIsTwoSeconds() {
        #expect(TransportSession.defaultHelloTimeout == .seconds(2))
    }

    @Test func sendsHelloFirstAndWaitsForTheFlipper() async throws {
        let (transport, session, events, run) = await start()
        defer { run.cancel() }

        #expect(await eventually { await session.state == .waitingForHello })
        #expect(transport.sent == [.hello(hostHello)])
        #expect(await eventually { await events.items == [.state(.waitingForHello)] })
        transport.disconnect()
    }

    @Test func flipperHelloInTimeConnectsWithoutAReply() async throws {
        let (transport, session, events, run) = await start()
        defer { run.cancel() }
        #expect(await eventually { await session.state == .waitingForHello })

        transport.deliver(.hello(flipperHello))

        #expect(await eventually { await session.state == .connected(flipperHello) })
        // Our hello already went out; answering again would ping-pong with the Flipper.
        #expect(transport.sent == [.hello(hostHello)])
        #expect(await eventually {
            await events.items == [.state(.waitingForHello), .state(.connected(flipperHello))]
        })
        transport.disconnect()
    }

    @Test func noHelloWithinTheTimeoutMeansNoAnswer() async throws {
        let (transport, session, events, run) = await start(helloTimeout: .milliseconds(50))
        defer { run.cancel() }

        #expect(await eventually { await session.state == .noAnswer })
        #expect(await eventually { await events.items == [.state(.waitingForHello), .state(.noAnswer)] })
        transport.disconnect()
    }

    @Test func lateFlipperHelloConnectsAndIsAnswered() async throws {
        let (transport, session, _, run) = await start(helloTimeout: .milliseconds(50))
        defer { run.cancel() }
        #expect(await eventually { await session.state == .noAnswer })

        transport.deliver(.hello(flipperHello))

        #expect(await eventually { await session.state == .connected(flipperHello) })
        #expect(transport.sent == [.hello(hostHello), .hello(hostHello)])
        transport.disconnect()
    }

    @Test func flipperHelloAnsweringOurReplyIsNotAnsweredAgain() async throws {
        let (transport, session, _, run) = await start(helloTimeout: .milliseconds(200))
        defer { run.cancel() }
        #expect(await eventually { await session.state == .noAnswer })

        // Late hello -> we reply; the Flipper answers our reply right away.
        transport.deliver(.hello(flipperHello))
        #expect(await eventually { transport.sent.count == 2 })
        transport.deliver(.hello(flipperHello))
        try await Task.sleep(for: .milliseconds(50))

        #expect(transport.sent.count == 2)
        #expect(await session.state == .connected(flipperHello))
        transport.disconnect()
    }

    @Test func connectedLinkIgnoresTheTimeout() async throws {
        let (transport, session, _, run) = await start(helloTimeout: .milliseconds(300))
        defer { run.cancel() }
        transport.deliver(.hello(flipperHello))
        #expect(await eventually { await session.state == .connected(flipperHello) })
        // No reply: the hello came in time, so this tests the connected state, not a late hello.
        #expect(transport.sent == [.hello(hostHello)])

        try await Task.sleep(for: .milliseconds(400))
        #expect(await session.state == .connected(flipperHello))
        transport.disconnect()
    }

    @Test func otherMessagesAreRelayedInOrder() async throws {
        let (transport, session, events, run) = await start()
        defer { run.cancel() }
        let scan = try Message.decode(line: Fixtures.message("scan_ntag"))
        let intent = try Message.decode(line: Fixtures.message("intent_weigh"))
        #expect(await eventually { await session.state == .waitingForHello })

        transport.deliver(.hello(flipperHello))
        transport.deliver(scan)
        transport.deliver(intent)

        #expect(await eventually { await events.items.count == 4 })
        #expect(await events.items == [
            .state(.waitingForHello), .state(.connected(flipperHello)), .message(scan), .message(intent),
        ])
        transport.disconnect()
    }

    @Test func sendGoesThroughTheTransport() async throws {
        let (transport, session, _, run) = await start()
        defer { run.cancel() }
        let lookup = try Message.decode(line: Fixtures.message("lookup_found"))
        #expect(await eventually { await session.state == .waitingForHello })

        try await session.send(lookup)

        #expect(transport.sent == [.hello(hostHello), lookup])
        transport.disconnect()
    }

    @Test func droppedTransportEndsRunAndReportsDisconnected() async throws {
        let (transport, session, events, run) = await start()
        transport.deliver(.hello(flipperHello))
        #expect(await eventually { await session.state == .connected(flipperHello) })

        transport.disconnect()

        try await run.value
        #expect(await session.state == .disconnected)
        #expect(await eventually { await events.items.last == .state(.disconnected) })
        await #expect(throws: TransportError.notConnected) { try await session.send(.hostHello) }
    }

    @Test func disconnectStopsTheSession() async throws {
        let (_, session, _, run) = await start()
        #expect(await eventually { await session.state == .waitingForHello })

        await session.disconnect()

        try await run.value
        #expect(await session.state == .disconnected)
    }

    @Test func runAgainReconnectsAndSaysHelloAgain() async throws {
        let (transport, session, _, run) = await start()
        transport.deliver(.hello(flipperHello))
        #expect(await eventually { await session.state == .connected(flipperHello) })
        transport.disconnect()
        try await run.value

        let again = Task { try await session.run() }
        defer { again.cancel() }
        #expect(await eventually { await session.state == .waitingForHello })
        #expect(transport.connectCount == 2)
        #expect(transport.sent == [.hello(hostHello), .hello(hostHello)])
        transport.disconnect()
    }

    @Test func runWhileRunningThrows() async throws {
        let (transport, session, _, run) = await start()
        defer { run.cancel() }
        #expect(await eventually { await session.state == .waitingForHello })

        await #expect(throws: TransportSessionError.alreadyRunning) { try await session.run() }
        #expect(transport.connectCount == 1)
        transport.disconnect()
    }

    @Test func connectFailureIsThrownAndStaysDisconnected() async {
        let transport = FakeTransport()
        transport.connectError = TransportError.openFailed(path: "/dev/x", errno: ENOENT)
        let session = TransportSession(transport: transport, hello: hostHello)

        await #expect(throws: TransportError.openFailed(path: "/dev/x", errno: ENOENT)) { try await session.run() }
        #expect(await session.state == .disconnected)
        #expect(transport.sent.isEmpty)
    }

    #if os(macOS)
    @Test func handshakeOverARealPseudoTerminal() async throws {
        let pty = try PseudoTerminal()
        defer { pty.closeMaster() }
        let session = TransportSession(transport: SerialTransport(path: pty.slavePath), hello: hostHello)
        let events = await Collector.draining(session.events)
        let run = Task { try await session.run() }

        let hello = try #require(pty.readLine())
        #expect(hello == (try Message.hello(hostHello).encodedLine()))
        pty.closeSlave()
        pty.write(try Message.hello(flipperHello).encodedLine())
        #expect(await eventually { await session.state == .connected(flipperHello) })

        pty.write(try Message.decode(line: Fixtures.message("scan_mfc")).encodedLine())
        #expect(await eventually { await events.items.count == 3 })

        await session.disconnect()
        try await run.value
        #expect(await session.state == .disconnected)
    }
    #endif
}
