# SpoolBuddy host (Swift package)

SwiftPM only: no Xcode project, no UI tests.

- `SpoolBuddyCore`: platform-neutral library (protocol models, tag parser,
  Bambuddy client, transport, session, view models). `TagParser` takes the
  tray UUID from block 9 of a Bambu tag, the block whose value matched the
  AMS-reported `tray_uuid` in Phase 0. Lookups try it first, then the UID,
  and new items and tag links store it. The UID goes to Bambuddy in the
  form an AMS writes (`ParsedTag.bambuddyTagUid`): for Bambu tags the UID
  followed by `00000100` (`7EF1AB04` → `7EF1AB0400000100`), NTAG UIDs as
  read; see `protocol/PROTOCOL.md`.
- `SpoolBuddyUI`: SwiftUI views shared by the macOS and iOS apps (the feed,
  the settings form, the New and Link sheets); macOS-only parts (the
  Settings link, the serial port picker) sit behind `#if os(macOS)`.
- `SpoolBuddyMac`: SwiftUI executable for macOS 14+: the app and the
  Settings window around `SettingsForm`.

The package supports macOS 14+ and iOS 26+. Off macOS `SerialTransport` is a
stub (no ports, connecting fails) and the `hello` names the platform through
`PlatformInfo` (`macOS 26.0`, `iOS 26.1`, `iPadOS 26.1`). To build the shared
targets or run the tests on the iOS simulator:

```
xcodebuild -scheme SpoolBuddyUI -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme SpoolBuddy-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```
- `SpoolBuddyCoreTests`: swift-testing suites (`import Testing`). The Command
  Line Tools have no XCTest, so the tests do not use it.

## Commands

```
cd host
swift build
swift test
swift run SpoolBuddyMac
```

If Xcode.app is installed but its license is not accepted, `swift` from
`/usr/bin` exits with 69. Use the Command Line Tools instead:

```
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test
```

## Running the Mac app

```
cd host
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift run SpoolBuddyMac
```

`swift run` starts a plain executable, not an `.app` bundle; the app makes
itself a regular app (Dock icon, menu bar) at launch. Settings (⌘,) hold the
Bambuddy URL and API key (stored in the login Keychain, service
`SpoolBuddy`), the empty-spool catalog entry and the editable core weight
used for new items, the default weight mode and the Flipper port ("Automatic" opens
the first `/dev/cu.usbmodemflip_*`). Use **Test connection** after entering
the key; it also loads the catalog.

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

The window shows the session feed, newest scan first. Known spools get a
weight field with a net/gross toggle and **Save**; unknown tags get **New…**
(the form is filled in from the tag) and **Link to existing…** (a filtered
picker of Bambuddy's spools). **Clear** empties the feed. The status bar
shows the Flipper link and the Bambuddy check; the link reconnects on its
own when the Flipper app is restarted or the cable is replugged.

The view models (`SpoolBuddyCore/ViewModels`) are platform-neutral and
tested with `swift test`; the SwiftUI views in `SpoolBuddyUI` and
`SpoolBuddyMac` have no tests.

### `@ViewState` instead of `@State`

The macOS 27 SDK declares `@State` as a macro too, implemented in the
`SwiftUIMacros` compiler plugin that only Xcode ships. With the Command Line
Tools, `@State` fails with "plugin for module 'SwiftUIMacros' not found".
`Sources/SpoolBuddyUI/ViewState.swift` aliases the `State` property wrapper
struct as a public `ViewState`; use `@ViewState` in both SwiftUI targets.

## Protocol fixtures

The tests read the shared contract in `protocol/fixtures/` as package
resources. `Tests/SpoolBuddyCoreTests/Fixtures` is a committed symlink to
`../../../protocol/fixtures`, declared as `.copy("Fixtures")` in
`Package.swift`; SwiftPM follows the symlink and copies the directory into
the test bundle on every build, picking up added, changed and removed
fixtures. Tests load it with `Bundle.module.url(forResource: "Fixtures",
withExtension: nil)`.

If the symlink is lost (for example on a checkout with `core.symlinks=false`),
recreate it:

```
cd host/Tests/SpoolBuddyCoreTests && ln -s ../../../protocol/fixtures Fixtures
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
