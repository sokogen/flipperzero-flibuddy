#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import Testing
@testable import FliBuddyCore

/// A peripheral as the central sees it; the test sets its state.
final class FakeCBPeripheral: CentralPeripheral, @unchecked Sendable {
    let identifier: UUID
    private let lock = NSLock()
    private var _state: CBPeripheralState = .disconnected
    private var _links: [FakeCentralLink] = []

    init(_ identifier: UUID) {
        self.identifier = identifier
    }

    var state: CBPeripheralState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    /// The links made for its connections, oldest first.
    var links: [FakeCentralLink] { lock.withLock { _links } }

    func makeLink(queue: DispatchQueue) -> any CentralLink {
        let link = FakeCentralLink(identifier: identifier)
        lock.withLock { _links.append(link) }
        return link
    }
}

final class FakeCentralLink: CentralLink, @unchecked Sendable {
    let identifier: UUID
    private let lock = NSLock()
    private var _lost = false

    init(identifier: UUID) {
        self.identifier = identifier
    }

    var lost: Bool { lock.withLock { _lost } }
    var maximumWriteValueLength: Int { 20 }
    func open(service: UUID, rx: UUID, tx: UUID, events: @escaping @Sendable (BLELinkEvent) -> Void) async throws {}
    func write(_ data: Data) {}
    func connectionLost() { lock.withLock { _lost = true } }
}

/// `CBCentralManager` as far as the central uses it, recorded.
final class FakeCBManager: CentralManager, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: CBManagerState = .poweredOn
    private var _connects: [UUID] = []
    private var _cancels: [UUID] = []
    var known: [UUID: FakeCBPeripheral] = [:]

    var state: CBManagerState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    var connects: [UUID] { lock.withLock { _connects } }
    var cancels: [UUID] { lock.withLock { _cancels } }
    var isScanning: Bool { false }

    func connect(_ peripheral: any CentralPeripheral) {
        lock.withLock { _connects.append(peripheral.identifier) }
    }

    func cancelConnection(_ peripheral: any CentralPeripheral) {
        lock.withLock { _cancels.append(peripheral.identifier) }
    }

    func retrieve(_ id: UUID) -> (any CentralPeripheral)? {
        lock.withLock { known[id] }
    }

    func scan(services: [CBUUID]) {}
    func stopScan() {}
}

private let flipper = UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")!

/// The task's value; a task still running after `timeout` is cancelled, so
/// a connect that is never answered fails the test instead of hanging it.
private func finish<T: Sendable>(_ task: Task<T, any Error>, within timeout: Duration = .seconds(2)) async throws -> T {
    let watchdog = Task {
        try await Task.sleep(for: timeout)
        task.cancel()
    }
    defer { watchdog.cancel() }
    return try await task.value
}

@Suite("CoreBluetoothCentral")
struct CoreBluetoothCentralTests {
    /// A central on a fake manager that knows `flipper`.
    private func makeCentral() -> (CoreBluetoothCentral, FakeCBManager, FakeCBPeripheral) {
        let manager = FakeCBManager()
        let peripheral = FakeCBPeripheral(flipper)
        manager.known[flipper] = peripheral
        let central = CoreBluetoothCentral { _, _ in manager }
        #expect(central.knowsPeripheral(flipper))
        return (central, manager, peripheral)
    }

    /// Starts a connect; the test waits for what the manager is asked.
    private func startConnect(
        _ central: CoreBluetoothCentral
    ) -> Task<any BLEPeripheralLink, any Error> {
        Task { try await central.connect(flipper) }
    }

    @Test func aConnectAnswersWithTheLinkOfDidConnect() async throws {
        let (central, manager, peripheral) = makeCentral()
        let connecting = startConnect(central)
        #expect(await eventually { manager.connects == [flipper] })

        peripheral.state = .connected
        central.onQueue { central.handleConnected(peripheral) }

        let link = try await finish(connecting)
        #expect(link === peripheral.links.first)
    }

