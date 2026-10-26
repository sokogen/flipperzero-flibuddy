# flipper

The Flipper Zero external app (FAP), built with stock `ufbt` pinned to
firmware 1.5.1, and its host-compiled unit tests.

## Build

```
cd flipper
ufbt update --branch=1.5.1   # once; dotenv mode keeps the SDK in .ufbt
ufbt                         # builds dist/flibuddy.fap
ufbt launch                  # builds, installs and starts it on a Flipper
```

`ufbt launch` installs the app as `/ext/apps/Tools/flibuddy.fap`; the
Flipper lists it as **FliBuddy** under Apps → Tools.

`.env` (from `ufbt dotenv_create`) points `UFBT_HOME` at `flipper/.ufbt`.
`application.fam` limits the sources to `src/`, so the tests and the SDK
stay out of the FAP.

With the USB transport (the default) the app takes the USB CDC port from
the CLI while it runs (qFlipper and the CLI are unavailable until it exits)
and gives it back on exit: Back on the Idle screen leaves the app and hands
the port back to the CLI. A host that opens the port gets a `hello`; a host
`hello` within 2 s marks it connected (`src/host_link.h`).

## Transport

On the Idle screen OK opens the **Transport** menu with **USB** and
**Bluetooth**; the one in use is selected and Back returns to Idle without
a change. Choosing a different one closes the running backend and opens the
other. The choice is saved with `saved_struct` in
`/ext/apps_data/flibuddy/settings.bin` (version 1, `0` = USB, `1` =
Bluetooth); a missing or unreadable file, or one of another version, means USB
(`src/app_settings.h`, the SDK side in `src/app_settings_file.c`). Only the
chosen backend runs: with Bluetooth the USB port stays with the CLI and
qFlipper.

The status line under the title shows:

| Text | Meaning |
|---|---|
| `USB` | USB; a host has opened the port and said hello |
| `BLE adv` | Bluetooth; the Bt service says advertising, no host subscribed yet (shown even when the stack refused the advertisement, see "Findings on hardware") |
| `BLE` | Bluetooth; a host is connected, subscribed and said hello |
| `no host` | no host on the chosen transport; on Bluetooth also when it does not advertise (Bluetooth switched off in the Flipper's Settings, or the radio stack could not start the profile, in which case the app falls back to a backend that never connects) |

### Bluetooth

The app does not use the stock serial profile: its passkey pairing cannot
be completed on an Apple Watch. While Bluetooth is chosen it starts its own
BLE profile (`src/ble_flibuddy_svc.c`, `src/transport_ble.c`) with
`bt_profile_start`: no bonding, no pairing, one GATT service. It advertises
the service UUID and no name, with the Flipper's MAC changed in one byte so
centrals keep it apart from the default profile's bonds. The name (8 chars
at most, "Flipper" when the Flipper has none) goes in the scan response as
manufacturer data, company id `0xFFFF` (reserved for tests) followed by the
name, and is the GAP device name a central reads after connecting
(`src/ble_wire.h` has the byte budget). Leaving the app, or switching back
to USB, restores the default profile with `bt_profile_restore_default`.

While FliBuddy holds the Bluetooth profile, the official Flipper mobile
app cannot connect to the Flipper; it can again once you leave the app.

| Role | UUID | Properties |
|---|---|---|
| Service | `51C07E84-E37E-4D52-AC6D-B2003116F506` | advertised |
| RX (host → Flipper) | `D250A7B1-D301-43F6-928E-BF2CA5D115BD` | write with response, write without response; variable, ≤ 243 bytes |
| TX (Flipper → host) | `C3AB2366-401D-482C-9002-B0A046C2A4E4` | notify; variable, ≤ 243 bytes |

The characteristics carry the same NDJSON lines as USB (lines ≤ 8192
bytes, `protocol/PROTOCOL.md`), cut into chunks of ATT MTU − 3 bytes (20
until the MTU exchange says more, at most 243). The Flipper sends one
notification at a time and retries a chunk up to 3 times when the stack is
busy (`src/ble_lines.h`); the host writes one chunk at a time. The Flipper
sends its `hello` when the host subscribes to TX, as it does on USB when
the host raises DTR. A subscribed host is a connected host; unsubscribing
or disconnecting ends the session.

The link is unencrypted by design: it carries tag dumps and grams, never
the API key. Setting `FLIBUDDY_BLE_REQUIRE_ENCRYPTION` to 1 makes both
characteristics require an encrypted link (`ATTR_PERMISSION_ENCRY_READ |
ATTR_PERMISSION_ENCRY_WRITE`), so a central has to pair "just works" first:

```
# in application.fam, inside App(...)
cdefines=["FLIBUDDY_BLE_REQUIRE_ENCRYPTION=1"],
```

