import Foundation
import Testing
@testable import FliBuddyCore

private let flipperA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let flipperB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

private func found(_ id: UUID, _ name: String = "Flipper Anmaa1") -> DiscoveredPeripheral {
    DiscoveredPeripheral(id: id, name: name, rssi: -60)
}

private func makeTransport(_ central: FakeCentral, peripheral: UUID?) -> BLETransport {
    BLETransport(central: central, peripheral: peripheral, scanTimeout: .milliseconds(200), connectTimeout: .milliseconds(200))
}

@Suite("BLETransport")
struct BLETransportTests {
    @Test func connectingSubscribesAndKeepsTheHelloSentOnSubscribe() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        central.peripheral(flipperA).onSubscribe = try Message.flipperHello.encodedLine()
        let transport = makeTransport(central, peripheral: flipperA)

        try await transport.connect()

        #expect(transport.state == .open)
        #expect(transport.connectedPeripheral == flipperA)
        let messages = await Collector.draining(transport.messages)
        #expect(await eventually { await messages.items == [.flipperHello] })
    }

    @Test func notificationsSplitMidLineReassemble() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        let messages = await Collector.draining(transport.messages)

        let scan = Message.scan(try fixtureScan())
        try central.peripheral(flipperA).notify(scan, size: 7)

        #expect(await eventually { await messages.items == [scan] })
    }

    @Test func aRememberedPeripheralIsConnectedWithoutAScan() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)

        try await transport.connect()

        #expect(central.scanCount == 0)
        #expect(central.connected == [flipperA])
    }

    @Test func anUnknownIdentifierIsScannedFor() async throws {
        let central = FakeCentral()
        central.advertise(found(flipperB, "Flipper Other"))
        central.advertise(found(flipperA))
        let transport = makeTransport(central, peripheral: flipperA)

        try await transport.connect()

        #expect(central.scanCount == 1)
        #expect(central.connected == [flipperA])
        #expect(await eventually { central.activeScans == 0 })
    }

    @Test func withoutAPeripheralTheFirstOneFoundIsUsed() async throws {
        let central = FakeCentral()
        let transport = makeTransport(central, peripheral: nil)
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            central.advertise(found(flipperB))
        }

        try await transport.connect()

        #expect(central.connected == [flipperB])
        #expect(transport.requestedPeripheral == nil)
    }

    @Test func nothingFoundReportsPeripheralNotFound() async {
        let central = FakeCentral()
        central.advertise(found(flipperB))
        let transport = makeTransport(central, peripheral: flipperA)

        await #expect(throws: TransportError.peripheralNotFound) { try await transport.connect() }
        #expect(transport.state == .closed)
        #expect(await eventually { central.activeScans == 0 })
    }

    @Test func aConnectionThatNeverCompletesTimesOutAndIsCancelled() async {
        let central = FakeCentral()
        central.known = [flipperA]
        central.connectHangs = true
        let transport = makeTransport(central, peripheral: flipperA)

        await #expect(throws: TransportError.peripheralNotFound) { try await transport.connect() }
        #expect(central.cancelled == [flipperA])
        #expect(transport.state == .closed)
    }

    @Test func aPeripheralWithoutTheServiceIsRefused() async {
        let central = FakeCentral()
        central.known = [flipperA]
        central.withoutService = true
        let transport = makeTransport(central, peripheral: flipperA)

        await #expect(throws: TransportError.serviceNotFound) { try await transport.connect() }
        #expect(central.cancelled == [flipperA])
        #expect(transport.state == .closed)
    }

    @Test(arguments: [
        (BLEPowerState.poweredOff, TransportError.bluetoothOff),
        (.unauthorized, .bluetoothUnauthorized),
        (.unsupported, .bluetoothUnsupported),
    ])
    func bluetoothThatIsNotOnIsReported(power: BLEPowerState, error: TransportError) async {
        let central = FakeCentral()
        central.power = power
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)

        await #expect(throws: error) { try await transport.connect() }
        #expect(central.connected.isEmpty)
    }

    @Test func aLongLineGoesOutAsSeveralWritesEachAfterTheLastConfirmation() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let peripheral = central.peripheral(flipperA)
        peripheral.maximumWriteValueLength = 182
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        let intent = Message.intent(try fixtureIntent("intent_new"))
        let line = try intent.encodedLine()
        #expect(line.count > 2 * 182)

        try transport.send(intent)

        #expect(peripheral.writes.count == 1)
        var confirmed = 0
        while peripheral.writes.count > confirmed {
            confirmed += 1
            peripheral.confirmWrite()
            #expect(peripheral.writes.count <= confirmed + 1)
        }
        #expect(peripheral.writes.allSatisfy { $0.count <= 182 })
        #expect(peripheral.writes.count == (line.count + 181) / 182)
        #expect(peripheral.writes.reduce(Data(), +) == line)
    }

    @Test func linesQueuedWhileAWriteIsInFlightFollowInOrder() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let peripheral = central.peripheral(flipperA)
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()

        try transport.send(.hostHello)
        try transport.send(.flipperHello)
        while peripheral.writes.count < 20 {
            let before = peripheral.writes.count
            peripheral.confirmWrite()
            if peripheral.writes.count == before { break }
        }

        let expected = try Message.hostHello.encodedLine() + Message.flipperHello.encodedLine()
        #expect(peripheral.writes.reduce(Data(), +) == expected)
    }

    @Test func sendingWhileClosedFails() {
        let transport = makeTransport(FakeCentral(), peripheral: flipperA)
        #expect(throws: TransportError.notConnected) { try transport.send(.hostHello) }
    }

    @Test func aDisconnectFinishesTheStream() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        let messages = await Collector.draining(transport.messages)

        central.peripheral(flipperA).drop()

        #expect(await eventually { await messages.finished })
        #expect(transport.state == .closed)
        #expect(throws: TransportError.notConnected) { try transport.send(.hostHello) }
    }

    @Test func bluetoothGoingOffFinishesTheStream() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        let messages = await Collector.draining(transport.messages)

        central.powerOff()

        #expect(await eventually { await messages.finished })
        #expect(transport.state == .closed)
        await #expect(throws: TransportError.bluetoothOff) { try await transport.connect() }
    }

    @Test func aFailedWriteDropsTheConnection() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        let messages = await Collector.draining(transport.messages)
        try transport.send(.hostHello)

        central.peripheral(flipperA).failWrite()

        #expect(await eventually { await messages.finished })
        #expect(central.cancelled == [flipperA])
        #expect(transport.state == .closed)
    }

    @Test func disconnectingCancelsTheConnectionAndAReconnectStartsAFreshStream() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let peripheral = central.peripheral(flipperA)
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        let first = await Collector.draining(transport.messages)
        try transport.send(.hostHello)
        // Half a line arrives before the link drops; it must not leak into the next one.
        peripheral.notify(Data("{\"t\":\"sc".utf8))

        transport.disconnect()

        #expect(await eventually { await first.finished })
        #expect(central.cancelled == [flipperA])
        try await transport.connect()
        #expect(central.connected == [flipperA, flipperA])
        let second = await Collector.draining(transport.messages)
        try peripheral.notify(.flipperHello)
        #expect(await eventually { await second.items == [.flipperHello] })
        try transport.send(.hostHello)
        #expect(peripheral.writes.count == 2)
    }

    @Test func lateEventsOfAnOldConnectionAreIgnored() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let old = central.peripheral(flipperA)
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        transport.disconnect()
        let current = central.replacePeripheral(flipperA)
        try await transport.connect()
        let messages = await Collector.draining(transport.messages)
        try transport.send(.hostHello)
        #expect(current.writes.count == 1)

        // A confirmation, a notification and a disconnect from the old link.
        old.emitLate(.writeConfirmed)
        old.emitLate(.notification(try Message.flipperHello.encodedLine()))
        old.emitLate(.disconnected)
        old.emitLate(.writeFailed)

        try await Task.sleep(for: .milliseconds(50))
        #expect(current.writes.count == 1)
        #expect(old.writes.isEmpty)
        #expect(await messages.items.isEmpty)
        #expect(transport.state == .open)
        #expect(central.cancelled == [flipperA])
        // The current link still works.
        current.confirmWrite()
        #expect(current.writes.count == 2)
    }

    @Test func aDropWhileOpeningFailsTheConnect() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        central.peripheral(flipperA).dropsWhileOpening = true
        let transport = makeTransport(central, peripheral: flipperA)

        await #expect(throws: TransportError.notConnected) { try await transport.connect() }

        #expect(transport.state == .closed)
        // The connection is gone already: nothing to cancel.
        #expect(central.cancelled.isEmpty)
    }

    @Test func disconnectingNamesTheConnectionItDrops() async throws {
        // CoreBluetooth reuses the peripheral's identifier for every
        // connection; a late disconnect of an old one must not hit the new one.
        let central = FakeCentral()
        central.known = [flipperA]
        let old = central.peripheral(flipperA)
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()
        transport.disconnect()
        let current = central.replacePeripheral(flipperA)
        try await transport.connect()

        transport.disconnect()

        #expect(central.disconnectedLinks.count == 2)
        #expect(central.disconnectedLinks.first === old)
        #expect(central.disconnectedLinks.last === current)
    }

    @Test func connectingWhileOpenDoesNothing() async throws {
        let central = FakeCentral()
        central.known = [flipperA]
        let transport = makeTransport(central, peripheral: flipperA)
        try await transport.connect()

        try await transport.connect()

        #expect(central.connected == [flipperA])
    }

    @Test func disconnectingWhenClosedDoesNothing() {
        let central = FakeCentral()
        makeTransport(central, peripheral: flipperA).disconnect()
        #expect(central.cancelled.isEmpty)
    }

    @Test func bluetoothErrorsReadWell() {
        #expect(TransportError.bluetoothOff.localizedDescription == "Bluetooth is off")
        #expect(TransportError.peripheralNotFound.localizedDescription == "No Flipper found over Bluetooth")
        #expect(TransportError.bluetoothUnauthorized.localizedDescription.contains("Bluetooth"))
        #expect(TransportError.bluetoothUnsupported.localizedDescription.contains("Bluetooth"))
        #expect(TransportError.serviceNotFound.localizedDescription.contains("FliBuddy"))
    }

    @Test func theGATTIdentifiersMatchTheFlipperService() {
        #expect(FliBuddyGATT.service.uuidString == "51C07E84-E37E-4D52-AC6D-B2003116F506")
        #expect(FliBuddyGATT.rx.uuidString == "D250A7B1-D301-43F6-928E-BF2CA5D115BD")
        #expect(FliBuddyGATT.tx.uuidString == "C3AB2366-401D-482C-9002-B0A046C2A4E4")
    }
}

