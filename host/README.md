# SpoolBuddy host (Swift package)

SwiftPM only: no Xcode project, no UI tests.

- `SpoolBuddyCore`: platform-neutral library (protocol models, tag parser,
  Bambuddy client, transport, session, view models).
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
