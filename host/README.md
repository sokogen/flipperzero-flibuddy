# FliBuddy host (Swift package)

The package builds with SwiftPM only; the iPhone/iPad and Apple Watch apps
in `Apple/` are thin XcodeGen shells over it (see below). No UI tests.

- `FliBuddyCore`: platform-neutral library (protocol models, tag parser,
  Bambuddy client, transport, session, view models). `TagParser` takes the
  tray UUID from block 9 of a Bambu tag, the block whose value matched the
  AMS-reported `tray_uuid` in Phase 0. Lookups try it first, then the UID,
  and new items and tag links store it. The UID goes to Bambuddy in the
  form an AMS writes (`ParsedTag.bambuddyTagUid`): for Bambu tags the UID
  followed by `00000100` (`7EF1AB04` → `7EF1AB0400000100`), NTAG UIDs as
  read; see `protocol/PROTOCOL.md`.
- `FliBuddyUI`: SwiftUI views shared by the macOS and iOS apps (the feed,
  the settings form with the Transport section, the New and Link sheets,
  the iOS QR scanner); macOS-only parts (the Settings link, the serial port
  picker) sit behind `#if os(macOS)`. `Watch/` holds the compact watch
  views (`#if os(watchOS)`): the feed list, a row detail with the weight on
  the Digital Crown, and a settings page. `FeedView`, `SettingsForm` and
  `UnknownRowActions` are not built for watchOS.
- `FliBuddyMac`: SwiftUI executable for macOS 14+: the app and the
  Settings window around `SettingsForm`.

The package supports macOS 14+, iOS 26+ and watchOS 26+. Off macOS
`SerialTransport` is a stub (no ports, connecting fails) and the `hello`
names the platform through `PlatformInfo` (`macOS 26.0`, `iOS 26.1`,
`iPadOS 26.1`, `watchOS 26.1`). To build the shared targets or run the
tests on the iOS simulator:

```
xcodebuild -scheme FliBuddyUI -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme FliBuddy-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```
- `FliBuddyCoreTests`: swift-testing suites (`import Testing`). The Command
  Line Tools have no XCTest, so the tests do not use it.

## Commands

```
cd host
swift build
swift test
swift run FliBuddyMac
```

If Xcode.app is installed but its license is not accepted, `swift` from
`/usr/bin` exits with 69. Use the Command Line Tools instead:

```
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test
```

## Running the Mac app

```
cd host
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift run FliBuddyMac
```

`swift run` starts a plain executable, not an `.app` bundle; the app makes
itself a regular app (Dock icon, menu bar) at launch. Settings (⌘,) hold the
Bambuddy URL and API key (stored in the login Keychain, service
`FliBuddy`), the empty-spool catalog entry and the editable core weight
used for new items, the default weight mode and the transport: USB with
the Flipper port ("Automatic" opens the first `/dev/cu.usbmodemflip_*`), the
default on the Mac, or Bluetooth (see below). Use **Test connection** after
entering the key; it also loads the catalog. Nothing applies until **Save**
(Return); **Revert** drops the edits, and the line beside them reads
"Unsaved changes" or "All changes saved".

`swift run` has no app bundle, so the Bluetooth usage description macOS asks
for lives in `Sources/FliBuddyMac/Info.plist`, linked into the executable's
`__TEXT,__info_plist` section with `-sectcreate` (`Package.swift`, macOS
only). It has no `CFBundleIdentifier` on purpose: one would move
`UserDefaults.standard` away from the `FliBuddyMac` domain that holds the
saved settings.
`SettingsStore` keeps the settings in a `KeyValueStore` (`UserDefaults` in
the apps, `InMemoryKeyValueStore` in the tests) and the API key in a
`SecretStore` (`KeychainSecretStore` in the apps).

The core weight is everything on the scale that is not filament (`net =
gross − core_weight`). It defaults to 325 g, a Bambu reusable spool (293 g)
plus a refill core (32 g), which fits sealed spools and mounted refills alike.
Choosing a catalog entry copies its weight once; the number stays editable
(1–5000 g) and is saved as entered; a value saved before (e.g. 250 g)
is kept, not replaced by the new default. The entry itself is sent only as
`core_weight_catalog_id`. AMS-added spools get their core weight from the
first "Bambu Lab" catalog entry in Bambuddy, so set that entry to 325 g as
well to keep both kinds of spool consistent.

