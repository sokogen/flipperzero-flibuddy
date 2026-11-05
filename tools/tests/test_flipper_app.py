"""flipper/application.fam as the Flipper Apps Catalog reads it, and the
app's version, which lives in the fam and in flipper/src/flibuddy_app.h."""

import re
from pathlib import Path

FLIPPER = Path(__file__).resolve().parents[2] / "flipper"
FAM = FLIPPER / "application.fam"
APP_HEADER = FLIPPER / "src" / "flibuddy_app.h"


def fam_text() -> str:
    return FAM.read_text(encoding="utf-8")


def fam_field(name: str) -> str:
    match = re.search(rf'^\s*{name}="([^"]*)",$', fam_text(), re.MULTILINE)
    assert match, f"{name} not found in application.fam"
    return match.group(1)


def header_version() -> str:
    match = re.search(r'^#define\s+FLIBUDDY_VERSION\s+"([^"]+)"', APP_HEADER.read_text(encoding="utf-8"), re.MULTILINE)
    assert match, "FLIBUDDY_VERSION not found in flibuddy_app.h"
    return match.group(1)


def test_the_fam_defines_one_external_app():
    assert fam_text().count("App(") == 1
    assert "apptype=FlipperAppType.EXTERNAL," in fam_text()
    assert fam_field("appid") == "flibuddy"
    assert fam_field("name") == "FliBuddy"


def test_the_app_is_listed_under_nfc_with_its_web_page():
    assert fam_field("fap_category") == "NFC"
    assert fam_field("fap_weburl") == "https://github.com/sokogen/flipperzero-flibuddy"
    assert fam_field("fap_author") == "Gennady Sokolachko"
    assert fam_field("fap_icon") == "icons/flibuddy_10px.png"


def test_the_version_is_major_minor():
    # The catalog wants "major.minor" and rejects an update that does not
    # raise it.
    assert re.fullmatch(r"[0-9]+\.[0-9]+", fam_field("fap_version"))


def test_the_app_reports_the_version_of_its_fam():
    # Shown on Waiting and About and sent in `hello`; one version for both.
    assert header_version() == fam_field("fap_version") == "1.0"


def test_the_description_is_plain_ascii_and_short():
    description = fam_field("fap_description")
    assert description.isascii()
    assert len(description) <= 100
