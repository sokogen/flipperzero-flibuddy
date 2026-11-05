"""The BLE workarounds were verified against one SDK API version.

flipper/src/ble_sdk_pin.h pins it; this fails when the installed ufbt SDK
reports another one, so a firmware bump forces a re-verification.
"""

import csv
import re
from pathlib import Path

import pytest

FLIPPER = Path(__file__).resolve().parents[2] / "flipper"
HEADER = FLIPPER / "src" / "ble_sdk_pin.h"
API_SYMBOLS = FLIPPER / ".ufbt" / "current" / "sdk_headers" / "f7_sdk" / "targets" / "f7" / "api_symbols.csv"


def pinned_version() -> str:
    match = re.search(r'^#define\s+FLIBUDDY_VERIFIED_SDK_API\s+"([0-9]+\.[0-9]+)"', HEADER.read_text(), re.MULTILINE)
    assert match, "FLIBUDDY_VERIFIED_SDK_API not found in ble_sdk_pin.h"
    return match.group(1)


def installed_version() -> str:
    with API_SYMBOLS.open(newline="") as f:
        for row in csv.reader(f):
            if row and row[0] == "Version":
                return row[2]
    raise AssertionError("no Version row in api_symbols.csv")


def test_pin_header_defines_a_version():
    assert re.fullmatch(r"[0-9]+\.[0-9]+", pinned_version())


def test_installed_sdk_is_the_one_the_ble_workarounds_were_verified_on():
    if not API_SYMBOLS.exists():
        pytest.skip("ufbt SDK not installed in flipper/.ufbt (run `ufbt update --branch=1.5.1` in flipper/)")
    assert installed_version() == pinned_version(), (
        "SDK API changed: re-verify the BLE workarounds named in src/ble_sdk_pin.h, "
        "then update FLIBUDDY_VERIFIED_SDK_API"
    )