After the startup check the session loads Bambuddy's colour map
(`GET /inventory/colors/map`, inventory read) once and keeps it; a settings
change reloads it. New items get `color_name` from it: the detailed type
and RGB first (`by_material`, e.g. `pla basic|ff9016`), then the RGB alone
(`colors`); with no match `color_name` is left out rather than set to the
hex. A failed load shows in the status bar, leaves names empty and never
blocks a scan; the next startup check retries it.

The view models (`FliBuddyCore/ViewModels`) are platform-neutral and
tested with `swift test`; the SwiftUI views in `FliBuddyUI` and
`FliBuddyMac` have no tests.

## The Mac window

The layout and copy follow `docs/design/macos-ui-spec.md`; its last section
lists where the app differs and why.

The window (default 1000 × 600, minimum 760 × 420) shows the session feed,
newest scan first, one line per tag: swatch, title and UID, colour and
remaining, status, then the weight entry (field, Net/Gross, **Save**) for
rows that wait for a weight. A scan of a tag already in the feed moves its
row to the top and reopens it; no second row. The newest row that waits
takes focus with the suggestion selected (remaining + core weight in gross,
remaining in net), so a correct suggestion costs one keystroke. While a
field holds a number you typed, a new scan does not take focus: the new row
gets a tinted outline and waits. After a save, focus moves to the newest
row still waiting. Switching Net/Gross converts an untouched suggestion and
keeps a typed number. The readout under the field shows what Save sends
("Saves 590 g left · 915 − 325 g core").

### Keyboard

| Action | Keys |
|---|---|
| Save the focused row | ⌘S, or Return in the field |
| Next / previous row | ⌘↓ / ⌘↑ |
| Field → mode → Save | ⇥ (⇧⇥ back; the picker and Save need keyboard navigation on) |
| Switch Net/Gross when the picker has focus | ← → |
| Clear the feed (asks first; nothing changes in Bambuddy) | ⌘⌫ |
| Settings | ⌘, |

### Row states

