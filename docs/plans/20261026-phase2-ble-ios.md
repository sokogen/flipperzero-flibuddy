# Phase 2: Bluetooth LE transport, shared SwiftUI, iPad and iPhone app

## Overview
Phase 1 links the Flipper to a Mac over USB. Phase 2 adds Bluetooth LE on
both sides and an iOS/iPadOS app, so the owner can weigh spools with an iPad
or iPhone in hand. The design is in
`docs/superpowers/specs/2026-10-25-flipper-spoolbuddy-design.md`, section
"Phase 2: BLE transport, iPad and iPhone", whose verified facts (GATT UUIDs,
flow control, profile lifecycle, QR payload) bind this plan.

What changes:
- the Flipper app gets a BLE serial backend behind the existing `Transport`
  interface and a persisted transport setting (USB or Bluetooth);
- `SpoolBuddyCore` gets a CoreBluetooth `BLETransport` behind the existing
  Swift `Transport` protocol, with flow control, and settings for the
  transport kind and the remembered peripheral; macOS gains BLE too;
- the SwiftUI views move into a platform-neutral `SpoolBuddyUI` target;
- a new iOS app target is generated from an XcodeGen `project.yml`;
- iOS Settings can scan Bambuddy's API-key QR code;
- CI builds the iOS app for the simulator.

The wire protocol (`protocol/PROTOCOL.md`, the schema, the fixtures) does
not change. BLE carries the same NDJSON lines.

## Context (from discovery)
- Flipper transport interface: `flipper/src/transport.h` (`open`, `close`,
  `send_line`, `set_rx_callback`, `is_connected`); USB backend
  `flipper/src/transport_usb.c` with a worker thread, `line_buffer`,
  `line_sender` (packetised sends with a completion wait); the app wires the
  transport in `flipper/src/spoolbuddy_app.c`, hello handling in
  `flipper/src/host_link.c`, Idle screen in `flipper/src/scene_idle.c`.
- SDK 1.5.1 (in `flipper/.ufbt/current/sdk_headers`): `ble_profile_serial`,
  `ble_profile_serial_tx`, `ble_profile_serial_set_event_callback`,
  `ble_profile_serial_notify_buffer_is_empty`, `bt_profile_start`,
  `bt_profile_restore_default`, `bt_set_status_changed_callback`,
  `bt_disconnect`, `furi_hal_bt_is_active`, `saved_struct_load/save`,
  `storage_common_mkdir`. Headers:
  `targets/f7/ble_glue/profiles/serial_profile.h`,
  `targets/f7/ble_glue/services/serial_service.h`
  (`BLE_SVC_SERIAL_DATA_LEN_MAX` 486, `BLE_SVC_SERIAL_CHAR_VALUE_LEN_MAX` 243,
  `SerialServiceEvent{DataReceived, DataSent, BleResetRequest}`),
  `applications/services/bt/bt_service/bt.h` (`BtStatus{Unavailable, Off,
  Advertising, Connected}`). The Bt service record name is `RECORD_BT`.
- Host transport: `host/Sources/SpoolBuddyCore/Transport/Transport.swift`
  (protocol with `state`, `messages`, `connect`, `send`, `disconnect`),
  `SerialTransport.swift` (POSIX serial, `discoverFlipperPorts`),
  `TransportSession.swift`, `ViewModels/FlipperLink.swift` (reconnect loop,
  `makeTransport: (String) -> any Transport`, `discoverPorts`),
  `ViewModels/HostModel.swift`, `Session/Settings.swift` (`port`,
  `SettingsStore`, `KeychainSecretStore`), `ViewModels/SettingsViewModel.swift`.
- macOS views: `host/Sources/SpoolBuddyMac/{App,FeedView,SettingsView,UnknownRowActions,ViewState}.swift`.
- `host/Package.swift`: swift-tools 6.0, `platforms: [.macOS(.v14)]`,
  targets `SpoolBuddyCore`, `SpoolBuddyMac`, `SpoolBuddyCoreTests`
  (fixtures via a symlink resource), CLT plugin workaround.
- Tooling on the owner's Mac: Xcode 27.1 (license accepted), iOS 27.1 SDK
  and simulators, Homebrew; `xcodegen` not installed yet (`brew install
  xcodegen`). CI: `.github/workflows/host.yml` runs `swift test` on macOS.
