# flipper-spoolbuddy

Keep a [Bambuddy](https://github.com/maziggy/bambuddy) filament inventory
accurate with a Flipper Zero instead of SpoolBuddy hardware. The Flipper
reads a spool's NFC tag (Bambu MIFARE Classic or NTAG) and streams the raw
dump over USB to a host app on the Mac; the host parses the tag, looks the
spool up in Bambuddy, and records weights typed in from an ordinary kitchen
scale, on either the Flipper or the host. New spools can be created and
existing ones linked to a tag. See
`docs/superpowers/specs/2026-10-25-flipper-spoolbuddy-design.md`.

## Layout

```
docs/superpowers/specs/   design docs
docs/plans/               implementation plans
protocol/                 PROTOCOL.md, JSON schema, fixtures (tag dumps,
                          sample messages) shared by all test suites
flipper/                  the FAP: application.fam, src/, host-compiled
                          unit tests (hkdf, intent model, line framing)
host/                     Swift package: macOS bridge app and its core
                          library
tools/                    Python dev bridge (Phase 0 spike, kept as a
                          debugging tool), dump inspection scripts
.github/workflows/        flipper, host and tools CI, path-filtered
```

## Tests

```
make test                    # all three below; CI runs each per part
make -C flipper/tests test   # C unit tests, host-compiled, no Flipper needed
cd host && swift test        # Swift
cd tools && uv run pytest    # Python
```
