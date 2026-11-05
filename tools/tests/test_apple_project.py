"""The XcodeGen spec of the Apple apps in `host/Apple`.

The generated Xcode project is not checked in; `make apple-project`
regenerates it from `project.yml` and `make apple-build` builds the iOS and
watch apps for the simulators without signing. These tests guard the spec, the signing
files and the Makefile targets, which no other suite exercises.
"""

import plistlib
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
APPLE = REPO / "host" / "Apple"


def spec() -> dict:
    return yaml.safe_load((APPLE / "project.yml").read_text(encoding="utf-8"))


def ios_settings() -> dict:
    return spec()["targets"]["FliBuddyiOS"]["settings"]["base"]


def test_the_ios_target_runs_on_iphone_and_ipad_from_ios_26():
    target = spec()["targets"]["FliBuddyiOS"]
    assert target["type"] == "application"
    assert target["platform"] == "iOS"
    assert target["deploymentTarget"] == "26.0"
    assert ios_settings()["TARGETED_DEVICE_FAMILY"] == "1,2"


def watch_settings() -> dict:
    return spec()["targets"]["FliBuddyWatch"]["settings"]["base"]


def package_products(target: str) -> set:
    deps = spec()["targets"][target]["dependencies"]
    return {(d["package"], d["product"]) for d in deps if "package" in d}


def test_the_ios_target_uses_the_local_package_products():
    assert spec()["packages"]["FliBuddy"]["path"] == ".."
    assert package_products("FliBuddyiOS") == {
        ("FliBuddy", "FliBuddyCore"),
        ("FliBuddy", "FliBuddyUI"),
    }


def test_the_watch_target_runs_on_watchos_26():
    project = spec()
    target = project["targets"]["FliBuddyWatch"]
    assert target["type"] == "application"
    assert target["platform"] == "watchOS"
    assert target["deploymentTarget"] == "26.0"
    assert project["options"]["deploymentTarget"]["watchOS"] == "26.0"
    assert watch_settings()["TARGETED_DEVICE_FAMILY"] == "4"
    assert package_products("FliBuddyWatch") == {
        ("FliBuddy", "FliBuddyCore"),
        ("FliBuddy", "FliBuddyUI"),
    }


