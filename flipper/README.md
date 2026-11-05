# flipper

The Flipper Zero external app (FAP), built with stock `ufbt` pinned to
firmware 1.5.1, and its host-compiled unit tests. The screens, keys and
feedback are specified in `docs/design/flipper-ui-spec.md`.

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
and gives it back on exit: Back on the Waiting or Ready screen leaves the
app and hands the port back to the CLI. A host that opens the port gets a `hello`; a host
`hello` within 2 s marks it connected (`src/host_link.h`).

## Settings

▶ on the Waiting or Ready screen opens **Settings**: ▲▼ select a row, ◀▶
change its value in place, Back saves and returns.

| Setting | Values | Default |
|---|---|---|
| Connection | USB / Bluetooth | USB |
| Auto-save new | Off / On | Off |
| Feedback | Vibro+LED / LED / Off | Vibro+LED |
| Sound | Off / On | Off |
| Version | OK opens About (version, protocol, firmware, host) | |

**Auto-save new** travels in every `scan` (`autosave`). On, the host
creates a Bambu tag Bambuddy does not know at once with the tag's defaults
and the Flipper shows **Added to Bambuddy**. Off, the result reads **Not in
Bambuddy** and nothing reaches Bambuddy until **Add** (OK), **Add and
weigh** (menu) or a save on the host. **Feedback** and **Sound** choose
what the LED, the vibro motor and the speaker do per event
(`src/feedback.h`).

Leaving Settings with another Connection closes the running backend and
opens the other (and retries the transport in use when it did not open).
The settings are saved with `saved_struct` in
`/ext/apps_data/flibuddy/settings.bin`, version 2: one byte each for the
transport (`0` = USB, `1` = Bluetooth), Auto-save new, Feedback (`0` =
Vibro+LED, `1` = LED, `2` = Off) and Sound. A version 1 file (transport
only) keeps its transport and takes the defaults for the rest; it is
rewritten as version 2 on the next save. A missing or unreadable file, one
of another version or with any value out of range loads the defaults
(`src/app_settings.h`, the SDK side in `src/app_settings_file.c`). Only the
chosen backend runs: with Bluetooth the USB port stays with the CLI and
qFlipper.

Without a host the Waiting screen names the transport in use; with one it
gives way to Ready:

| Text | Meaning |
|---|---|
| `USB: no host app` | USB; no host has opened the port and said hello |
| `USB unavailable` | the USB port could not be taken |
| `Visible as <name>` | Bluetooth; the Bt service says advertising, no host subscribed yet (shown even when the stack refused the advertisement, see "Findings on hardware"); the Bluetooth icon blinks |
| `Bluetooth: no host app` | Bluetooth; a central subscribed but sent no hello |
| `Bluetooth off` | Bluetooth does not advertise (switched off in the Flipper's Settings, or the radio stack could not start the profile, in which case the app falls back to a backend that never connects) |

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
notification at a time and does not retry a chunk: the SDK waits about a
second for room in the stack, and a chunk it still cannot place ends the
line at once (`src/ble_lines.h`); the host writes one chunk at a time.
The Flipper sends its `hello` when the host subscribes to TX, as it does on USB when
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

`Visible as <name>` on the Waiting screen does not prove the Flipper is on
air: the firmware raises `GapEventTypeStartAdvertising` even when
`aci_gap_set_discoverable` fails (`gap_advertise_start` in
`targets/f7/ble_glue/gap.c`), so the app shows it either way. The Flipper
log tells.

### Reading the Flipper log

With Bluetooth chosen the USB port stays with the CLI, so the log can be
read while the app runs. Open a CLI session (`ufbt cli` from `flipper/`,
or any serial terminal on the Flipper's USB port) and run `log debug`
(`log ?` lists the levels; Ctrl+C stops, and the previous level comes
back). Then start the app and choose Bluetooth in Settings. The lines to look for:
`BleGap` (advertising, connections; `set_discoverable failed` means
nothing is advertised), `FliBuddyBle` (the profile and the service) and
`FliBuddy` (the app). With the USB transport the app holds the port, so
there is no CLI to read the log from.

## Scanning

On the Waiting and Ready screens the app keeps the NFC scanning for an ISO
14443-3A tag and reads it (`src/nfc_read.h`): a MIFARE Classic (SAK
0x08/0x18) with the Bambu Key A derived from its UID, sectors that do not
open stay missing; an NTAG (SAK 0x00) page by page. A tag moved away before
the read finishes yields a dump with every sector missing (Tag details:
"0/16 sectors"); the host then has only the UID to go on, with no tray UUID
and no prefill, so hold the tag still and scan again. A tag that was read is
not read again until it has left the field or another tag answers
(`src/tag_watch.h`), so a spool left on the Flipper does not rescan.

With a host the dump goes out as `scan` (protocol version 2,
`protocol/PROTOCOL.md`) and the host's `lookup` brings the spool's fields;
the Flipper lays out the result itself. A known spool offers **Weigh**, **New**
(Mark as new) and, in the menu, Mark as empty, Relink on host, Tag details
and Delete spool; an unknown Bambu tag **Add**, **Link** and Add and weigh;
a blank tag Link on host. Mark as new / empty wait 3 s with **Undo** before
anything is sent; Delete asks first. An intent waits up to 10 s for its
`result`, then the Flipper shows an error whose Retry resends it under the
same id. Without a host a scan shows the tag's own detailed type or
material, the type and the UID; Tag details adds how many sectors or pages
were read.

Every screen change goes through the pure reducer in `src/app_state.h`. The
app has one custom View: after every state change and tick
`ui_frame_build()` (`src/ui_frame.h`, SDK-free) turns the state into a
`UiFrame` with all the wording, and `src/ui_draw.c` lays it out on the GUI
thread. The reducer's feedback cue goes through `src/feedback.h` (tested)
to the notification sequences in `src/feedback_play.c`.

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
