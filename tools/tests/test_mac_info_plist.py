"""The Info.plist embedded in the SpoolBuddyMac executable.

`swift run` starts a bare executable; macOS ends it on the first CoreBluetooth
call unless the binary carries a Bluetooth usage description. Package.swift
links `host/Sources/SpoolBuddyMac/Info.plist` into its `__TEXT,__info_plist`
section.
"""

import plistlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PLIST = REPO / "host" / "Sources" / "SpoolBuddyMac" / "Info.plist"
MANIFEST = REPO / "host" / "Package.swift"


def test_the_plist_describes_bluetooth_use():
    info = plistlib.loads(PLIST.read_bytes())
    assert info["NSBluetoothAlwaysUsageDescription"].strip()

def test_the_plist_has_no_bundle_identifier():
    # A bundle identifier would move UserDefaults.standard from the
    # `SpoolBuddyMac` domain (the process name) and lose the saved settings.
    info = plistlib.loads(PLIST.read_bytes())
    assert "CFBundleIdentifier" not in info


def test_the_manifest_embeds_the_plist_on_macos():
    manifest = MANIFEST.read_text(encoding="utf-8")
    assert '"/Sources/SpoolBuddyMac/Info.plist"' in manifest
    assert '"__info_plist"' in manifest
    assert '"-sectcreate"' in manifest
    assert ".when(platforms: [.macOS])" in manifest
    assert 'exclude: ["Info.plist"]' in manifest
