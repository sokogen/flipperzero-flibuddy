"""The BLE workarounds were verified against one SDK API version.

flipper/src/ble_sdk_pin.h pins it; this fails when the installed ufbt SDK
reports another one, so a firmware bump forces a re-verification.

The SDK is looked up where ufbt puts it: `$UFBT_HOME` when set (relative to
flipper/, as ufbt runs there), else flipper/.ufbt (the git-ignored
flipper/.env of dotenv mode). Without an SDK the check skips, unless
`UFBT_HOME` is set: then an SDK is expected there (the flipper CI job sets
it before fetching one) and its absence fails.
"""

import csv
import os
import re
from pathlib import Path

import pytest

FLIPPER = Path(__file__).resolve().parents[2] / "flipper"
HEADER = FLIPPER / "src" / "ble_sdk_pin.h"
API_SYMBOLS = Path("current") / "sdk_headers" / "f7_sdk" / "targets" / "f7" / "api_symbols.csv"


def sdk_home(env: dict[str, str]) -> Path:
    home = env.get("UFBT_HOME")
    return FLIPPER / home if home else FLIPPER / ".ufbt"


def api_symbols(env: dict[str, str]) -> Path:
    return sdk_home(env) / API_SYMBOLS


def sdk_expected(env: dict[str, str]) -> bool:
    return bool(env.get("UFBT_HOME"))


def pinned_version() -> str:
    match = re.search(r'^#define\s+FLIBUDDY_VERIFIED_SDK_API\s+"([0-9]+\.[0-9]+)"', HEADER.read_text(), re.MULTILINE)
    assert match, "FLIBUDDY_VERIFIED_SDK_API not found in ble_sdk_pin.h"
    return match.group(1)


def installed_version(path: Path) -> str:
    with path.open(newline="") as f:
        for row in csv.reader(f):
            if row and row[0] == "Version":
                return row[2]
    raise AssertionError("no Version row in api_symbols.csv")


def test_pin_header_defines_a_version():
    assert re.fullmatch(r"[0-9]+\.[0-9]+", pinned_version())


def test_the_sdk_is_looked_up_in_ufbt_home_relative_to_flipper():
    assert api_symbols({}) == FLIPPER / ".ufbt" / API_SYMBOLS
    assert api_symbols({"UFBT_HOME": ".ufbt"}) == FLIPPER / ".ufbt" / API_SYMBOLS
    assert api_symbols({"UFBT_HOME": "/opt/sdk"}) == Path("/opt/sdk") / API_SYMBOLS


def test_an_sdk_is_expected_only_when_ufbt_home_is_set():
    assert not sdk_expected({})
    assert not sdk_expected({"CI": "true"})
    assert sdk_expected({"UFBT_HOME": "/home/runner/work/x/flipper/.ufbt"})


def test_installed_sdk_is_the_one_the_ble_workarounds_were_verified_on():
    env = dict(os.environ)
    path = api_symbols(env)
    if not path.exists():
        if sdk_expected(env):
            pytest.fail(f"UFBT_HOME is set but there is no SDK at {sdk_home(env)}")
        pytest.skip("ufbt SDK not installed in flipper/.ufbt (run `ufbt update --branch=1.5.1` in flipper/)")
    assert installed_version(path) == pinned_version(), (
        "SDK API changed: re-verify the BLE workarounds named in src/ble_sdk_pin.h, "
        "then update FLIBUDDY_VERIFIED_SDK_API"
    )
