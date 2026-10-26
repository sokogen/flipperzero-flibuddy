# workflows

Path-filtered CI: one workflow each for `flipper/`, `host/` and `tools/`.
Each also runs when `protocol/` (the shared contract) or the workflow file
changes; `tools` also watches `flipper/tests/vectors/`, which its tests
compare against the generators. `make test` at the repository root runs
the same three suites locally; `tools/tests/test_ci.py` checks that the
workflows and the Makefile stay in line.

- `flipper.yml`: ubuntu, `ufbt` pinned to SDK 1.5.1, builds the FAP, runs
  the host-compiled C tests, uploads `dist/*.fap` as an artifact.
- `host.yml`: macOS, `swift build` with warnings as errors, `swift test`
  with coverage and the 80 % SpoolBuddyCore gate (`tools/swift_coverage.py`,
  so it also runs when that script changes).
- `tools.yml`: ubuntu, `uv sync`, `uv run pytest --cov` (fails under 80 %)
  and `uv run ruff check`.
