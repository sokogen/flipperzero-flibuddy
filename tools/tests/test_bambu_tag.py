"""The bridge's Bambu tag parser against the protocol tag fixtures."""

import json
import struct
from pathlib import Path

import pytest

from bridge import bambu_tag
from fixtures import make_message_fixtures

PROTOCOL = Path(__file__).resolve().parents[2] / "protocol"
TAGS = PROTOCOL / "fixtures" / "tags"
MESSAGES = PROTOCOL / "fixtures" / "messages"


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def bambu_dump() -> dict:
    return load(TAGS / "bambu_pla_basic_synthetic.json")


def bambu_scan_tag(missing: list[int] | None = None) -> dict:
    """The fixture dump as a `scan` tag object (trailers dropped)."""
    return make_message_fixtures.mfc_tag(bambu_dump(), missing or [])


def test_parses_the_synthetic_bambu_fixture():
    dump = bambu_dump()
    parsed = bambu_tag.parse_tag(bambu_scan_tag())

    assert parsed.kind == "bambu"
    assert parsed.uid == "5A3C9E21"
    assert parsed.material == "PLA"
    assert parsed.detailed_type == "PLA Basic"
    assert parsed.variant_id == "A00-W1"
    assert parsed.material_id == "GFA00"
    assert parsed.rgba == "FFFFFFFF"
    assert parsed.label_weight == 1000
    assert parsed.diameter == pytest.approx(1.75)
    assert parsed.drying_temp == 55
    assert parsed.drying_hours == 8
    assert parsed.bed_temp == 35
    assert parsed.nozzle_max == 230
    assert parsed.nozzle_min == 190
    assert parsed.has_prefill is True

    assert parsed.tray_uuid == dump["blocks"][9]


def test_parses_the_real_bambu_dump():
    """The PLA Pure spool captured by the bridge in Phase 0 (sectors 3-15 missing)."""
    dump = load(TAGS / "bambu_pla_pure_real.json")
    assert dump["synthetic"] is False
    assert dump["missing"] == list(range(3, 16))
    parsed = bambu_tag.parse_tag(dump)

    assert parsed.kind == "bambu"
    assert parsed.uid == "7EF1AB04"
    assert parsed.tray_uuid == "F1C8FDF0BC1643C0B37189ADB0687992"
    assert parsed.material == "PLA"
    assert parsed.detailed_type == "PLA Pure"
    assert parsed.variant_id == "A19-B00"
    assert parsed.material_id == "GFA19"
    assert parsed.rgba == "A4DBE8FF"
    assert parsed.label_weight == 1000
    assert parsed.diameter == pytest.approx(1.75)
    assert parsed.drying_temp == 55
    assert parsed.drying_hours == 8
    assert parsed.nozzle_max == 230
    assert parsed.nozzle_min == 190
    assert parsed.has_prefill is True
    assert parsed.display_lines() == ["PLA Pure", "#A4DBE8FF", "label 1000 g"]

    # the Flipper's `scan` (trailers dropped) parses the same
    scan = make_message_fixtures.mfc_tag(dump, dump["missing"])
    assert bambu_tag.parse_tag(scan) == parsed


def test_parses_the_scan_fixture_with_a_missing_sector():
    tag = load(MESSAGES / "scan_mfc.json")["tag"]
    parsed = bambu_tag.parse_tag(tag)
    assert parsed.material == "PLA"
    assert parsed.tray_uuid == "FCFFA95B29EA71C5A36D7A067DF82014"


def test_accepts_the_fixture_file_block_list():
    assert bambu_tag.parse_tag(bambu_dump()) == bambu_tag.parse_tag(bambu_scan_tag())


def test_missing_sector_1_drops_the_prefill():
    parsed = bambu_tag.parse_tag(bambu_scan_tag(missing=[1]))
    assert parsed.kind == "bambu"
    assert parsed.material == "PLA"  # block 2 is in sector 0
    assert parsed.detailed_type is None
    assert parsed.rgba is None
    assert parsed.label_weight is None
    assert parsed.tray_uuid == bambu_dump()["blocks"][9]