The raw ACI events the profile handles are decoded by offset in
`src/ble_wire.c` (the stack's structs are not in the SDK); `ble_wire`,
`ble_lines` and `app_settings` are host-compiled and tested.

### Findings on hardware

The first Bluetooth build never connected on a real Flipper (firmware
1.5.1). Three causes, each fixed and covered where it can be tested on the
host:

1. **The advertisement did not fit.** An advertisement holds 31 bytes. The
   stack adds the flags (3) and the TX power level (3), the 128-bit service
   UUID takes 18, and the name AD up to 10: 34. The stack refused it
   (`[E][BleGap] set_discoverable failed 146`, `BLE_STATUS_INVALID_PARAMS`)
   and nothing was on air. The advertisement now carries no name (24
   bytes) and the name moved to the scan response;
   `tests/test_ble_wire.c` asserts both sizes against `BLE_WIRE_ADV_MAX`.
   The host takes the name from the peripheral, the advertised local name
   or, failing both, the manufacturer data
   (`FliBuddyGATT.displayName` in the host package).
2. **"Connected" never came.** Firmware 1.5.1's `gap.c` raises
   `GapEventTypeConnected` only when pairing completes, which a FliBuddy
   host never does, so the Bt service never reports `BtStatusConnected`.
   The Flipper received the host's `hello` and never answered. A host now
   counts as connected once it has subscribed to TX (a disconnect clears
   the subscription); `ble_wire_link` holds the table and is tested.
3. **The subscription event.** TX's `gatt_evt_mask` is
   `GATT_NOTIFY_ATTRIBUTE_WRITE` (it was `GATT_DONT_NOTIFY_EVENTS`), so the
   host's CCCD write reaches the service as an attribute-modified event and
   the subscription is seen at all.

`BLE adv` on the Idle screen does not prove the Flipper is on air: the
firmware raises `GapEventTypeStartAdvertising` even when
`aci_gap_set_discoverable` fails (`gap_advertise_start` in
`targets/f7/ble_glue/gap.c`), so the app shows `BLE adv` either way. The
Flipper log tells.

### Reading the Flipper log

With Bluetooth chosen the USB port stays with the CLI, so the log can be
read while the app runs. Open a CLI session (`ufbt cli` from `flipper/`,
or any serial terminal on the Flipper's USB port) and run `log debug`
(`log ?` lists the levels; Ctrl+C stops, and the previous level comes
back). Then start the app and choose Bluetooth. The lines to look for:
`BleGap` (advertising, connections; `set_discoverable failed` means
nothing is advertised), `FliBuddyBle` (the profile and the service) and
`FliBuddy` (the app). With the USB transport the app holds the port, so
there is no CLI to read the log from.

## Scanning

On the Idle screen the app keeps the NFC scanning for an ISO 14443-3A tag
and reads it (`src/nfc_read.h`): a MIFARE Classic (SAK 0x08/0x18) with the
Bambu Key A derived from its UID, sectors that do not open stay missing; an
NTAG (SAK 0x00) page by page. A tag moved away before the read finishes
yields a dump with every sector missing ("Sectors read 0/16"); the host
then has only the UID to go on, with no tray UUID and no prefill, so hold
the tag still and scan again. With a host the dump goes out as `scan`;
without one the Flipper shows the UID, the type and, for a Bambu tag, the
ASCII of blocks 2 and 4 and the block 9 hex, the tray UUID; in Phase 0 it
matched the `tray_uuid` an AMS reported (`src/nfc_classify.h`). Every
screen change goes through the reducer in `src/app_state.h`;
`flibuddy_app.c` picks the scene for the new screen.

With a host, the Result screen shows the host's `lookup` lines; OK opens
the actions: a found spool offers **Enter weight** and **Mode: gross/net**
(kept for the session), an unknown tag with prefill **New** and **Link on
host**, a bare one **Create on host** and **Link on host**. The weight
input is pre-filled for the current mode (gross: the last gross weight or
label + core; net: gross - core or the label weight). An intent waits up to
10 s for its `result`, then the Flipper shows an error; Done/Error close
with OK or Back. The wording lives in `src/screen_text.h` and is tested on
the host.

## Tests

Host-compiled unit tests live in `tests/`: `make -C flipper/tests test`
builds every `test_*.c` against each source in `src/` that includes no
Flipper SDK header (`tests/minitest.h` is the assert runner). Sources that
use the SDK (NFC, USB, BLE, GUI) stay behind small interfaces and are left out
automatically, so every such `.c` file must include an SDK header itself
(`<furi.h>`, `<gui/...>`), not only through a project header.

Tests that compare against the shared protocol fixtures read them through
`tests/fixture.h` (the Makefile passes the `protocol/` path) and compare
after stripping JSON whitespace. Generated C vectors live in
`tests/vectors/`; see `tools/README.md` for their generators.
