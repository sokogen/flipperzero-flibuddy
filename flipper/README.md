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