def test_missing_sector_0_has_no_material_and_no_prefill():
    parsed = bambu_tag.parse_tag(bambu_scan_tag(missing=[0]))
    assert parsed.material is None
    assert parsed.has_prefill is False


def test_missing_sector_2_has_no_tray_uuid():
    parsed = bambu_tag.parse_tag(bambu_scan_tag(missing=[2]))
    assert parsed.tray_uuid is None
    assert parsed.detailed_type == "PLA Basic"


def test_absent_block_9_has_no_tray_uuid():
    tag = bambu_scan_tag()
    del tag["blocks"]["9"]
    assert bambu_tag.parse_tag(tag).tray_uuid is None


def test_zero_block_9_has_no_tray_uuid():
    tag = bambu_scan_tag()
    tag["blocks"]["9"] = "00" * 16
    assert bambu_tag.parse_tag(tag).tray_uuid is None


def test_blocks_4_and_5_are_never_a_tray_uuid():
    # The SpoolBuddy daemon reads ASCII hex from blocks 4+5; Phase 0 showed the
    # AMS tray_uuid is block 9, so blocks 4+5 are the detailed type only.
    tag = bambu_scan_tag()
    text = b"0123456789abcdef0123456789ABCDEF"
    tag["blocks"]["4"] = text[:16].hex().upper()
    tag["blocks"]["5"] = text[16:].hex().upper()
    tag["blocks"]["9"] = "00" * 16
    assert bambu_tag.parse_tag(tag).tray_uuid is None


def test_zero_label_weight_reads_as_unknown():
    tag = bambu_scan_tag()
    block5 = bytearray(bytes.fromhex(tag["blocks"]["5"]))
    block5[4:6] = struct.pack("<H", 0)
    tag["blocks"]["5"] = block5.hex().upper()
    assert bambu_tag.parse_tag(tag).label_weight is None


def test_non_ascii_material_reads_as_unknown():
    tag = bambu_scan_tag()
    tag["blocks"]["2"] = "FF" * 16
    parsed = bambu_tag.parse_tag(tag)
    assert parsed.material is None
    assert parsed.has_prefill is False


def test_ntag_fixture_is_uid_only():
    parsed = bambu_tag.parse_tag(load(MESSAGES / "scan_ntag.json")["tag"])
    assert parsed.kind == "ntag"
    assert parsed.uid == "04112233445566"
    assert parsed.tray_uuid is None
    assert parsed.material is None
    assert parsed.has_prefill is False


def test_ntag_fixture_file_page_list():
    parsed = bambu_tag.parse_tag(load(TAGS / "ntag215_blank.json"))
    assert parsed.kind == "ntag"
    assert parsed.uid == "04112233445566"


def test_display_lines_for_a_bambu_tag_match_the_lookup_fixture():
    parsed = bambu_tag.parse_tag(bambu_scan_tag())
    assert parsed.display_lines() == load(MESSAGES / "lookup_unknown.json")["lines"]


def test_display_lines_for_an_ntag():
    parsed = bambu_tag.parse_tag(load(MESSAGES / "scan_ntag.json")["tag"])
    assert parsed.display_lines() == ["NTAG", "UID 04112233445566"]


def test_display_lines_fit_the_flipper_screen():
    tag = bambu_scan_tag()
    tag["blocks"]["4"] = ("Z" * 16).encode().hex().upper()
    for lines in (
        bambu_tag.parse_tag(tag).display_lines(),
        bambu_tag.parse_tag(bambu_scan_tag(missing=[0, 1])).display_lines(),
    ):
        assert 1 <= len(lines) <= 4
        assert all(len(line) <= 40 for line in lines)


def test_as_dict_is_json_serialisable():
    parsed = bambu_tag.parse_tag(bambu_scan_tag())
    data = json.loads(json.dumps(parsed.as_dict()))
    assert data["material"] == "PLA"
    assert data["tray_uuid"] == parsed.tray_uuid