def test_the_watch_app_is_the_ios_apps_companion():
    ios = ios_settings()
    watch = watch_settings()
    deps = spec()["targets"]["FliBuddyiOS"]["dependencies"]
    # Embedding the watch app makes it install from the iPhone.
    assert {"target": "FliBuddyWatch"} in deps
    assert watch["PRODUCT_BUNDLE_IDENTIFIER"].startswith(ios["PRODUCT_BUNDLE_IDENTIFIER"] + ".")
    assert watch["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] == ios["PRODUCT_BUNDLE_IDENTIFIER"]
    assert watch["GENERATE_INFOPLIST_FILE"] is True
    assert watch["INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription"].strip()
    # Bluetooth only in the foreground: no background modes.
    assert not any("BackgroundModes" in key for key in watch)


def test_the_ios_target_has_the_usage_descriptions_and_bundle_id():
    settings = ios_settings()
    assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "com.sokolachko.flibuddy"
    assert settings["GENERATE_INFOPLIST_FILE"] is True
    assert settings["INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription"].strip()
    assert settings["INFOPLIST_KEY_NSCameraUsageDescription"].strip()


def test_the_iphone_is_portrait_only_and_the_ipad_turns_every_way():
    # FliBuddy 1.0 has no landscape iPhone design; the iPad page draws both
    # orientations.
    settings = ios_settings()
    assert settings["INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone"].split() == [
        "UIInterfaceOrientationPortrait"
    ]
    assert set(settings["INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"].split()) == {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }


def test_the_ios_app_asks_for_local_network_access():
    # Bambuddy runs on the local network; iOS asks before the first request.
    assert ios_settings()["INFOPLIST_KEY_NSLocalNetworkUsageDescription"].strip()


def test_both_apps_talk_https_only():
    # FliBuddy 1.0 talks to Bambuddy over HTTPS only (owner decision), so
    # neither app carries an App Transport Security exception. The iOS
    # Info.plist only adds UIBackgroundModes, which INFOPLIST_KEY_* settings
    # cannot express; Xcode merges it with the keys it generates. The watch
    # app has no Info.plist of its own.
    for name in ("FliBuddyiOS", "FliBuddyWatch"):
        settings = spec()["targets"][name]["settings"]["base"]
        assert settings["GENERATE_INFOPLIST_FILE"] is True
        assert not [key for key in settings if "NSAppTransportSecurity" in key]
    assert ios_settings()["INFOPLIST_FILE"] == "iOS/Info.plist"
    info = plistlib.loads((APPLE / "iOS" / "Info.plist").read_bytes())
    assert "NSAppTransportSecurity" not in info
    assert info["UIBackgroundModes"] == ["bluetooth-central"]
    assert "INFOPLIST_FILE" not in watch_settings()
    assert not (APPLE / "Watch" / "Info.plist").exists()


def test_the_app_sources_exist():
    for target in spec()["targets"].values():
        for source in target["sources"]:
            assert (APPLE / source).is_dir()
    assert "@main" in (APPLE / "iOS" / "App.swift").read_text(encoding="utf-8")
    assert "@main" in (APPLE / "Watch" / "App.swift").read_text(encoding="utf-8")


def test_signing_stays_out_of_the_repository():
    project = spec()
    assert set(project["configFiles"].values()) == {"Base.xcconfig"}
    base = (APPLE / "Base.xcconfig").read_text(encoding="utf-8")
    # The optional include keeps builds working without Signing.xcconfig.
    assert '#include? "Signing.xcconfig"' in base
    example = (APPLE / "Signing.example.xcconfig").read_text(encoding="utf-8")
    assert "DEVELOPMENT_TEAM = " in example
    gitignore = (REPO / ".gitignore").read_text(encoding="utf-8").splitlines()
    assert "host/Apple/Signing.xcconfig" in gitignore
    assert "host/Apple/*.xcodeproj" in gitignore


def apple_build_recipe() -> list[str]:
    lines = (REPO / "Makefile").read_text(encoding="utf-8").splitlines()
    start = lines.index("apple-build:") + 1
    recipe = []
    for line in lines[start:]:
        if not line.startswith("\t"):
            break
        recipe.append(line.strip())
    # Join continuation lines; one entry per xcodebuild run.
    return " ".join(recipe).replace("\\ ", "").split("xcodebuild ")[1:]


def test_root_makefile_generates_and_builds_both_apps_unsigned():
    makefile = (REPO / "Makefile").read_text(encoding="utf-8")
    assert "apple-project:" in makefile
    assert "xcodegen generate" in makefile
    commands = apple_build_recipe()
    assert len(commands) == 2
    ios, watch = commands
    assert "-scheme FliBuddyiOS" in ios
    assert "generic/platform=iOS Simulator" in ios
    assert "-scheme FliBuddyWatch" in watch
    assert "generic/platform=watchOS Simulator" in watch
    for command in commands:
        assert "CODE_SIGNING_ALLOWED=NO" in command


def test_the_apps_are_named_flibuddy():
    project = spec()
    assert project["name"] == "FliBuddy"
    ios = ios_settings()
    watch = watch_settings()
    assert ios["PRODUCT_NAME"] == "FliBuddy"
    assert watch["PRODUCT_NAME"] == "FliBuddyWatch"
    assert ios["INFOPLIST_KEY_CFBundleDisplayName"] == "FliBuddy"
    assert watch["INFOPLIST_KEY_CFBundleDisplayName"] == "FliBuddy"
    # The owner's domain, not Bambuddy's.
    assert watch["PRODUCT_BUNDLE_IDENTIFIER"] == "com.sokolachko.flibuddy.watchkitapp"
    for settings in (ios, watch):
        for key, value in settings.items():
            if key.endswith("UsageDescription"):
                assert value.startswith("FliBuddy "), key


def test_root_makefile_builds_the_flibuddy_project():
    for command in apple_build_recipe():
        assert "-project FliBuddy.xcodeproj" in command


def test_both_apps_use_the_app_icon_and_accent_color_of_their_catalogs():
    for settings in (ios_settings(), watch_settings()):
        assert settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon"
        assert settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] == "AccentColor"
    assert (APPLE / "iOS/Assets.xcassets/AppIcon.appiconset").is_dir()
    assert (APPLE / "Watch/Assets.xcassets/AppIcon.appiconset").is_dir()