| Status | Meaning | What the row offers |
|---|---|---|
| Looking up | the host is asking Bambuddy about the tag, or creating it | nothing yet |
| Enter weight | a known spool | the weight entry |
| Saving… | the weight is on its way | the entry, disabled |
| Saved 590 g left · by host / by Flipper | the last save and who made it; after a host save that came later than the Flipper's 10 s, a note says the Flipper showed a timeout but the save went through | click the row (or the VoiceOver "Re-weigh" action) to weigh again |
| Created in Bambuddy | an unknown Bambu tag, created on scan (the Flipper's **Auto-save new** is on) with the tag's material, colour and label weight and the core weight from Settings | the entry, pre-filled with label + core; **Link to existing…** deletes the spool just created and links the tag to the chosen one |
| Not in Bambuddy | an unknown Bambu tag with Auto-save new off, or a tag with material that has no spool any more (the link after deleting the created spool failed, or the spool went away) | the entry, pre-filled with label + core; **Save** creates the spool, then records the weight; **New** (one step, from the tag) and **Link to existing…** |
| Not in Bambuddy; tag has no material | an NTAG or blank tag | **New…** (the New spool form) and **Link to existing…** |
| Updating… | Mark as new / empty or Delete from the Flipper on its way | the entry, disabled |
| Marked as new · 1000 g left · by Flipper | the spool is full again (restored first when it was archived) | click the row to weigh |
| Marked as empty · archived · by Flipper | remaining 0 and archived; the colour column reads `… · archived` | click the row to weigh; a Save restores the spool |
| Deleted from Bambuddy · by Flipper | the Flipper deleted the spool | **New** and **Link to existing…** |
| Flipper asks to create / link it here | the Flipper sent a request for this tag | the requested action is the prominent button |
| Error: … | the last Bambuddy call failed | on a spool, the entry keeps its value for a retry; after a failed create on scan, **New** and **Link to existing…** |

Whether an unknown Bambu tag is created on scan is up to the Flipper: its
Auto-save new setting travels in every `scan` (`autosave`), and the host has
no switch of its own. Lookups include archived spools, so a spool marked
empty and scanned again reads `Enter weight` with `… · archived` in the
colour column, and its Save restores it first. After New, Link, or a Save
that created the spool, the host pushes a fresh `lookup` for the row's scan
so a Flipper still showing that tag shows the spool.

A rescan of a tag created on scan finds that spool by tag and never creates
a second one; so does a retried Save on a `Not in Bambuddy` row whose create
went through and whose weight failed. If the delete behind **Link to existing…** fails, nothing
changes and the row says so; if the link fails after the delete, the row
has no spool and offers New and Link again.

### Status bar

Two items, the Flipper link and the Bambuddy check, each a phrase with a
symbol and a tint; the tooltip holds the detail (port, firmware, error).
The link reconnects on its own when the Flipper app is restarted or the
cable is replugged. Some items carry a button:

| Item | Button |
|---|---|
| Flipper nearby, not connected (the link is stopped) | Connect |
| Bambuddy · not checked | Check |
| Bambuddy unreachable | Retry |
| Bambuddy is in Spoolman mode (also replaces the feed until it is fixed) | Retry |
| API key lacks inventory permission, Bambuddy rejected the API key, Bambuddy not set up | Settings |

Connect starts the link with the saved transport; Check and Retry re-run
the startup check (`HostModel.perform(_:)`); Settings opens the Settings
window. The other items have no button: "No Flipper · searching" (spinner),
"Flipper · USB", "Flipper · Bluetooth", "Open FliBuddy on the Flipper" (the
port is open but no `hello` came within 2 s), "Flipper speaks protocol 1,
host speaks 2" (the Flipper answered in another protocol version; the
tooltip says which side to update), "Checking Bambuddy…",
"Bambuddy ready" and "Bambuddy ready · colour names unavailable".

## Bluetooth (`BLETransport`)

`Transport/BLE/BLETransport.swift` implements `Transport` over the FAP's
GATT service (UUIDs in `FliBuddyGATT.swift`, the table in
`flipper/README.md`). `connect()` waits for Bluetooth to power on,
connects to the remembered peripheral if the system still knows it, else
scans for the service (scan and connect each give up after 10 s with
`peripheralNotFound`), discovers RX and TX, subscribes to TX and only then
reports `.open`, so the `hello` the Flipper sends on subscription is kept.
`BLEChunker` cuts outgoing lines into writes of
`maximumWriteValueLength(for: .withoutResponse)`, which is ATT MTU - 3 (at
most 243 bytes), sends one write with response at a time, and reassembles TX notifications into lines
with `NDJSONFramer`. A disconnect, a failed write or Bluetooth turning off
finishes the message stream, and `FlipperLink` reconnects as it does on
USB. Errors: `bluetoothOff`, `bluetoothUnauthorized`,
`bluetoothUnsupported`, `peripheralNotFound`, `serviceNotFound`.

CoreBluetooth sits behind two protocols in `Central.swift`: `BLECentral`
(power, scan, retrieve, connect, cancel) and `BLEPeripheralLink`
(discovery and subscription, write, events). `CoreBluetoothCentral` is the
real adapter for macOS, iOS and watchOS and is not unit-tested; the tests
drive `BLETransport` with a fake central and never create the real one,
which would ask for Bluetooth permission.

`Settings` holds `transport` (`usb` default on macOS, `bluetooth`
elsewhere, where USB is not offered), `peripheralId` and `peripheralName`.
**Scan for Flipper** in the settings lists the Flippers found for 15 s
with their RSSI (the name from the peripheral, the advertised local name or
the scan response's manufacturer data, `FliBuddyGATT.displayName`; the FAP
advertises no name); choosing one stores it and selects Bluetooth. **Forget**
clears the remembered Flipper of the chosen transport (the USB port back to
Automatic, the Bluetooth peripheral to the first found); like every other
field it takes effect on **Save**. `HostModel` reconnects when the transport choice
changes (kind, port or peripheral), not on a rename. No pairing: the link
is unencrypted and carries no secrets.

