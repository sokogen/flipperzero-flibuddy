# flipper

The Flipper Zero external app (FAP), built with stock `ufbt` pinned to
firmware 1.5.1, and its host-compiled unit tests.

## Build

```
cd flipper
ufbt update --branch=1.5.1   # once; dotenv mode keeps the SDK in .ufbt
ufbt                         # builds dist/spoolbuddy.fap
ufbt launch                  # builds, installs and starts it on a Flipper
```

`.env` (from `ufbt dotenv_create`) points `UFBT_HOME` at `flipper/.ufbt`.
`application.fam` limits the sources to `src/`, so the tests and the SDK
stay out of the FAP.

The app takes the USB CDC port from the CLI while it runs (qFlipper and the
CLI are unavailable until it exits) and gives it back on exit. A host that
opens the port gets a `hello`; a host `hello` within 2 s marks it connected
(`src/host_link.h`).

On the Idle screen the app keeps the NFC scanning for an ISO 14443-3A tag
and reads it (`src/nfc_read.h`): a MIFARE Classic (SAK 0x08/0x18) with the
Bambu Key A derived from its UID, sectors that do not open stay missing; an
NTAG (SAK 0x00) page by page. With a host the dump goes out as `scan`;
without one the Flipper shows the UID, the type and, for a Bambu tag, the
ASCII of blocks 2 and 4 and the block 9 hex (`src/nfc_classify.h`). Every
screen change goes through the reducer in `src/app_state.h`;
`spoolbuddy_app.c` picks the scene for the new screen.

## Tests

Host-compiled unit tests live in `tests/`: `make -C flipper/tests test`
builds every `test_*.c` against each source in `src/` that includes no
Flipper SDK header (`tests/minitest.h` is the assert runner). Sources that
use the SDK (NFC, USB, GUI) stay behind small interfaces and are left out
automatically, so every such `.c` file must include an SDK header itself
(`<furi.h>`, `<gui/...>`), not only through a project header.

Tests that compare against the shared protocol fixtures read them through
`tests/fixture.h` (the Makefile passes the `protocol/` path) and compare
after stripping JSON whitespace. Generated C vectors live in
`tests/vectors/`; see `tools/README.md` for their generators.