def test_both_apps_declare_the_privacy_manifest():
    # App Store Connect requires a manifest: no tracking, no collected data,
    # and the one required-reason API the apps use, UserDefaults (the
    # settings), for the app's own data (CA92.1). No other such API is used:
    # no file timestamps, boot time, disk space or active keyboards.
    for folder in ("iOS", "Watch"):
        manifest = plistlib.loads((APPLE / folder / "PrivacyInfo.xcprivacy").read_bytes())
        assert manifest["NSPrivacyTracking"] is False
        assert manifest["NSPrivacyTrackingDomains"] == []
        assert manifest["NSPrivacyCollectedDataTypes"] == []
        assert manifest["NSPrivacyAccessedAPITypes"] == [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }
        ]


def test_the_host_sources_use_no_other_required_reason_api():
    sources = REPO / "host" / "Sources"
    forbidden = (
        "attributesOfItem",
        "creationDate",
        "contentModificationDate",
        "systemUptime",
        "mach_absolute_time",
        "volumeAvailableCapacity",
        "systemFreeSize",
        "activeInputModes",
        "stat(",
        "statfs",
        ".creationDateKey",
        "fileModificationDate",
        "volumeAvailableCapacityKey",
    )
    for path in sources.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for name in forbidden:
            assert name not in text, f"{path.name} uses {name}: declare it in the privacy manifests"


def test_both_apps_declare_that_they_use_no_non_exempt_encryption():
    # HTTPS and the Keychain are exempt, so App Store Connect asks no export
    # compliance question per build.
    for settings in (ios_settings(), watch_settings()):
        assert settings["INFOPLIST_KEY_ITSAppUsesNonExemptEncryption"] is False


def test_the_apps_are_version_1_0_0_in_one_project_wide_setting():
    # `make apple-archive` overrides CURRENT_PROJECT_VERSION for both targets
    # at once, so the embedded watch app gets the iPhone app's build number.
    base = spec()["settings"]["base"]
    assert base["MARKETING_VERSION"] == "1.0.0"
    for name in ("FliBuddyiOS", "FliBuddyWatch"):
        target = spec()["targets"][name]["settings"]["base"]
        assert "MARKETING_VERSION" not in target
        assert "CURRENT_PROJECT_VERSION" not in target


def apple_archive_recipe() -> str:
    lines = (REPO / "Makefile").read_text(encoding="utf-8").splitlines()
    start = lines.index("apple-archive:") + 1
    recipe = []
    for line in lines[start:]:
        if not line.startswith("\t"):
            break
        recipe.append(line.strip())
    return " ".join(recipe).replace("\\ ", "")


def test_apple_archive_archives_and_exports_locally_without_uploading():
    recipe = apple_archive_recipe()
    assert "-scheme FliBuddyiOS" in recipe
    assert "-configuration Release" in recipe
    assert "generic/platform=iOS" in recipe
    assert "-allowProvisioningUpdates" in recipe
    assert "build=$$(git rev-list --count HEAD)" in recipe
    assert "CURRENT_PROJECT_VERSION=$$build" in recipe
    assert " archive" in recipe
    assert "-exportArchive" in recipe
    assert "-exportOptionsPlist" in recipe
    assert ".build/export" in recipe
    # Uploading to App Store Connect is a separate, confirmed step.
    assert "altool" not in recipe
    assert "notarytool" not in recipe


def test_the_export_options_export_for_app_store_connect_without_uploading():
    options = plistlib.loads((APPLE / "ExportOptions.plist").read_bytes())
    assert options["method"] == "app-store-connect"
    assert options["destination"] == "export"
    assert options["signingStyle"] == "automatic"
    # The team comes from the git-ignored Signing.xcconfig, not the repo.
    assert "teamID" not in options
    assert "Signing.xcconfig" in apple_archive_recipe()
    # A trailing comment or CRLF in the file cannot end up in the team id.
    assert "([A-Z0-9]+)" in apple_archive_recipe()


def test_the_store_screenshot_script_covers_the_required_devices():
    script = (REPO / "tools" / "store_shots.sh").read_text(encoding="utf-8")
    assert "sim_shot.sh" in script
    for device in ("iPhone 18 Pro Max", "iPad Pro 13-inch (M5)", "Apple Watch Series 12 (46mm)"):
        assert device in script
    assert "host/Apple/.build/store-shots" in script
    # A missing simulator fails before the first shot.
    assert script.index("simctl list devices") < script.index('"$shot"')
    for argument in ("-FliBuddyDemoSet store", "-FliBuddyDemoFocus none", "-FliBuddyDemoSheet link",
                     "-FliBuddyDemoSearch pla", "-FliBuddyDemoQR YES"):
        assert argument in script