## iPhone, iPad and Apple Watch apps (`Apple/`)

```
Apple/project.yml                XcodeGen spec: FliBuddyiOS (iPhone, iPad)
                                 with the FliBuddyWatch companion embedded
Apple/iOS/App.swift              NavigationSplitView (regular width) or
                                 TabView (compact) over FeedView and
                                 SettingsForm
Apple/Watch/App.swift            the watch app over the Watch/ views
Apple/Base.xcconfig              tracked; includes Signing.xcconfig if present
Apple/Signing.example.xcconfig   copy to Signing.xcconfig (git-ignored) and
                                 set DEVELOPMENT_TEAM
```

The apps have no logic of their own: everything is in `FliBuddyCore`
and `FliBuddyUI`, used as local package products. The Info.plists are
generated from `INFOPLIST_KEY_*` settings (Bluetooth on both, camera on the
iPhone app). `make apple-project` runs `xcodegen generate` and
`make apple-build` builds both schemes for the simulators with
`CODE_SIGNING_ALLOWED=NO` into `Apple/.build`; both need Xcode, not the
Command Line Tools. To run on a device, fill in `Signing.xcconfig` with a
team (a free personal team works; the install lasts 7 days), regenerate,
and run `FliBuddyiOS` from Xcode; the watch app installs with it.

### Settings sync to the watch

`Session/SettingsSync.swift`: `SettingsSyncPayload` is the Bambuddy URL,
API key, core weight, catalog entry id (left out when none) and default
mode, encoded as a WatchConnectivity application context with `v: 1`;
other versions and malformed fields are rejected.
`Session/WatchSettingsSync.swift` works behind a `SessionMessaging`
protocol (`WatchConnectivitySession` wraps `WCSession`):

- iPhone: `WatchSettingsSender` sends the payload with
  `updateApplicationContext` after every save (`HostModel.onSettingsSaved`)
  and once at launch when the settings are complete. A save it cannot send
  yet (session not activated, no watch app) is held and sent on the next
  session change. The iPad has no WatchConnectivity and sends nothing.
