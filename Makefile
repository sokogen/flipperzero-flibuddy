# Runs every test suite locally, the same ones CI runs per part
# (.github/workflows). With an unaccepted Xcode license, run it as
# `DEVELOPER_DIR=/Library/Developer/CommandLineTools make test` (AGENTS.md).

.PHONY: test test-flipper test-host test-tools
.PHONY: lint lint-flipper lint-host lint-tools
.PHONY: coverage coverage-host coverage-tools
.DEFAULT_GOAL := test

test: test-flipper test-host test-tools

test-flipper:
	$(MAKE) -C flipper/tests test

test-host:
	cd host && swift test

test-tools:
	cd tools && uv run pytest

# Warnings fail the build: the C tests compile with -Werror, Swift with
# -warnings-as-errors, Python goes through ruff.
lint: lint-flipper lint-host lint-tools

lint-flipper:
	$(MAKE) -C flipper/tests test

lint-host:
	cd host && swift build -Xswiftc -warnings-as-errors

lint-tools:
	cd tools && uv run ruff check

# Line coverage of SpoolBuddyCore and of the Python tools, at least 80 %.
coverage: coverage-host coverage-tools

coverage-host:
	cd host && swift test --enable-code-coverage
	cd tools && uv run python swift_coverage.py "$$(cd ../host && swift test --show-codecov-path)" --min 80

coverage-tools:
	cd tools && uv run pytest --cov
