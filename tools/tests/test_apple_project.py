"""The XcodeGen spec of the Apple apps in `host/Apple`.

The generated Xcode project is not checked in; `make apple-project`
regenerates it from `project.yml` and `make apple-build` builds the iOS and
watch apps for the simulators without signing. These tests guard the spec, the signing
files and the Makefile targets, which no other suite exercises.
"""

from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
APPLE = REPO / "host" / "Apple"


def spec() -> dict:
    return yaml.safe_load((APPLE / "project.yml").read_text(encoding="utf-8"))


def ios_settings() -> dict:
    return spec()["targets"]["SpoolBuddyiOS"]["settings"]["base"]


def test_the_ios_target_runs_on_iphone_and_ipad_from_ios_26():
    target = spec()["targets"]["SpoolBuddyiOS"]
    assert target["type"] == "application"
    assert target["platform"] == "iOS"
    assert target["deploymentTarget"] == "26.0"
    assert ios_settings()["TARGETED_DEVICE_FAMILY"] == "1,2"


def watch_settings() -> dict:
    return spec()["targets"]["SpoolBuddyWatch"]["settings"]["base"]


def package_products(target: str) -> set:
    deps = spec()["targets"][target]["dependencies"]
    return {(d["package"], d["product"]) for d in deps if "package" in d}


def test_the_ios_target_uses_the_local_package_products():
    assert spec()["packages"]["SpoolBuddy"]["path"] == ".."
    assert package_products("SpoolBuddyiOS") == {
        ("SpoolBuddy", "SpoolBuddyCore"),
        ("SpoolBuddy", "SpoolBuddyUI"),
    }


def test_the_watch_target_runs_on_watchos_26():
    project = spec()
    target = project["targets"]["SpoolBuddyWatch"]
    assert target["type"] == "application"
    assert target["platform"] == "watchOS"
    assert target["deploymentTarget"] == "26.0"
    assert project["options"]["deploymentTarget"]["watchOS"] == "26.0"
    assert watch_settings()["TARGETED_DEVICE_FAMILY"] == "4"
    assert package_products("SpoolBuddyWatch") == {
        ("SpoolBuddy", "SpoolBuddyCore"),
        ("SpoolBuddy", "SpoolBuddyUI"),
    }


def test_the_watch_app_is_the_ios_apps_companion():
    ios = ios_settings()
    watch = watch_settings()
    deps = spec()["targets"]["SpoolBuddyiOS"]["dependencies"]
    # Embedding the watch app makes it install from the iPhone.
    assert {"target": "SpoolBuddyWatch"} in deps
    assert watch["PRODUCT_BUNDLE_IDENTIFIER"].startswith(ios["PRODUCT_BUNDLE_IDENTIFIER"] + ".")
    assert watch["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] == ios["PRODUCT_BUNDLE_IDENTIFIER"]
    assert watch["GENERATE_INFOPLIST_FILE"] is True
    assert watch["INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription"].strip()
    # Bluetooth only in the foreground: no background modes.
    assert not any("BackgroundModes" in key for key in watch)


def test_the_ios_target_has_the_usage_descriptions_and_bundle_id():
    settings = ios_settings()
    assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "cool.bambuddy.spoolbuddy"
    assert settings["GENERATE_INFOPLIST_FILE"] is True
    assert settings["INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription"].strip()
    assert settings["INFOPLIST_KEY_NSCameraUsageDescription"].strip()


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
    assert "-scheme SpoolBuddyiOS" in ios
    assert "generic/platform=iOS Simulator" in ios
    assert "-scheme SpoolBuddyWatch" in watch
    assert "generic/platform=watchOS Simulator" in watch
    for command in commands:
        assert "CODE_SIGNING_ALLOWED=NO" in command
