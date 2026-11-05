"""The Flipper app's XBM icons in flipper/images/, generated from the
bitmaps of the design prototype (docs/design/source/flipper-ui.js), and
the Get app QR code, generated from its URL into both."""

import re
from pathlib import Path

import pytest
import zxingcpp
from PIL import Image

from fixtures import make_flipper_icons

REPO = Path(__file__).resolve().parents[2]
QR_XBM = REPO / "flipper" / "images" / "qr_get_app.xbm"


def test_icons_are_current():
    outputs = make_flipper_icons.build()
    assert sorted(outputs) == sorted(
        [
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
                "ok_button",
                "qr_get_app",
            )
        ]
        + ["docs/design/source/flipper-ui.js"]
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


def read_xbm(path: Path) -> list[str]:
    """The rows of an XBM file as '#' (ink) and '.' (paper)."""
    text = path.read_text(encoding="utf-8")
    width = int(re.search(r"_width (\d+)", text).group(1))
    height = int(re.search(r"_height (\d+)", text).group(1))
    data = [int(b, 16) for b in re.findall(r"0x([0-9a-f]{2})", text)]
    per_row = (width + 7) // 8
    assert len(data) == per_row * height
    return [
        "".join("#" if data[y * per_row + x // 8] >> (x % 8) & 1 else "." for x in range(width))
        for y in range(height)
    ]


def decode(rows: list[str], quiet: int = 8, zoom: int = 4) -> list[str]:
    """What a QR reader sees in the bitmap, on paper with a quiet zone."""
    size = (len(rows[0]) + 2 * quiet, len(rows) + 2 * quiet)
    img = Image.new("L", size, 255)
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == "#":
                img.putpixel((x + quiet, y + quiet), 0)
    img = img.resize((size[0] * zoom, size[1] * zoom), Image.Resampling.NEAREST)
    return [r.text for r in zxingcpp.read_barcodes(img)]


def test_the_get_app_qr_code_decodes_to_the_landing_page():
    assert make_flipper_icons.GET_APP_URL == "https://sokogen.github.io/flipperzero-flibuddy/"
    assert decode(read_xbm(QR_XBM)) == [make_flipper_icons.GET_APP_URL]


def test_the_get_app_qr_code_is_version_3_at_2_px_a_module():
    # 29 modules x 2 px = 58 px: it fits the 64 px screen with 3 px clear.
    rows = read_xbm(QR_XBM)
    assert len(rows) == len(rows[0]) == 58
    modules = make_flipper_icons.qr_rows(make_flipper_icons.GET_APP_URL)
    assert len(modules) == len(modules[0]) == 29
    assert rows == make_flipper_icons.scale(modules, 2)


def test_the_design_shows_the_same_qr_code():
    assert make_flipper_icons.load_bitmaps()["qr"] == make_flipper_icons.qr_rows(make_flipper_icons.GET_APP_URL)


def test_the_qr_line_of_the_design_is_replaced_in_place():
    js = "const I = {\n  a: ['#'],\n  qr: ['.'],\n};\n"
    out = make_flipper_icons.with_qr_line(js, ["#.", ".#"])
    assert out == "const I = {\n  a: ['#'],\n  qr: ['#.', '.#'],\n};\n"


def test_a_design_without_a_qr_line_is_refused():
    with pytest.raises(ValueError, match="qr"):
        make_flipper_icons.with_qr_line("const I = {\n};\n", ["#"])


def test_the_ok_chip_icon_is_the_firmwares():
    # Drawn when the OK chip moves aside (ui_draw.c), as ButtonCenter_7x7.
    assert make_flipper_icons.load_bitmaps()["okBtn"] == [
        "..###..",
        ".#...#.",
        "#.###.#",
        "#.###.#",
        "#.###.#",
        ".#...#.",
        "..###..",
    ]
