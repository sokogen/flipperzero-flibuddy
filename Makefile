# Runs every test suite locally, the same ones CI runs per part
# (.github/workflows). With an unaccepted Xcode license, run it as
# `DEVELOPER_DIR=/Library/Developer/CommandLineTools make test` (AGENTS.md).

.PHONY: test test-flipper test-host test-tools
.PHONY: lint lint-flipper lint-host lint-tools
.PHONY: coverage coverage-host coverage-tools
.PHONY: apple-project apple-build apple-archive icons
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

# Line coverage of FliBuddyCore and of the Python tools, at least 80 %.
coverage: coverage-host coverage-tools

coverage-host:
	cd host && swift test --enable-code-coverage
	cd tools && uv run python swift_coverage.py "$$(cd ../host && swift test --show-codecov-path)" --min 80

coverage-tools:
	cd tools && uv run pytest --cov

# The iOS and watch apps (host/Apple, generated with XcodeGen; needs Xcode,
# not the Command Line Tools). Builds for the simulators without signing, as
# CI does.
apple-project:
	cd host/Apple && xcodegen generate

apple-build:
	cd host/Apple && xcodebuild -project FliBuddy.xcodeproj -scheme FliBuddyiOS \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath .build \
		CODE_SIGNING_ALLOWED=NO build
	cd host/Apple && xcodebuild -project FliBuddy.xcodeproj -scheme FliBuddyWatch \
		-destination 'generic/platform=watchOS Simulator' -derivedDataPath .build \
		CODE_SIGNING_ALLOWED=NO build

# Archives the iPhone app (with the watch app embedded) for the App Store and
# exports a signed .ipa to host/Apple/.build/export; it uploads nothing. Needs
# a distribution certificate and an App Store Connect app record for the
# bundle ids (-allowProvisioningUpdates creates profiles), and DEVELOPMENT_TEAM
# in the git-ignored host/Apple/Signing.xcconfig. The build number is the
# commit count, one for both apps.
apple-archive:
	@team=$$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' host/Apple/Signing.xcconfig 2>/dev/null | tr -d ' '); \
	test -n "$$team" || { echo "set DEVELOPMENT_TEAM in host/Apple/Signing.xcconfig" >&2; exit 1; }; \
	build=$$(git rev-list --count HEAD); \
	echo "archiving build $$build"; \
	cd host/Apple && mkdir -p .build && \
	cp ExportOptions.plist .build/ExportOptions.plist && \
	/usr/libexec/PlistBuddy -c "Add :teamID string $$team" .build/ExportOptions.plist && \
	xcodebuild -project FliBuddy.xcodeproj -scheme FliBuddyiOS -configuration Release \
		-destination 'generic/platform=iOS' -archivePath .build/FliBuddy.xcarchive \
		-allowProvisioningUpdates CURRENT_PROJECT_VERSION=$$build archive && \
	xcodebuild -exportArchive -archivePath .build/FliBuddy.xcarchive \
		-exportPath .build/export -exportOptionsPlist .build/ExportOptions.plist \
		-allowProvisioningUpdates

# Regenerates the app icons (SVGs, asset catalog PNGs, the Flipper icon);
# needs rsvg-convert (brew install librsvg). The PNGs are committed.
icons:
	cd tools && uv run python -m fixtures.make_app_icons
