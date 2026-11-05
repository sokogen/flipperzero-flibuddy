"""App icons: the SVGs, the 1024 px PNGs in the asset catalogs and the
Flipper's 10x10 icon, all generated from the formulas of
docs/design/source/FliBuddy App Icon.dc.html."""

import json
import shutil
from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image

from fixtures import make_app_icons as icons

REPO = Path(__file__).resolve().parents[2]
IOS = REPO / "host/Apple/iOS/Assets.xcassets"
WATCH = REPO / "host/Apple/Watch/Assets.xcassets"

needs_rsvg = pytest.mark.skipif(
    shutil.which("rsvg-convert") is None, reason="rsvg-convert not installed"
)


# Computed by running the design's JS antenna() in node.
def test_antenna_matches_the_design_script_for_the_coil():
    assert icons.antenna(300, 24, 8, 215, 34) == (
        "M812 512 A300 300 0 1 1 212 512 A300 300 0 1 1 812 512 Z "
        "M788 512 A276 276 0 1 1 236 512 A276 276 0 1 1 788 512 Z "
        "M272.5 433.8 A252 252 0 1 1 272.5 590.2 A82 82 0 1 0 272.5 433.8 Z "
        "M309.7 406.8 A228 228 0 1 1 309.7 617.2 A106 106 0 0 0 309.7 406.8 Z "
        "M347.0 392.0 A204 204 0 1 1 347.0 632.0 A130 130 0 0 0 347.0 392.0 Z "
        "M384.3 385.1 A180 180 0 1 1 384.3 638.9 A154 154 0 0 0 384.3 385.1 Z "
        "M421.6 384.9 A156 156 0 1 1 421.6 639.1 A178 178 0 0 0 421.6 384.9 Z "
        "M458.9 391.2 A132 132 0 1 1 458.9 632.8 A202 202 0 0 0 458.9 391.2 Z "
    )


def test_antenna_matches_the_design_script_for_the_small_coil():
    assert icons.antenna(296, 44, 4, 210, 40) == (
        "M808 512 A296 296 0 1 1 216 512 A296 296 0 1 1 808 512 Z "
        "M272.6 433.3 A252 252 0 1 1 272.6 590.7 A84 84 0 1 0 272.6 433.3 Z "
        "M343.0 390.7 A208 208 0 1 1 343.0 633.3 A128 128 0 0 0 343.0 390.7 Z "
        "M413.4 381.0 A164 164 0 1 1 413.4 643.0 A172 172 0 0 0 413.4 381.0 Z "
    )


def test_antenna_matches_the_design_script_for_the_hub_coil():
    assert icons.antenna(140, 12, 6, 100, 16).startswith(
        "M652 512 A140 140 0 1 1 372 512 A140 140 0 1 1 652 512 Z "
        "M640 512 A128 128 0 1 1 384 512 A128 128 0 1 1 640 512 Z "
        "M402.7 473.1 A116 116 0 1 1 402.7 550.9 A40 40 0 1 0 402.7 473.1 Z "
    )


def test_the_svgs_carry_the_variants_of_the_design():
    svgs = icons.svgs()
    assert sorted(svgs) == [
        "docs/design/icons/flibuddy-dark.svg",
        "docs/design/icons/flibuddy-light.svg",
        "docs/design/icons/flibuddy-small.svg",
        "docs/design/icons/flibuddy-tinted.svg",
        "docs/design/icons/flibuddy-watch.svg",
    ]
    light = svgs["docs/design/icons/flibuddy-light.svg"]
    assert icons.antenna(300, 24, 8, 215, 34) in light
    assert '"#EEF1F4"' in light and '"#FF7A1A"' in light and '"#8C97A3"' in light
    assert '"#121314"' in svgs["docs/design/icons/flibuddy-dark.svg"]
    assert '"#FF8A2B"' in svgs["docs/design/icons/flibuddy-dark.svg"]
    assert '"#BDBDBD"' in svgs["docs/design/icons/flibuddy-tinted.svg"]
    small = svgs["docs/design/icons/flibuddy-small.svg"]
    assert icons.antenna(296, 44, 4, 210, 40) in small
    watch = svgs["docs/design/icons/flibuddy-watch.svg"]
    assert 'fill="#141416"' in watch and "scale(1.1)" in watch
    assert '"#FF8A2B"' in watch and 'stroke-width="13"' in watch
    assert 'r="7"' not in watch  # no pad dots on the watch


def png(relative: str) -> Image.Image:
    return Image.open(REPO / relative)


CATALOG_PNGS = [
    "host/Apple/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-Light.png",
    "host/Apple/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png",
    "host/Apple/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png",
    "host/Apple/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
]