- Bambuddy QR payload: `bambuddy://config?v=1&url=<encodeURIComponent(baseUrl)>&key=<encodeURIComponent(apiKey)>`
  (frontend `utils/apiKeyQr.ts`, version 1).

## Development Approach
- **Testing approach**: TDD. Write the failing test, then the code.
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Keep the wire protocol unchanged
- Hardware-only code (CoreBluetooth calls, Flipper BLE calls) sits behind
  small protocols or function tables so the logic around it is unit-tested
  with fakes; the thin adapters are read-reviewed and checked on hardware in
  Post-Completion
- Follow `AGENTS.md`: English everywhere in the repository, one commit per task
- Minimum OS versions: macOS 14 stays; iOS and iPadOS 26 (current major
  minus one, per the design)

## Testing Strategy
- **Unit tests**: required for every task (see Development Approach above)
- Suites: `make -C flipper/tests test`, `cd host && swift test`,
  `cd tools && uv run pytest`; `make test` runs all; `make lint`,
  `make coverage` gate the end; the iOS target is built for the simulator
  with `make ios-build`
- No e2e suite; pairing and BLE on real devices are Post-Completion

## Progress Tracking
- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in consuming projects, deployment configs, third-party verifications
- **Checkbox placement**: Checkboxes belong only in Task sections (`### Task N:` or `### Iteration N:`). Do not put checkboxes in Success criteria, Overview, or Context — they cause extra loop iterations.

## Implementation Steps

