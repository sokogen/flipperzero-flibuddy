# SpoolBuddy host (Swift package)

SwiftPM only: no Xcode project, no UI tests.

- `SpoolBuddyCore`: platform-neutral library (protocol models, tag parser,
  Bambuddy client, transport, session, view models). `TagParser` takes the
  tray UUID from block 9 of a Bambu tag, the block whose value matched the
  AMS-reported `tray_uuid` in Phase 0. Lookups try it first, then the UID,
  and new items and tag links store it.
- `SpoolBuddyMac`: SwiftUI executable for macOS 14+.
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
`SpoolBuddy`), the empty-spool catalog entry used for new items, the default
weight mode and the Flipper port ("Automatic" opens the first
`/dev/cu.usbmodemflip_*`). Use **Test connection** after entering the key; it
also loads the catalog.

The window shows the session feed, newest scan first. Known spools get a
weight field with a net/gross toggle and **Save**; unknown tags get **New…**
(the form is filled in from the tag) and **Link to existing…** (a filtered
picker of Bambuddy's spools). **Clear** empties the feed. The status bar
shows the Flipper link and the Bambuddy check; the link reconnects on its
own when the Flipper app is restarted or the cable is replugged.

The view models (`SpoolBuddyCore/ViewModels`) are platform-neutral and
tested with `swift test`; the SwiftUI views in `SpoolBuddyMac` have no tests.

### `@ViewState` instead of `@State`

The macOS 27 SDK declares `@State` as a macro too, implemented in the
`SwiftUIMacros` compiler plugin that only Xcode ships. With the Command Line
Tools, `@State` fails with "plugin for module 'SwiftUIMacros' not found".
`Sources/SpoolBuddyMac/ViewState.swift` aliases the `State` property wrapper
struct as `ViewState`; use `@ViewState` in that target.

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