@pytest.mark.parametrize("relative", CATALOG_PNGS)
def test_catalog_icons_are_1024_square_without_alpha(relative):
    image = png(relative)
    assert image.size == (1024, 1024)
    assert image.mode == "RGB"


def test_the_tinted_icon_is_grayscale_only():
    image = png(CATALOG_PNGS[2])
    assert all(r == g == b for r, g, b in image.get_flattened_data())


def test_the_watch_icon_is_dark_to_the_corners():
    image = png(CATALOG_PNGS[3])
    for corner in [(0, 0), (1023, 0), (0, 1023), (1023, 1023)]:
        assert image.getpixel(corner) == (0x14, 0x14, 0x16)


def test_the_light_icon_is_light_and_the_dark_one_is_dark():
    assert png(CATALOG_PNGS[0]).getpixel((2, 2)) == (0xEE, 0xF1, 0xF4)
    assert png(CATALOG_PNGS[1]).getpixel((2, 2)) == (0x12, 0x13, 0x14)


def test_the_flipper_icon_is_the_design_bitmap_in_pure_black_and_white():
    image = png("flipper/icons/flibuddy_10px.png")
    assert image.size == (10, 10)
    assert image.mode == "1"
    colors = {c for _, c in image.convert("RGB").getcolors()}
    assert colors == {(0, 0, 0), (255, 255, 255)}
    for y, row in enumerate(icons.APP):
        for x, ch in enumerate(row):
            expected = (0, 0, 0) if ch == "#" else (255, 255, 255)
            assert image.convert("RGB").getpixel((x, y)) == expected


def test_the_app_bitmap_is_the_one_of_the_flipper_prototype():
    from fixtures import make_flipper_icons

    assert icons.APP == make_flipper_icons.load_bitmaps()["app"]


def test_flipper_png_has_no_extra_chunks():
    data = icons.flipper_png()
    assert Image.open(BytesIO(data)).info.keys() <= {"dpi", "gamma"}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_ios_catalog_has_light_dark_and_tinted_single_size_icons():
    images = load(IOS / "AppIcon.appiconset/Contents.json")["images"]
    by_name = {i["filename"]: i for i in images}
    assert set(by_name) == {
        "AppIcon-Light.png",
        "AppIcon-Dark.png",
        "AppIcon-Tinted.png",
    }
    for image in images:
        assert image["idiom"] == "universal"
        assert image["platform"] == "ios"
        assert image["size"] == "1024x1024"
    assert "appearances" not in by_name["AppIcon-Light.png"]
    assert by_name["AppIcon-Dark.png"]["appearances"] == [
        {"appearance": "luminosity", "value": "dark"}
    ]
    assert by_name["AppIcon-Tinted.png"]["appearances"] == [
        {"appearance": "luminosity", "value": "tinted"}
    ]


def test_watch_catalog_has_one_single_size_icon():
    images = load(WATCH / "AppIcon.appiconset/Contents.json")["images"]
    assert images == [
        {
            "filename": "AppIcon.png",
            "idiom": "universal",
            "platform": "watchos",
            "size": "1024x1024",
        }
    ]


@pytest.mark.parametrize("catalog", [IOS, WATCH])
def test_accent_color_keeps_the_system_blue_tint(catalog):
    # Orange is only the icon's chip colour; the UI tint stays system blue.
    colors = load(catalog / "AccentColor.colorset/Contents.json")["colors"]

    def rgb(color):
        c = color["color"]["components"]
        return [round(float(c[k]) * 255) for k in ("red", "green", "blue")]

    light = [c for c in colors if "appearances" not in c]
    dark = [c for c in colors if "appearances" in c]
    assert [rgb(c) for c in light] == [[0x00, 0x7A, 0xFF]]
    assert [rgb(c) for c in dark] == [[0x0A, 0x84, 0xFF]]
    assert dark[0]["appearances"] == [{"appearance": "luminosity", "value": "dark"}]


@pytest.mark.parametrize("catalog", [IOS, WATCH])
def test_catalog_root_has_contents(catalog):
    assert (catalog / "Contents.json").is_file()


@needs_rsvg
def test_committed_files_are_current():
    for relative, content in icons.build().items():
        committed = (REPO / relative).read_bytes()
        if not relative.endswith(".png"):
            assert committed == content, f"{relative} is stale: run make icons"
            continue
        # Rasterisers differ between librsvg builds by a rounding error.
        old = Image.open(BytesIO(committed))
        new = Image.open(BytesIO(content))
        assert old.size == new.size and old.mode == new.mode, relative
        worst = max(
            max(abs(a - b) for a, b in zip(p, q, strict=True))
            for p, q in zip(
                old.convert("RGB").get_flattened_data(),
                new.convert("RGB").get_flattened_data(),
                strict=True,
            )
        )
        assert worst <= 8, f"{relative} is stale: run make icons"
