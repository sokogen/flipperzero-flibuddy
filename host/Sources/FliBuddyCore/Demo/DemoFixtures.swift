import Foundation

/// The hidden demo mode: the iPhone, iPad and watch apps started with
/// `-FliBuddyDemo YES` run against a connected demo Flipper ("Atgizo") and an
/// in-memory Bambuddy instead of Bluetooth and the network, so the screens
/// can be checked (and screenshotted) in the simulator. Nothing is persisted:
/// the settings live in memory stores, never in `UserDefaults` or the
/// Keychain. The rows follow the design fixtures (`seed()` and `INV` in
/// `docs/design/source/flibuddy-core.js`) at a fixed 09:41.
public enum DemoFixtures {
    /// The launch argument, followed by `YES`.
    public static let launchArgument = "-FliBuddyDemo"

    /// Whether the process was launched with `-FliBuddyDemo YES` (or `1`, `true`).
    public static func isRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return false }
        return ["yes", "1", "true"].contains(arguments[index + 1].lowercased())
    }

    /// Opens the demo on a pane for a screenshot (`tools/sim_shot.sh`), e.g.
    /// `-FliBuddyDemoPane spools`.
    public static let paneArgument = "-FliBuddyDemoPane"

    /// The pane `-FliBuddyDemoPane` names, in the demo only; the app maps the
    /// name to its pane and ignores one it does not know.
    public static func requestedPane(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard isRequested(arguments), let index = arguments.firstIndex(of: paneArgument),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// What the demo starts as, for the first-run screens:
    /// `-FliBuddyDemoState fresh` (no settings at all) or `noFlipper`
    /// (Bambuddy set up, no Flipper chosen); else connected.
    public static let stateArgument = "-FliBuddyDemoState"

    public enum State: String, Sendable {
        case connected
        case fresh
        case noFlipper

        /// The demo's settings in this state.
        var settings: Settings {
            switch self {
            case .connected: DemoFixtures.settings
            case .fresh: Settings(transport: .bluetooth)
            case .noFlipper:
                Settings(
                    baseURL: DemoFixtures.settings.baseURL, apiKey: DemoFixtures.settings.apiKey,
                    catalogEntryId: 1, coreWeight: 242, defaultMode: .gross, transport: .bluetooth
                )
            }
        }
    }

    /// The state `-FliBuddyDemoState` names, in the demo only.
    public static func requestedState(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> State {
        guard isRequested(arguments), let index = arguments.firstIndex(of: stateArgument),
              index + 1 < arguments.count else { return .connected }
        return State(rawValue: arguments[index + 1]) ?? .connected
    }

    /// The demo's host: the fixtures' settings, Bambuddy and Flipper; the
    /// feed fills once `start()` connects the Flipper.
    @MainActor
    public static func makeHost(state: State = requestedState()) -> HostModel {
        makeEnvironment(state: state).host
    }

    // MARK: - Settings

    public static let flipperName = "Atgizo"
    static let flipperId = UUID(uuidString: "4F1B5A2E-9C3D-4E7A-8B6F-0D2C1A9E7B35")!

    /// A configured HTTPS Bambuddy with a placeholder key, the Bambu catalog
    /// entry and the paired demo Flipper.
    public static let settings = Settings(
        baseURL: "https://bambuddy.example.com", apiKey: "demo-key", catalogEntryId: 1, coreWeight: 242,
        defaultMode: .gross, transport: .bluetooth, peripheralId: flipperId, peripheralName: flipperName
    )

    public static let catalog = [
        CatalogEntry(id: 1, name: "Bambu Lab - Reusable spool + refill", weight: 242),
        CatalogEntry(id: 2, name: "Bambu Lab - Plastic Low Temp", weight: 250),
        CatalogEntry(id: 3, name: "Bambu Lab - Cardboard", weight: 160),
        CatalogEntry(id: 4, name: "Polymaker - Cardboard", weight: 140),
        CatalogEntry(id: 5, name: "Sunlu - Plastic", weight: 165),
    ]

    // MARK: - Clock

    /// 09:41 on the day the demo was made, in the device's time zone.
    public static let clockTime: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 41))!
    }()

    static let archivedAt = "2026-11-05T09:20:00"

    // MARK: - Tags

    /// A Bambu tag of the demo: what `bambuTag` writes into the blocks.
    struct BambuSpec {
        var uid: String
        var materialId: String
        var variantId: String
        var material: String
        var detailedType: String
        var rgba: String
        var labelWeight = 1000

        var dump: TagDump {
            DemoFixtures.bambuTag(
                uid: uid, materialId: materialId, variantId: variantId, material: material,
                detailedType: detailedType, rgba: rgba, labelWeight: labelWeight
            )
        }

        var parsed: ParsedTag { TagParser.parse(dump) }
    }

    static let bambuGreen = BambuSpec(
        uid: "91B4E7C2", materialId: "GFA00", variantId: "A00-G6", material: "PLA", detailedType: "PLA Basic",
        rgba: "00AE42FF"
    )
    static let pumpkinOrange = BambuSpec(
        uid: "7EF1AB04", materialId: "GFA00", variantId: "A00-A1", material: "PLA", detailedType: "PLA Basic",
        rgba: "FF9016FF"
    )
    static let jadeWhite = BambuSpec(
        uid: "E61F09B3", materialId: "GFA00", variantId: "A00-W1", material: "PLA", detailedType: "PLA Basic",
        rgba: "FFFFFFFF"
    )
    static let charcoal = BambuSpec(
        uid: "A1C3770E", materialId: "GFA01", variantId: "A01-K1", material: "PLA", detailedType: "PLA Matte",
        rgba: "000000FF"
    )
    static let petgBlack = BambuSpec(
        uid: "5B21C0DE", materialId: "GFG02", variantId: "G02-K0", material: "PETG", detailedType: "PETG HF",
        rgba: "000000FF"
    )
    /// Not in Bambuddy.
    static let pureBlue = BambuSpec(
        uid: "3C9D20F1", materialId: "GFA19", variantId: "A19-B00", material: "PLA", detailedType: "PLA Pure",
        rgba: "A4DBE8FF"
    )
    /// Added to Bambuddy on scan.
    static let silkGold = BambuSpec(
        uid: "8C33F05D", materialId: "GFA06", variantId: "A06-Y1", material: "PLA", detailedType: "PLA Silk+",
        rgba: "F4A925FF"
    )
    /// The Flipper asks the host to link it.
    static let petgWhite = BambuSpec(
        uid: "D40E19A7", materialId: "GFG02", variantId: "G02-W0", material: "PETG", detailedType: "PETG HF",
        rgba: "FFFFFFFF"
    )
    static let blankUid = "04A2C93B1F5E80"

    /// A Bambu MIFARE Classic dump in the layout `TagParser` reads: block 0
    /// with the UID, the ids in block 1, the type in 2 and 4, colour, label
    /// weight and 1.75 mm in 5, PLA temperatures in 6 and a tray UUID made
    /// from the UID in 9.
    static func bambuTag(
        uid: String, materialId: String, variantId: String, material: String, detailedType: String,
        rgba: String, labelWeight: Int
    ) -> TagDump {
        let uidBytes = (try? Hex.decode(uid, byteCount: 4, field: "uid")) ?? [0, 0, 0, 0]
        let bcc = uidBytes.reduce(0, ^)
        func text(_ value: String, _ count: Int) -> [UInt8] {
            Array((Array(value.utf8) + [UInt8](repeating: 0, count: count)).prefix(count))
        }
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        let color = (try? Hex.decode(rgba, byteCount: 4, field: "rgba")) ?? [0, 0, 0, 0xFF]
        let diameter = withUnsafeBytes(of: Float(1.75).bitPattern.littleEndian, Array.init)
        let block5 = color + u16(labelWeight) + [0, 0] + diameter + [0, 0, 0, 0]
        // Drying 55 °C for 8 h, bed type 1, bed 35 °C, nozzle 230 to 190 °C.
        let block6 = u16(55) + u16(8) + u16(1) + u16(35) + u16(230) + u16(190) + [0, 0, 0, 0]
        let block0 = uidBytes + [bcc, 0x08, 0x04, 0x00] + [UInt8](repeating: 0x62, count: 8)
        let tray = Array(repeating: uidBytes, count: 4).flatMap { $0 }
        return TagDump(
            type: .mfc, uid: uid, sak: 0x08, atqa: "0400",
            blocks: [
                0: block0, 1: text(variantId, 8) + text(materialId, 8), 2: text(material, 16),
                4: text(detailedType, 16), 5: block5, 6: block6, 9: tray,
            ]
        )
    }

    /// A blank NTAG215: the UID pages and an empty NDEF message.
    static func ntagTag(uid: String) -> TagDump {
        let bytes = (try? Hex.decode(uid, byteCount: 7, field: "uid")) ?? [UInt8](repeating: 0, count: 7)
        let bcc0 = 0x88 ^ bytes[0] ^ bytes[1] ^ bytes[2]
        let bcc1 = bytes[3] ^ bytes[4] ^ bytes[5] ^ bytes[6]
        return TagDump(
            type: .ntag, uid: uid, sak: 0x00, atqa: "0044",
            pages: [
                0: [bytes[0], bytes[1], bytes[2], bcc0], 1: Array(bytes[3...6]), 2: [bcc1, 0x48, 0x00, 0x00],
                3: [0xE1, 0x10, 0x3E, 0x00], 4: [0x03, 0x00, 0xFE, 0x00],
            ]
        )
    }

    // MARK: - Bambuddy

    /// `updated_at` this long before 09:41.
    private static func updated(_ minutes: Int) -> String {
        BambuddyDate.string(from: clockTime.addingTimeInterval(TimeInterval(-minutes * 60)))
    }

    private static let day = 24 * 60

    /// A spool for a demo Bambu tag, as an AMS or the Flipper adds it.
    private static func spool(_ id: Int, _ tag: BambuSpec, left: Int, lastScale: Int? = nil, updated: String) -> Spool {
        let parsed = tag.parsed
        return Spool(
            id: id, material: tag.material, subtype: parsed.bambuddySubtype, colorName: parsed.bambuColor?.name,
            rgba: tag.rgba, brand: NewSpool.bambuBrand, labelWeight: tag.labelWeight, coreWeight: 242,
            coreWeightCatalogId: 1, weightUsed: Double(tag.labelWeight - left), lastScaleWeight: lastScale,
            tagUid: parsed.bambuddyTagUid, trayUuid: parsed.trayUuid, tagType: ParsedTag.Kind.bambu.bambuddyTagType,
            materialNumber: parsed.bambuColor?.code, updatedAt: updated
        )
    }

    /// Twelve spools: `INV` of the design, the tags of `seed()` and a few
    /// untagged ones for Link to existing, each last updated a while before
    /// 09:41 (the design's `upd`).
    public static let spools: [Spool] = [
        spool(8, jadeWhite, left: 860, updated: updated(6 * day + 50)),
        spool(12, pumpkinOrange, left: 120, lastScale: 362, updated: updated(day + 200)),
        spool(14, petgBlack, left: 742, lastScale: 984, updated: updated(2 * day + 30)),
        spool(21, charcoal, left: 410, lastScale: 652, updated: updated(3 * day + 10)),
        Spool(
            id: 27, material: "PETG", colorName: "Transparent Blue", rgba: "2F6DB5FF", brand: "Sunlu",
            labelWeight: 1000, coreWeight: 165, coreWeightCatalogId: 5, weightUsed: 120, note: "drawer 3",
            updatedAt: updated(21 * day)
        ),
        Spool(
            id: 30, material: "PLA", subtype: "Silk", colorName: "Copper", rgba: "B87333FF", brand: "eSun",
            labelWeight: 1000, coreWeight: 172, weightUsed: 345, lastScaleWeight: 827, note: "opened in September",
            updatedAt: updated(12 * day + 5)
        ),
        Spool(
            id: 31, material: "TPU", subtype: "95A", colorName: "Red", rgba: "D62D20FF", brand: "Overture",
            labelWeight: 500, coreWeight: 150, weightUsed: 80, updatedAt: updated(35 * day)
        ),
        Spool(
            id: 33, material: "ASA", colorName: "White", rgba: "F4F4F4FF", brand: "Polymaker",
            labelWeight: 1000, coreWeight: 140, coreWeightCatalogId: 4, weightUsed: 10, lastScaleWeight: 1130,
            note: "enclosure parts", updatedAt: updated(60 * day)
        ),
        spool(35, bambuGreen, left: 590, updated: updated(4 * 60)),
        Spool(
            id: 36, material: "PLA", subtype: "Basic", colorName: "Black", rgba: "000000FF", brand: NewSpool.bambuBrand,
            labelWeight: 1000, coreWeight: 242, coreWeightCatalogId: 1, weightUsed: 770, updatedAt: updated(9 * day)
        ),
        Spool(
            id: 38, material: "PLA", subtype: "Matte", colorName: "Ivory White", rgba: "FFFFFFFF",
            brand: NewSpool.bambuBrand, labelWeight: 1000, coreWeight: 242, coreWeightCatalogId: 1, weightUsed: 0,
            updatedAt: updated(45)
        ),
        Spool(
            id: 40, material: "ABS", colorName: "Black", rgba: "000000FF", brand: NewSpool.bambuBrand,
            labelWeight: 1000, coreWeight: 242, coreWeightCatalogId: 1, weightUsed: 320, updatedAt: updated(16 * day)
        ),
    ]

    /// Bambuddy's names for the demo colours.
    public static let colorMap: ColorMap = {
        let tags = [bambuGreen, pumpkinOrange, jadeWhite, charcoal, petgBlack, pureBlue, silkGold, petgWhite]
        var byMaterial: [String: String] = [:]
        for tag in tags {
            guard let name = tag.parsed.bambuColor?.name else { continue }
            byMaterial["\(tag.detailedType.lowercased())|\(tag.rgba.prefix(6).lowercased())"] = name
        }
        return ColorMap(colors: ["000000": "Black", "ffffff": "White"], byMaterial: byMaterial)
    }()

    // MARK: - The feed

    /// One Flipper line of the script; a scan moves the clock to `at` first.
    struct Step: Sendable {
        var at: Date?
        var message: Message
    }

    private static func scan(_ minute: Int, _ id: String, _ tag: TagDump, autosave: Bool = false) -> Step {
        let at = clockTime.addingTimeInterval(TimeInterval((minute - 41) * 60))
        return Step(at: at, message: .scan(Scan(scanId: id, autosave: autosave, tag: tag)))
    }

    private static func intent(
        _ scanId: String, _ action: Intent.Action, _ tag: TagDump, grams: Int? = nil, mode: Intent.WeightMode? = nil
    ) -> Step {
        let intent = Intent(id: "\(scanId)-\(action.rawValue)", scanId: scanId, action: action, grams: grams, mode: mode, tag: tag)
        return Step(at: nil, message: .intent(intent))
    }

    /// What the demo Flipper sends, oldest first; the feed shows it newest
    /// first: Bambu Green waiting for a weight (590 g of 1000, 832 suggested),
    /// a blank NTAG, PLA Pure not in Bambuddy, Pumpkin Orange saved by the
    /// Flipper, PLA Silk+ added on scan, PETG HF the Flipper asks to link, and
    /// PLA Matte marked empty and archived.
    static let script: [Step] = [
        scan(20, "demo-0920", charcoal.dump),
        intent("demo-0920", .empty, charcoal.dump),
        scan(24, "demo-0924", petgWhite.dump),
        intent("demo-0924", .linkOnHost, petgWhite.dump),
        scan(27, "demo-0927", silkGold.dump, autosave: true),
        scan(30, "demo-0930", pumpkinOrange.dump),
        intent("demo-0930", .weigh, pumpkinOrange.dump, grams: 257, mode: .gross),
        scan(34, "demo-0934", pureBlue.dump),
        scan(37, "demo-0937", ntagTag(uid: blankUid)),
        scan(41, "demo-0941", bambuGreen.dump),
    ]

    /// Plays `script` into `session` one line at a time, as the Flipper
    /// would, moving `clock` before each scan.
    static func play(on session: Session, clock: DemoClock) async {
        Log.info(.session, "demo: playing \(script.count) fixture lines")
        for step in script {
            if let at = step.at { clock.set(at) }
            _ = await session.handle(step.message)
        }
        let rows = await session.rows.count
        Log.info(.session, "demo: feed ready, rows=\(rows)")
    }

    // MARK: - The host

    @MainActor
    static func makeEnvironment(
        state: State = .connected, linkWaitsForChosenFlipper: Bool = TransportKind.available == [.bluetooth]
    ) -> DemoEnvironment {
        let defaults = InMemoryKeyValueStore()
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        do {
            try store.save(state.settings)
        } catch {
            // In-memory stores do not fail.
            Log.error(.settings, "demo: settings not saved: \(Session.describe(error))")
        }
        let clock = DemoClock()
        let inventory = DemoInventory(now: clock.now)
        let player = DemoPlayer(clock: clock)
        // Settings without a server make no Bambuddy, as the real factory.
        let makeInventory: @Sendable (Settings) throws -> any SpoolInventory = { settings in
            _ = try settings.makeClient()
            return inventory
        }
        let host = HostModel(
            store: store,
            makeInventory: makeInventory,
            makeTransport: { _ in DemoTransport(onConnect: { player.playOnce() }) },
            discoverPorts: { [] },
            scanPeripherals: {
                AsyncStream { continuation in
                    continuation.yield(DiscoveredPeripheral(id: flipperId, name: flipperName, rssi: -52))
                    continuation.finish()
                }
            },
            bluetoothPower: { .poweredOn },
            now: { clock.now() },
            linkWaitsForChosenFlipper: linkWaitsForChosenFlipper
        )
        player.session = host.session
        Log.notice(.app, "demo: fixture mode, state=\(state.rawValue), no Bluetooth, no network, settings in memory")
        return DemoEnvironment(
            host: host, inventory: inventory, defaults: defaults, secrets: secrets, makeInventory: makeInventory
        )
    }
}

/// The demo host and what tests look at behind it.
struct DemoEnvironment {
    let host: HostModel
    let inventory: DemoInventory
    let defaults: InMemoryKeyValueStore
    let secrets: InMemorySecretStore
    let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
}

/// The demo's clock: still, at the time the script last set.
final class DemoClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = DemoFixtures.clockTime

    func now() -> Date { lock.withLock { date } }

    func set(_ new: Date) { lock.withLock { date = new } }
}

/// Plays the script on the first Flipper connect only: a reconnect (another
/// Flipper chosen in Settings) keeps the feed as it is.
private final class DemoPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: DemoClock
    private var played = false
    private var target: Session?

    init(clock: DemoClock) {
        self.clock = clock
    }

    var session: Session? {
        get { lock.withLock { target } }
        set { lock.withLock { target = newValue } }
    }

    func playOnce() {
        let session: Session? = lock.withLock {
            guard !played, let target else { return nil }
            played = true
            return target
        }
        guard let session else { return }
        let clock = clock
        Task { await DemoFixtures.play(on: session, clock: clock) }
    }
}
