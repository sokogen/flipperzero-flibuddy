# AGENTS.md

Instructions for coding agents (and humans) working in this repository.

## Language

- Repository content is in English: code, comments, docs, commit messages.
- Communicate with the owner in Russian.

## Ground rules

- No Flipper firmware forks. The FAP builds with stock `ufbt` pinned to
  firmware release 1.5.1 (`ufbt update --branch=1.5.1`, dotenv mode so the
  SDK lives in `flipper/.ufbt`). The Flipper must run 1.5.1.
- No Xcode project and no UI tests. The host is a SwiftPM package built with
  `swift build` / `swift test` only.
- TDD: write the failing test first, then the code. Every change ships with
  tests; all suites pass before moving on.
- Flipper hardware code (NFC, USB) stays behind small interfaces so that the
  rest of `flipper/src` compiles and is tested on the host with plain `cc`.
- The protocol fixtures in `protocol/fixtures/` are the contract: the C,
  Swift and Python test suites all run against them. Changing a message
  means changing the schema, the fixtures and both sides in one commit.
- Bambuddy internal inventory mode only; the host refuses Spoolman mode.
- The Flipper never creates an item without `material`.

## Layout

```
AGENTS.md, README.md
docs/superpowers/specs/   design docs
docs/plans/               implementation plans
protocol/                 PROTOCOL.md, JSON schema, fixtures (tag dumps,
                          sample messages) shared by all test suites
flipper/                  the FAP: application.fam, src/, host-compiled
                          unit tests in tests/
host/                     Swift package: SpoolBuddyCore library,
                          SpoolBuddyMac SwiftUI executable, tests
tools/                    Python dev bridge (Phase 0 spike, kept as a
                          debugging tool), fixture generators
.github/workflows/        path-filtered CI per part
```

## Test commands

```
make -C flipper/tests test   # C unit tests, host-compiled
cd host && swift test        # Swift (SpoolBuddyCore)
cd tools && uv run pytest    # Python bridge, fixtures, schema
```

## Environment notes

- If Xcode.app is installed but its license has not been accepted, `git`,
  `swift` and `cc` from `/usr/bin` fail with exit 69. Run them with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` to use the Command Line
  Tools instead.