    @Test func aConnectWaitsForTheDisconnectOfACancelledAttempt() async throws {
        let (central, manager, peripheral) = makeCentral()
        let abandoned = startConnect(central)
        #expect(await eventually { manager.connects == [flipper] })
        peripheral.state = .connecting
        abandoned.cancel()
        #expect(await eventually { manager.cancels == [flipper] })

        let connecting = startConnect(central)
        try await Task.sleep(for: .milliseconds(50))
        // The cancelled attempt is still going away.
        #expect(manager.connects == [flipper])

        peripheral.state = .disconnected
        central.onQueue { central.handleDisconnected(peripheral) }
        #expect(manager.connects == [flipper, flipper])
        central.onQueue { central.handleConnected(peripheral) }
        _ = try await finish(connecting)
    }

    @Test func aCancelledAttemptGoneWithoutACallbackNoLongerBlocksConnects() async throws {
        let (central, manager, peripheral) = makeCentral()
        let abandoned = startConnect(central)
        #expect(await eventually { manager.connects == [flipper] })
        abandoned.cancel()
        #expect(await eventually { manager.cancels == [flipper] })
        // iOS dropped the attempt but never sent didDisconnect.
        peripheral.state = .disconnected

        let connecting = startConnect(central)
        #expect(await eventually { manager.connects == [flipper, flipper] })
        central.onQueue { central.handleConnected(peripheral) }
        _ = try await finish(connecting)
    }

    @Test(arguments: [CBManagerState.resetting, .unknown])
    func aResetDropsConnectionsAndAttemptsLikePowerOff(_ state: CBManagerState) async throws {
        let (central, manager, peripheral) = makeCentral()
        // A connection being cancelled and a newer attempt waiting for it.
        let first = startConnect(central)
        #expect(await eventually { manager.connects == [flipper] })
        peripheral.state = .connected
        central.onQueue { central.handleConnected(peripheral) }
        let link = try #require(try await finish(first) as? FakeCentralLink)
        central.disconnect(link)
        #expect(await eventually { manager.cancels == [flipper] })
        let waiting = startConnect(central)
        try await Task.sleep(for: .milliseconds(50))

        manager.state = state
        central.onQueue { central.handleState(state) }

        await #expect(throws: TransportError.notConnected) { try await finish(waiting) }
        #expect(link.lost)
        // Nothing is left closing: the next attempt after the reset goes ahead at once.
        manager.state = .poweredOn
        peripheral.state = .disconnected
        central.onQueue { central.handleState(.poweredOn) }
        let next = startConnect(central)
        #expect(await eventually { manager.connects == [flipper, flipper] })
        next.cancel()
    }

    @Test func aResetLeavesThePowerStateUnknownUntilTheRadioSettles() async throws {
        let (central, manager, _) = makeCentral()
        manager.state = .resetting
        central.onQueue { central.handleState(.resetting) }
        let power = Task { await central.powerState() }
        try await Task.sleep(for: .milliseconds(50))

        manager.state = .poweredOn
        central.onQueue { central.handleState(.poweredOn) }

        #expect(await power.value == .poweredOn)
    }

    @Test func powerOffFailsAWaitingConnectAsBluetoothOff() async throws {
        let (central, manager, _) = makeCentral()
        let connecting = startConnect(central)
        #expect(await eventually { manager.connects == [flipper] })

        manager.state = .poweredOff
        central.onQueue { central.handleState(.poweredOff) }

        await #expect(throws: TransportError.bluetoothOff) { try await finish(connecting) }
    }

    @Test func aRestoreIdentifierInTheLaunchOptionsIsABluetoothRelaunch() {
        #expect(CoreBluetoothCentral.restores([CoreBluetoothCentral.restoreIdentifier]))
        #expect(!CoreBluetoothCentral.restores(["com.example.other"]))
        #expect(!CoreBluetoothCentral.restores(nil))
    }
}
#endif