- Watch: `WatchSettingsReceiver` merges the payload onto the watch's own
  settings (the transport and the Flipper stay), stores it through
  `SettingsStore` (the key in the watch's Keychain), reconfigures
  `HostModel`, and ignores a payload equal to what it has. It also reads
  `receivedApplicationContext` on activation.

The watch then talks to Bambuddy itself. Its settings page shows what
arrived and **Scan for Flipper**. The weight model behind the Digital Crown
is `ViewModels/CrownWeight.swift` (0…9999 g, 1 g steps, 5 g from 20 g/s).

### API key from Bambuddy's QR code

`Session/APIKeyQRPayload.swift` parses
`bambuddy://config?v=1&url=<percent-encoded URL>&key=<percent-encoded key>`
(only `v=1`); the URL is normalised as Settings expects it.
`SettingsViewModel.applyQRPayload(_:)` fills the URL and key and reports
in `qrStatus`; `scanQRCode(with:)` takes any `QRScanning` scanner, so it is
tested without a camera. On iOS **Scan QR code** opens
`FliBuddyUI/QRScanner.swift`, a sheet over VisionKit's
`DataScannerViewController` reading QR codes. The button only shows where
the scanner is supported and available, so never in the simulator.

### `@ViewState` instead of `@State`

The macOS 27 SDK declares `@State` as a macro too, implemented in the
`SwiftUIMacros` compiler plugin that only Xcode ships. With the Command Line
Tools, `@State` fails with "plugin for module 'SwiftUIMacros' not found".
`Sources/FliBuddyUI/ViewState.swift` aliases the `State` property wrapper
struct as a public `ViewState`; use `@ViewState` in both SwiftUI targets.

## Debugging

Every link, wire, session, Bambuddy and settings event is logged through
`FliBuddyCore/Logging/Log.swift`, both to the unified log and to a plain
text file:

- macOS: `~/Library/Logs/FliBuddy/flibuddy.log` (Help ▸ **Show Log File**
  reveals it in Finder)
- iOS, iPadOS and watchOS: `Logs/flibuddy.log` in the app's Application
  Support directory (download the container from Xcode's Devices window)

The file has one event per line, `2026-10-26T13:04:05.123+0300 INFO link
state: waitingForHello -> connected`, and rotates at 5 MB to `flibuddy.log.1`,
`.2` and `.3`. The first line of each run is `app start: …` with the
version, platform, log file and level. Follow it while scanning a tag:

```
tail -f ~/Library/Logs/FliBuddy/flibuddy.log
```

The level is `info` by default. The Mac app reads `FLIBUDDY_LOG`
(`debug`, `info`, `notice`, `error`); `debug` adds the wire lines and
Bambuddy's response bodies:

```
cd host
FLIBUDDY_LOG=debug swift run FliBuddyMac
```

The iPhone, iPad and watch apps always log at `info`. The same lines go to
the unified log, subsystem `com.sokolachko.flibuddy`, with one category
per kind of event:

```
log stream --level debug --predicate 'subsystem == "com.sokolachko.flibuddy"'
log show --last 1h --info --predicate 'subsystem == "com.sokolachko.flibuddy" && category == "bambuddy"'
```

The unified log keeps `info` and `debug` lines in memory only, so `log show`
finds them for a short while at best; the file keeps them.

| Category | Records |
| --- | --- |
| `app` | the start line, written whatever the level; a log file that cannot be written (unified log only, once) |
| `link` | connect and disconnect, link state changes with the problem, retries, the serial port opening and closing (with `errno`), Bluetooth scan, peripherals found (name, RSSI), services, MTU, disconnects, the hello handshake |
| `wire` | each protocol line sent (`tx`) and received (`rx`) at `debug`, cut to 300 characters; dropped lines at `error` with the reason |
| `session` | Bambuddy state changes, scans, lookups with their outcome and time, intents and results, creating, linking and deleting spools, colour map failures |
| `bambuddy` | each request's method, path, status and time; errors with Bambuddy's `detail`; response bodies at `debug` |
| `settings` | settings load and save (`key=present` or `absent`), Keychain failures with the `OSStatus`, **Test connection** and catalog loads |
| `sync` | watch settings sync: payloads sent, held, received, applied or rejected, by version only |
| `ui` | reserved; nothing logs to it yet |

The API key is never logged: settings lines only say whether a key is
present, and `Log.redact` replaces any `bb_…` key, any `key=`, `X-API-Key`
or `apiKey` value and the `user:password@` of a URL with `«redacted»` before
a line reaches the unified log or the file. Neither the QR payload nor the
sync payload is logged.

## Protocol fixtures

The tests read the shared contract in `protocol/fixtures/` as package
resources. `Tests/FliBuddyCoreTests/Fixtures` is a committed symlink to
`../../../protocol/fixtures`, declared as `.copy("Fixtures")` in
`Package.swift`; SwiftPM follows the symlink and copies the directory into
the test bundle on every build, picking up added, changed and removed
fixtures. Tests load it with `Bundle.module.url(forResource: "Fixtures",
withExtension: nil)`.

If the symlink is lost (for example on a checkout with `core.symlinks=false`),
recreate it:

```
cd host/Tests/FliBuddyCoreTests && ln -s ../../../protocol/fixtures Fixtures
```

## swift-testing with the Command Line Tools

The Command Line Tools (Swift 6.4) install the swift-testing macro plugin in
`usr/lib/swift/host/plugins/testing/`, but its rpath is `@loader_path/..`,
which points at `plugins/` instead of `host/` where the swift-syntax
libraries live. The compiler then fails with "plugin for module
'TestingMacros' not found".

`Toolchain/clt-testing-plugin/` mirrors the layout the plugin expects with
symlinks into the Command Line Tools. When `DEVELOPER_DIR` starts with
`/Library/Developer/CommandLineTools`, `Package.swift` adds it to the test
target with `-plugin-path`. With Xcode (CI) nothing changes. Remove the
workaround once a Command Line Tools release fixes the rpath.