### Task 1: Package for two platforms and a shared SwiftUI target
- [x] `host/Package.swift`: `platforms: [.macOS(.v14), .iOS(.v26)]`; new library target `SpoolBuddyUI` (depends on `SpoolBuddyCore`) and product; `SpoolBuddyMac` depends on both
- [x] move `FeedView.swift`, `SettingsView.swift` (the `SettingsForm` part), `UnknownRowActions.swift` and `ViewState.swift` into `host/Sources/SpoolBuddyUI/`, make them `public` where the apps need them, and wrap macOS-only parts (`SwiftUI.Settings` scene, serial port picker, `.keyboardShortcut`, `NSApp`) in `#if os(macOS)`; `SpoolBuddyMac` keeps `App.swift` and the Settings scene wrapper only
- [x] `SerialTransport.discoverFlipperPorts()` returns `[]` and `SerialTransport.init` is unavailable off macOS (`#if os(macOS)` around the termios code, a stub that throws `TransportError.notConnected` elsewhere)
- [x] `HostModel.hostHello` reports the platform (`"macOS …"` / `"iOS …"` / `"iPadOS …"`) through a small `PlatformInfo` helper with a test
- [x] write tests: `PlatformInfo`, port discovery off macOS is empty (compile-time guarded test), existing suites still pass; `swift build` of `SpoolBuddyUI` for macOS succeeds
- [x] run all three suites - must pass before task 2
- ➕ deviations: the manifest uses `.iOS("26.0")` because `.v26` needs tools version 6.2; `.keyboardShortcut` stays unguarded (SwiftUI has it on iOS too); off macOS `SerialTransport.init` stays available (HostModel's default factory uses it) and the stub's `connect`/`send` throw `notConnected`; `SpoolBuddyMac/App.swift` has an `#else` stub `main` so the whole package (tests included) builds for iOS
- ➕ `xcodebuild test -scheme SpoolBuddy-Package -destination 'platform=iOS Simulator,…'` runs the suite on the iOS simulator (299 tests pass, the pty tests are macOS-only); `xcodebuild -scheme SpoolBuddyUI -destination 'generic/platform=iOS Simulator' build` succeeds

### Task 2: Flow-control and chunking model for BLE (pure Swift)
- [ ] `host/Sources/SpoolBuddyCore/Transport/BLEFlow.swift`: `BLEFlow` keeps the credit (bytes the Flipper will accept, from the flow-control characteristic, uint32 big-endian), the write size (`min(negotiatedMTU - 3, 243)`), and a queue of outgoing bytes; `enqueue(line)`, `nextChunk()` returns the next write (never longer than the write size nor the remaining credit, `nil` when nothing may be sent), `creditUpdated(_:)`, `writeConfirmed()`; lines longer than 8192 bytes are rejected as in PROTOCOL.md
- [ ] `BLEFlow` also reassembles inbound notifications into lines through `NDJSONFramer`
- [ ] write tests: credit parsing from 4 bytes; chunk sizes at MTU boundaries; no send with zero credit; credit refill resumes; a 2000-byte line crosses several chunks in order; inbound notifications split mid-line reassemble; empty and oversize inputs
- [ ] run all three suites - must pass before task 3

### Task 3: `BLETransport` on CoreBluetooth behind testable protocols
- [ ] `host/Sources/SpoolBuddyCore/Transport/BLE/Central.swift`: protocols `BLECentral` (state, scan for the service UUID, connect, retrieve a remembered peripheral by identifier, cancel) and `BLEPeripheralLink` (discover service and characteristics, set notify on TX and flow control, read flow control, write RX with response, events); `CoreBluetoothCentral` adapter implementing them on `CBCentralManager`/`CBPeripheral` (not unit-tested); `FakeCentral` in the test target
- [ ] `host/Sources/SpoolBuddyCore/Transport/BLE/BLETransport.swift`: implements `Transport` with `BLEFlow`: `connect()` scans or reconnects to the remembered identifier, discovers, subscribes, reads the initial credit, then reports `.open`; `send` enqueues and drains through `nextChunk`/`writeConfirmed`; disconnect or a central power-off finishes the `messages` stream; errors mapped to new `TransportError` cases (`bluetoothOff`, `unauthorized`, `peripheralNotFound`, `pairingFailed`)
- [ ] `FlipperLink`: a `TransportChoice` (`.usb(port:)` / `.bluetooth(peripheral:)`) replaces the port string; the reconnect loop and `isActive` behave the same for both; discovery of BLE peripherals exposed for the settings picker (name, identifier, RSSI)
- [ ] write tests with `FakeCentral`: connect/subscribe/credit handshake → `.open` and the Flipper hello reaches `messages`; a long `intent` is written as several chunks respecting credit; disconnect finishes the stream and `FlipperLink` retries; central off → `bluetoothOff`; unknown identifier → scan; remembered identifier → direct connect
- [ ] run all three suites - must pass before task 4

### Task 4: Transport settings on the host
- [ ] `Settings`: `transport: TransportKind` (`usb` default on macOS, `bluetooth` on iOS), `peripheralId: UUID?`, `peripheralName: String?`; `SettingsStore` persists them; `HostModel.apply` reconnects when the choice changes
- [ ] `SettingsViewModel`: transport picker, a list of discovered Flippers while scanning ("Scan for Flipper"), "Forget Flipper"; USB section only on macOS
- [ ] `SettingsForm` in `SpoolBuddyUI`: the Transport section for both platforms; the macOS window keeps its minimum size
- [ ] write tests: defaults per platform; persistence round trip; choosing a peripheral stores id and name; forget clears them; `HostModel` reconnects on a change of kind or peripheral and not otherwise
- [ ] run all three suites - must pass before task 5

### Task 5: Flipper settings and transport choice on the Idle screen
- [ ] `flipper/src/app_settings.{c,h}`: `AppSettings { uint8_t version; uint8_t transport; }` saved with `saved_struct_save`/`load` at `/ext/apps_data/spoolbuddy/settings.bin` (directory created with `storage_common_mkdir`); unreadable or wrong-version files load the defaults (USB); the file functions are isolated so the choice logic is host-testable
- [ ] Idle screen: OK opens a submenu "Transport: USB / Bluetooth"; choosing restarts the transport; the status line shows `USB`, `BLE adv`, `BLE` (connected, hello seen) or `no host`
- [ ] `app_state` reducer: transport kind and BLE status in the state, with the status-line text derived in `screen_text.c`
- [ ] write C tests: settings defaults and version handling (with a fake storage), reducer transitions for BLE statuses, status-line text for each state
- [ ] run all three suites - must pass before task 6

### Task 6: Flipper BLE transport
- [ ] `flipper/src/ble_lines.{c,h}` (host-tested, no SDK): outbound chunking at `BLE_PROFILE_SERIAL_PACKET_SIZE_MAX`, one packet in flight until `DataSent`, inbound bytes into `line_buffer`, a counter of consumed bytes that says when to grant new credit
- [ ] `flipper/src/transport_ble.c` implementing `Transport`: `open` records the Bt service (`furi_record_open(RECORD_BT)`), sets the status callback, `bt_profile_start(bt, ble_profile_serial, NULL)`, `ble_profile_serial_set_event_callback(profile, BUFFER, cb, ctx)`; the callback feeds `ble_lines` and calls `ble_profile_serial_notify_buffer_is_empty` once the received bytes are consumed; `send_line` uses `ble_profile_serial_tx` through `line_sender` with the `DataSent` wait; `is_connected` is `BtStatusConnected`; `close` disconnects, restores the default profile and closes the record; `BleResetRequest` closes and reopens
- [ ] `spoolbuddy_app.c`: pick the transport from `app_settings`; the hello is sent on BLE connect as it is on USB DTR; the USB CLI stays untouched while BLE is selected
- [ ] write C tests for `ble_lines` (chunk boundaries, in-flight gating, credit grant after consumption, partial lines) and for the app wiring that is pure; `ufbt` builds the FAP
- [ ] run all three suites - must pass before task 7

### Task 7: iOS app project with XcodeGen
- [ ] `host/iOS/project.yml`: target `SpoolBuddyiOS` (iOS 26, iPhone and iPad), depends on the local package products `SpoolBuddyCore` and `SpoolBuddyUI`; `Info.plist` keys `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`; bundle id `cool.bambuddy.spoolbuddy` placeholder; `Signing.xcconfig` is git-ignored and `Signing.example.xcconfig` carries `DEVELOPMENT_TEAM = `; CI builds with `CODE_SIGNING_ALLOWED=NO`
- [ ] `host/iOS/Sources/App.swift`: `@main` SwiftUI app with a `TabView` or `NavigationSplitView` over `FeedView` and the settings form from `SpoolBuddyUI`; `HostModel` constructed with the BLE transport factory
- [ ] root `Makefile`: `ios-project` (`xcodegen generate`), `ios-build` (`xcodebuild -scheme SpoolBuddyiOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`); `.gitignore` for `*.xcodeproj` under `host/iOS`
- [ ] write tests: the iOS app has no logic of its own; verify instead that `make ios-project ios-build` succeeds locally (record the command output in the plan) and that `swift test` still passes
- [ ] run all three suites and `make ios-build` - must pass before task 8

### Task 8: API key from Bambuddy's QR code
- [ ] `host/Sources/SpoolBuddyCore/Session/APIKeyQRPayload.swift`: `parse(_ string:) throws -> (baseURL: String, apiKey: String)` for `bambuddy://config?v=1&url=…&key=…`; errors for wrong scheme or host, unsupported `v`, missing or empty fields, invalid percent-encoding; the URL is normalised the way Settings expects (scheme and host, optional port, no trailing slash)
- [ ] `SettingsViewModel.applyQRPayload(_:)` fills `baseURL` and `apiKey` and sets a status line; a `QRScanning` protocol with a `scan() async throws -> String` entry so the view model is testable
- [ ] iOS only: "Scan QR code" button in the Settings form presenting a VisionKit `DataScannerViewController` (`.barcode(symbologies: [.qr])`) through a `UIViewControllerRepresentable`; unavailable device → the button is hidden
- [ ] write tests: valid payload; `bambuddy://config?v=2…` rejected; missing key rejected; percent-decoding of `http%3A%2F%2F192.168.1.10%3A8000`; view model applies and reports; a failing scanner leaves the fields untouched
- [ ] run all three suites - must pass before task 9

### Task 9: CI for the iOS build
- [ ] `.github/workflows/host.yml`: add a job on `macos-latest` that installs `xcodegen` with Homebrew, runs `make ios-project ios-build`; path filters include `host/iOS/**`
- [ ] `.github/workflows/README.md` documents the job and the signing policy
- [ ] write tests: `tools/tests/test_ci.py` checks the new job and the path filters as it does for the others
- [ ] run all three suites - must pass before task 10

### Task 10: Verify acceptance criteria
- [ ] verify every bullet of the Overview is implemented
- [ ] `protocol/` unchanged (`git diff --stat main...HEAD -- protocol` is empty)
- [ ] `make test`, `make lint`, `make coverage` (80 %) pass
- [ ] `cd flipper && ufbt` builds the FAP
- [ ] `make ios-project ios-build` succeeds

### Task 11: Documentation
- [ ] root `README.md`: Phase 2 section (transport setting on both sides, pairing steps: start Bluetooth on the Flipper, scan in Settings, type the passkey the Flipper shows, iPad/iPhone install from Xcode with free provisioning), the `host/iOS` layout, `make ios-*` targets
- [ ] `flipper/README.md`: the transport submenu, status-line values, the note that the official Flipper app cannot connect while SpoolBuddy holds the BLE serial profile
- [ ] `host/README.md`: `SpoolBuddyUI`, `BLETransport`, QR scanning, signing files
- [ ] `docs/superpowers/specs/…design.md`: mark Phase 2 decisions taken by the builder in "Decisions made by the designer"

## Technical Details

### GATT (Flipper serial service, firmware 1.5.1)
| Role | UUID | Properties |
|---|---|---|
| Service | `8FE5B3D5-2E7F-4A98-2A48-7ACC60FE0000` | |
| TX (Flipper → host) | `19ED82AE-ED21-4C9D-4145-228E61FE0000` | notify |
| RX (host → Flipper) | `19ED82AE-ED21-4C9D-4145-228E62FE0000` | write with response |
| Flow control | `19ED82AE-ED21-4C9D-4145-228E63FE0000` | read, notify; uint32 big-endian credit |
| RPC status | `19ED82AE-ED21-4C9D-4145-228E64FE0000` | leave at 0; a write of 0 raises `BleResetRequest` on the Flipper |

Write size ≤ 243 bytes per write and ≤ MTU − 3. The Flipper grants a new
credit only when its counter reaches zero, so the host sends up to the
credit, then waits for the flow-control notification.

### Flipper BLE lifecycle
```
open:  furi_record_open(RECORD_BT) → bt_set_status_changed_callback →
       bt_profile_start(bt, ble_profile_serial, NULL) →
       ble_profile_serial_set_event_callback(profile, 1024, cb, ctx)
rx:    DataReceived → ble_lines → line_buffer → rx callback;
       after consumption: ble_profile_serial_notify_buffer_is_empty
tx:    ble_profile_serial_tx(≤ 486 bytes) → wait DataSent → next packet
close: bt_disconnect → bt_profile_restore_default → furi_record_close
```
`BtStatusConnected` is "connected"; the hello goes out on that transition.

### Settings on the Flipper
`/ext/apps_data/spoolbuddy/settings.bin`, `saved_struct` magic `0x5B`,
version 1: `{ transport: 0 = USB, 1 = Bluetooth }`.

### QR payload
`bambuddy://config?v=1&url=<percent-encoded base URL>&key=<percent-encoded key>`.
Only `v=1` is accepted.

### Repository additions
```
host/Sources/SpoolBuddyUI/        shared SwiftUI views
host/Sources/SpoolBuddyCore/Transport/BLEFlow.swift
host/Sources/SpoolBuddyCore/Transport/BLE/{Central,BLETransport,CoreBluetoothCentral}.swift
host/Sources/SpoolBuddyCore/Session/APIKeyQRPayload.swift
host/iOS/project.yml, host/iOS/Sources/App.swift, host/iOS/Signing.example.xcconfig
flipper/src/app_settings.{c,h}, ble_lines.{c,h}, transport_ble.c, scene_transport.c
```

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification** (owner, with the Flipper, the Mac and an iPad):
- Flipper: Idle → OK → Transport: Bluetooth; the status line shows `BLE adv`.
- Mac: Settings → Transport Bluetooth → Scan → pick "Flipper <name>" →
  type the passkey the Flipper shows; status `BLE`; scan a spool and weigh
  it; compare with the USB path.
- iPad: `brew install xcodegen`, `make ios-project`, open
  `host/iOS/SpoolBuddy.xcodeproj` in Xcode, sign with the personal team
  (free provisioning, 7-day certificate), run on the iPad; pair, scan the
  API-key QR from Bambuddy's key dialog, Test connection, weigh a spool.
- Long lines: a `scan` with 64 blocks (~2.8 KB) must arrive intact over BLE
  in both directions; watch for stalls (credit) and reordering.
- Leaving the FAP restores the default BLE profile: the official Flipper
  app connects again afterwards.

**External systems**:
- Apple Developer account and TestFlight when the app is ready (later).
- App icon and bundle id are placeholders until then.
