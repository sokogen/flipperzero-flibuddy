# workflows

Path-filtered CI: one workflow each for `flipper/`, `host/` and `tools/`.
Each also runs when `protocol/` (the shared contract) or the workflow file
changes; `tools` also watches `flipper/` and the design's
`flipper-ui.js`, which its tests check (generated vectors and images, the
fam and version, the app's strings, the catalog files). `make test` at the repository root runs
the same three suites locally; `tools/tests/test_ci.py` checks that the
workflows and the Makefile stay in line.

- `flipper.yml`: ubuntu, `ufbt` pinned to SDK 1.5.1 in `flipper/.ufbt`
  (`UFBT_HOME` is set by the job, as `flipper/.env` is git-ignored), checks
  the SDK pin (`tools/tests/test_sdk_pin.py`, which fails rather than
  skips when `UFBT_HOME` names a dir without an SDK), builds the FAP, runs
  the host-compiled C tests, uploads `dist/*.fap` as an artifact.
- `host.yml`: macOS, two jobs.
  - `test`: `swift build` with warnings as errors, `swift test` with
    coverage and the 80 % FliBuddyCore gate (`tools/swift_coverage.py`,
    so it also runs when that script changes).
  - `apple`: installs XcodeGen with Homebrew and runs
    `make apple-project apple-build`, which generates `host/Apple` and
    builds `FliBuddyiOS` and `FliBuddyWatch` for the simulators with the
    runner's default Xcode. It also runs when the root `Makefile` changes,
    since the `apple-*` recipes live there.
- `tools.yml`: ubuntu, `uv sync`, `uv run pytest --cov` (fails under 80 %)
  and `uv run ruff check`.

## Signing

CI never signs. There are no certificates, provisioning profiles or team
ids in the repository or in its secrets: `make apple-build` passes
`CODE_SIGNING_ALLOWED=NO` and builds for the simulators only. The team for
device builds lives in `host/Apple/Signing.xcconfig`, which is git-ignored
(copy `Signing.example.xcconfig`); `Base.xcconfig` includes it with
`#include?`, so the project generates and builds without it.
