"""The XcodeGen spec of the Apple apps in `host/Apple`.

The generated Xcode project is not checked in; `make apple-project`
regenerates it from `project.yml` and `make apple-build` builds the iOS app
for the simulator without signing. These tests guard the spec, the signing
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


def test_the_ios_target_uses_the_local_package_products():
    project = spec()
    assert project["packages"]["SpoolBuddy"]["path"] == ".."
    deps = project["targets"]["SpoolBuddyiOS"]["dependencies"]
    assert {(d["package"], d["product"]) for d in deps} == {
        ("SpoolBuddy", "SpoolBuddyCore"),
        ("SpoolBuddy", "SpoolBuddyUI"),
    }


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


def test_root_makefile_generates_and_builds_the_ios_app_unsigned():
    makefile = (REPO / "Makefile").read_text(encoding="utf-8")
    assert "apple-project:" in makefile
    assert "xcodegen generate" in makefile
    assert "apple-build:" in makefile
    assert "-scheme SpoolBuddyiOS" in makefile
    assert "generic/platform=iOS Simulator" in makefile
    assert "CODE_SIGNING_ALLOWED=NO" in makefile
