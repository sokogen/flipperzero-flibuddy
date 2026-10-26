# flipper-spoolbuddy

Keep a [Bambuddy](https://github.com/maziggy/bambuddy) filament inventory
accurate with a Flipper Zero instead of SpoolBuddy hardware. The Flipper
reads a spool's NFC tag (Bambu MIFARE Classic or NTAG) and streams the raw
dump over USB to a host app on the Mac; the host parses the tag, looks the
spool up in Bambuddy, and records weights typed in from an ordinary kitchen
scale, on either the Flipper or the host. New spools can be created and
existing ones linked to a tag. See
`docs/superpowers/specs/2026-10-25-flipper-spoolbuddy-design.md`.

Bambuddy must run in internal inventory mode; the host refuses Spoolman
mode.

## Layout

```
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
.github/workflows/        flipper, host and tools CI, path-filtered
```

Each part has its own README with the details: `flipper/README.md`,
`host/README.md`, `tools/README.md`, and the wire protocol in
`protocol/PROTOCOL.md`.

## Requirements

- Flipper Zero on firmware release **1.5.1** (stock, no fork).
- macOS 14+ with the Command Line Tools (Swift 6). No Xcode project; the
  host builds with `swift build` only.
- Python 3.13 and [uv](https://docs.astral.sh/uv/) for the bridge and the
  tools.
- [ufbt](https://pypi.org/project/ufbt/) for the Flipper app:

  ```
  uv tool install ufbt          # or: python3 -m pip install --upgrade ufbt
  ```

If Xcode.app is installed but its license is not accepted, `git`, `swift`
and `cc` from `/usr/bin` exit with 69. Prefix the commands below with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools` (see `AGENTS.md`).

## Flipper app

```
cd flipper
ufbt update --branch=1.5.1    # once; the SDK goes to flipper/.ufbt (.env)
ufbt                          # builds dist/spoolbuddy.fap
ufbt launch                   # builds, installs and starts it over USB
```

While the app runs it owns the USB serial port, so qFlipper and the Flipper
CLI are unavailable until you leave it. The Idle screen shows `USB` once a
host has said hello, `no host` otherwise. Without a host a scan shows the
tag's local facts only. See `flipper/README.md` for the screens.

## Mac host

```
cd host
swift run SpoolBuddyMac
```

Open Settings (⌘,), enter the Bambuddy URL (`http://<BAMBUDDY_LAN_IP>:8000`)
and an API key with inventory read + update and settings read, pick the
empty-spool catalog entry for new items, and press **Test connection**. The
Flipper port defaults to the first `/dev/cu.usbmodemflip_*`. Every scan
appears in the session feed, where the weight can be entered or corrected,
new spools created and tags linked to existing spools. See `host/README.md`.

The core weight of new items defaults to 325 g: everything on the scale that
is not filament, a Bambu reusable spool (293 g) plus a refill core (32 g).
Picking a catalog entry copies its weight, which can then be edited; the
entry is recorded only as `core_weight_catalog_id`. A core weight saved
before keeps its value, so an install set up with 250 g needs 325 entered
once. AMS-added spools take their core weight from the first "Bambu Lab"
catalog entry in Bambuddy, so set that entry to 325 g too.

## Python dev bridge

The bridge does what the Mac host does from a terminal, for the Phase 0
spike and for debugging the protocol:

```
cd tools
uv run python -m bridge --bambuddy http://<BAMBUDDY_LAN_IP>:8000 --api-key bb_...
uv run python -m bridge               # no Bambuddy: print the parsed scans only
```

`--port` overrides the auto-detected `/dev/cu.usbmodemflip_*`; the key can
also come from `$BAMBUDDY_API_KEY`; `--core-weight` (default 325 g, see the
Mac host above) and `--catalog-id` set the core weight and the catalog entry
of new items. Only one program can hold the port: quit the
Mac host before starting the bridge.

## Fixtures

`protocol/fixtures/` is the contract shared by the C, Swift and Python
suites:

- `messages/`: one sample per message type, status and action, validated
  against `protocol/schema/message.schema.json`; the C encoder output must
  equal them once JSON whitespace is stripped.
- `tags/`: tag dumps. `bambu_pla_pure_real.json` is a real Bambu tag
  (spool "PLA Pure", UID `7EF1AB04`) captured by the bridge in Phase 0,
  marked `synthetic: false`; it was read with sectors 3-15 missing, which
  still covers every field the parsers use (blocks 1-10). Every parser
  and the Flipper's classifier and `scan` encoder are tested against it.
  `bambu_pla_basic_synthetic.json` is built from the documented block
  layout (`synthetic: true`) and stays for the key vectors, the sample
  messages and the full 16-sector cases; `ntag215_blank.json` is a blank
  NTAG215 (synthetic).

Messages and synthetic tag dumps are generated by `tools/fixtures/` (see
`tools/README.md`); a test fails when a committed fixture differs from its
generator. Real dumps have no generator and are checked for shape only:
64 blocks, block 0 matching UID, SAK and ATQA, missing sectors zero-filled.

### Capturing real dumps

Run the bridge with `--dump-dir` and scan a spool:

```
cd tools
uv run python -m bridge --dump-dir ../protocol/fixtures/tags
```

Each scan is saved as `<type>_<UID>_<scan_id>.json` in the tag fixture
format. MIFARE Classic sector trailers are rebuilt from the derived Key A,
since the Flipper does not send them. `--dump-dir` combines with
`--bambuddy`. UIDs stay in the dumps; they are not secrets.

## Tests

```
make test                    # all three below; CI runs each per part
make -C flipper/tests test   # C unit tests, host-compiled, no Flipper needed
cd host && swift test        # Swift
cd tools && uv run pytest    # Python
make lint                    # C with -Werror, Swift with -warnings-as-errors, ruff
make coverage                # line coverage of SpoolBuddyCore and tools, >= 80 %
```

## Phase 0 results (2026-10-26)

Checked with the owner's Flipper (firmware 1.5.1), real Bambu spools and
the Bambuddy on the NAS; the details are in "Phase 0 findings (2026-10-26)"
of the design doc. Verified:

- Handshake: with the app open the Mac sees `/dev/cu.usbmodemflip_*`, the
  Flipper sends `hello`, a host `hello` turns the Idle status to `USB`;
  Back on the Idle screen leaves the app and the CLI gets the port back.
- Scans with and without a host: with a host the dump goes out as `scan`
  and the `lookup` lines show; without one the Flipper shows the UID, the
  type, the material, the detailed type and the block 9 hex.
- Both tags of a spool resolve to the same tray UUID, and a sealed refill
  reads through its box. A tag moved away early yields a dump with all
  sectors missing, which leaves the host only the UID.
- Weigh and New end to end, from the Flipper and from the host: Bambuddy
  records `last_scale_weight` and `weight_used`; a new item gets the label
  weight, core weight and tag, and a scan of the other tag matches it.
- The tray UUID is block 9: it matched the `tray_uuid` an AMS reported for
  a known spool byte for byte. Blocks 4+5 hold the detailed type.
- Bambuddy stores AMS tag UIDs as the MIFARE UID followed by `00000100`;
  the host and the bridge send Bambu UIDs in that form.
- Core weight 325 g: a Bambu reusable spool (293 g) plus a refill core
  (32 g), for sealed spools and mounted refills alike.

Remaining checks:

- [ ] Scan an NTAG with and without a host.
- [ ] Link a hand-added spool via the host picker; confirm a repeat scan
      matches.
- [ ] Press Back while "Reading tag"; the app returns to Idle and scanning
      resumes.