@Suite("BLEPromise")
struct BLEPromiseTests {
    @Test func aValueResolvedBeforeWaitingIsReturned() async throws {
        let promise = BLEPromise<Int>()
        promise.resolve(.success(7))
        #expect(promise.isResolved)
        #expect(try await promise.value() == 7)
    }

    @Test func aWaiterGetsALaterValueAndOnlyTheFirstCounts() async throws {
        let promise = BLEPromise<Int>()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            promise.resolve(.success(1))
            promise.resolve(.success(2))
        }
        #expect(try await promise.value() == 1)
    }

    @Test func resolvingSaysWhetherItCounted() async {
        let promise = BLEPromise<Int>()
        #expect(promise.resolve(.success(1)))
        #expect(!promise.resolve(.success(2)))

        let cancelled = BLEPromise<Int>()
        let waiter = Task { try await cancelled.value() }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        _ = try? await waiter.value
        #expect(!cancelled.resolve(.success(3)))
    }

    @Test func aFailureIsThrown() async {
        let promise = BLEPromise<Int>()
        promise.resolve(.failure(TransportError.serviceNotFound))
        await #expect(throws: TransportError.serviceNotFound) { try await promise.value() }
    }

    @Test func cancellingTheWaiterThrowsCancellationError() async {
        let promise = BLEPromise<Int>()
        let waiter = Task { try await promise.value() }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}
