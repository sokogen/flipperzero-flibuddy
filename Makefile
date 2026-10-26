# Runs every test suite locally, the same ones CI runs per part
# (.github/workflows). With an unaccepted Xcode license, run it as
# `DEVELOPER_DIR=/Library/Developer/CommandLineTools make test` (AGENTS.md).

.PHONY: test test-flipper test-host test-tools
.DEFAULT_GOAL := test

test: test-flipper test-host test-tools

test-flipper:
	$(MAKE) -C flipper/tests test

test-host:
	cd host && swift test

test-tools:
	cd tools && uv run pytest
