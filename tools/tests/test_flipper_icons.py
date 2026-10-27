"""The Flipper app's XBM icons in flipper/images/, generated from the
bitmaps of the design prototype (docs/design/flipper/flipper-ui.js)."""

from pathlib import Path

import pytest

from fixtures import make_flipper_icons

REPO = Path(__file__).resolve().parents[2]


def test_icons_are_current():
    outputs = make_flipper_icons.build()
    assert sorted(outputs) == sorted(
        f"flipper/images/{name}.xbm"
        for name in (
            "usb",
            "bt",
            "check",
            "warn",
            "arrow_left",
            "arrow_right",
            "arrow_up",
            "arrow_down",
            "app",
            "app_2x",
        )
    )
    for relative, content in outputs.items():
        assert (REPO / relative).read_text(encoding="utf-8") == content, (
            f"{relative} is stale; regenerate with "
            "`uv run python -m fixtures.make_flipper_icons`"
        )


def test_bitmaps_are_read_from_the_design():
    bitmaps = make_flipper_icons.load_bitmaps()
    assert bitmaps["usb"] == [
        "....#####",
        "....#...#",
        "#####.#.#",
        "....#...#",
        "....#####",
    ]
    assert len(bitmaps["app"]) == 10
    assert {"bt", "check", "warn", "aL", "aR", "aU", "aD"} <= set(bitmaps)


def test_rows_are_packed_lsb_first_and_padded_to_bytes():
    assert make_flipper_icons.pack_row("#........") == [0x01, 0x00]
    assert make_flipper_icons.pack_row("....#####") == [0xF0, 0x01]
    assert make_flipper_icons.pack_row("........#") == [0x00, 0x01]
    assert make_flipper_icons.pack_row("##") == [0x03]


def test_xbm_carries_the_size_and_the_bits():
    xbm = make_flipper_icons.xbm("check", ["#.", ".#"])
    assert "#define check_width 2\n" in xbm
    assert "#define check_height 2\n" in xbm
    assert "static const unsigned char check_bits[] = {\n    0x01, 0x02,\n};\n" in xbm


def test_scale_doubles_every_pixel():
    assert make_flipper_icons.scale(["#.", ".#"], 2) == ["##..", "##..", "..##", "..##"]


def test_uneven_rows_are_refused():
    with pytest.raises(ValueError, match="uneven"):
        make_flipper_icons.xbm("bad", ["#.", "#"])


def test_a_missing_icon_block_is_refused(tmp_path):
    js = tmp_path / "ui.js"
    js.write_text("export const W = 128;\n", encoding="utf-8")
    with pytest.raises(ValueError, match="icon table"):
        make_flipper_icons.load_bitmaps(js)
