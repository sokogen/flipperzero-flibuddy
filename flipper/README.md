# flipper

The Flipper Zero external app (FAP), built with stock `ufbt` pinned to
firmware 1.5.1, and its host-compiled unit tests.

Host-compiled unit tests live in `tests/`: `make -C flipper/tests test`
builds every `test_*.c` against each source in `src/` that includes no
Flipper SDK header (`tests/minitest.h` is the assert runner). Sources that
use the SDK (NFC, USB, GUI) stay behind small interfaces and are left out
automatically.
