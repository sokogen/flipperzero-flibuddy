"""Emit the app icons from the formulas of the design
(docs/design/source/FliBuddy App Icon.dc.html).

* docs/design/icons/*.svg: the iOS light, dark and tinted icons, the
  small-size variant (below 64 px) and the watchOS one;
* the 1024 px PNGs of the iOS and watch asset catalogs, rasterised with
  `rsvg-convert` (librsvg) and stripped of alpha; the tinted one is
  grayscale only;
* flipper/icons/flibuddy_10px.png: the 10x10 1-bit `APP` bitmap, pure
  black and white (the Flipper catalog rejects greys).

The PNGs are committed, so building the apps needs neither Python nor
librsvg. `tests/test_app_icons.py` fails when a file is stale.

Run from tools/: `uv run python -m fixtures.make_app_icons` (or `make icons`).
"""

import subprocess
from io import BytesIO
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[2]

# The Flipper bitmap of the design: '#' is ink.
APP = [
    "..######..",
    ".#......#.",
    "#..####..#",
    "#.#....#.#",
    "#.#.##.#.#",
    "#.#.##.#.#",
    "#.#....#.#",
    "#..####..#",
    ".#......#.",
    "..######..",
]

SVG_DIR = "docs/design/icons"
IOS_SET = "host/Apple/iOS/Assets.xcassets/AppIcon.appiconset"
WATCH_SET = "host/Apple/Watch/Assets.xcassets/AppIcon.appiconset"
FLIPPER_ICON = "flipper/icons/flibuddy_10px.png"


def antenna(R0: float, pitch: float, n: int, d: float, r0: float) -> str:
    """NFC antenna loops, a port of the design's JS `antenna()`.

    Outer loops are full circles around the centre; inner loops follow the
    centre circle on the right and bend into ")" arcs around the left
    contact pad, leaving a crescent for the chip.
    """
    from math import sqrt

    c = 512

    def f(x: float) -> str:
        return f"{x:.1f}"

    def num(x: float) -> str:
        return str(int(x)) if x == int(x) else repr(x)

    s = ""
    for i in range(n):
        R = R0 - pitch * i
        r = r0 + pitch * i
        if r <= R - d:
            s += (
                f"M{num(c + R)} {c} A{num(R)} {num(R)} 0 1 1 {num(c - R)} {c} "
                f"A{num(R)} {num(R)} 0 1 1 {num(c + R)} {c} Z "
            )
            continue
        a = (R * R - r * r + d * d) / (2 * d)
        h = sqrt(R * R - a * a)
        x = c - a
        s += (
            f"M{f(x)} {f(c - h)} A{num(R)} {num(R)} 0 {1 if a > 0 else 0} 1 "
            f"{f(x)} {f(c + h)} A{num(r)} {num(r)} 0 {1 if a > d else 0} 0 "
            f"{f(x)} {f(c - h)} Z "
        )
    return s


COIL = antenna(300, 24, 8, 215, 34)
COIL_SMALL = antenna(296, 44, 4, 210, 40)

# The iOS variants of the design: bg, glow, disk, rim, coil, chip.
IOS_VARIANTS = {
    "light": {
        "bg": "#EEF1F4",
        "glow": "#E1E6EC",
        "disk": "#FAFBFC",
        "rim": "#6B7682",
        "coil": "#8C97A3",
        "chip": "#FF7A1A",
    },
    "dark": {
        "bg": "#121314",
        "glow": "#1A1B1D",
        "disk": "#1C1E21",
        "rim": "#5E6873",
        "coil": "#9AA5B1",
        "chip": "#FF8A2B",
    },
    "tinted": {
        "bg": "#0B0B0C",
        "glow": "#141415",
        "disk": "#1C1C1E",
        "rim": "#6A6A6E",
        "coil": "#BDBDBD",
        "chip": "#FFFFFF",
    },
}

PADS = (
    '<circle cx="284" cy="499" r="7"/><circle cx="310" cy="499" r="7"/>'
    '<circle cx="284" cy="525" r="7"/><circle cx="310" cy="525" r="7"/>'
    '<circle cx="547" cy="559" r="6"/><circle cx="569" cy="559" r="6"/>'
    '<circle cx="547" cy="581" r="6"/><circle cx="569" cy="581" r="6"/>'
)
CHIP = (
    '<circle cx="297" cy="512" r="40"/>'
    '<rect x="520" y="424" width="76" height="72" rx="10"/>'
    '<rect x="546" y="490" width="24" height="60"/>'
    '<circle cx="558" cy="570" r="28"/>'
)
CHIP_SMALL = (
    '<circle cx="302" cy="512" r="44"/>'
    '<rect x="520" y="420" width="92" height="80" rx="12"/>'
    '<rect x="552" y="494" width="28" height="50"/>'
    '<circle cx="566" cy="575" r="34"/>'
)


def _svg(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        f'width="1024" height="1024">\n{body}</svg>\n'
    )


def ios_svg(v: dict[str, str]) -> str:
    return _svg(
        f'<rect width="1024" height="1024" fill="{v["bg"]}"/>\n'
        f'<circle cx="512" cy="512" r="372" fill="{v["glow"]}"/>\n'
        f'<circle cx="512" cy="512" r="352" fill="{v["disk"]}"/>\n'
        f'<circle cx="512" cy="512" r="345" fill="none" stroke="{v["rim"]}" '
        'stroke-width="14"/>\n'
        f'<path d="{COIL}" fill="none" stroke="{v["coil"]}" stroke-width="12"/>\n'
        f'<g fill="{v["chip"]}">{CHIP}</g>\n'
        f'<g fill="{v["disk"]}">{PADS}</g>\n'
        f'<path d="M562 597 Q577 611 572 628" fill="none" stroke="{v["chip"]}" '
        'stroke-width="8" stroke-linecap="round"/>\n'
    )


def small_svg() -> str:
    """Below 64 px: four thick rings, pads without dots, a thicker rim."""
    return _svg(
        '<rect width="1024" height="1024" fill="#EEF1F4"/>\n'
        '<circle cx="512" cy="512" r="352" fill="#FAFBFC"/>\n'
        '<circle cx="512" cy="512" r="342" fill="none" stroke="#6B7682" '
        'stroke-width="20"/>\n'
        f'<path d="{COIL_SMALL}" fill="none" stroke="#8C97A3" stroke-width="24"/>\n'
        f'<g fill="#FF7A1A">{CHIP_SMALL}</g>\n'
    )


def watch_svg() -> str:
    """A full square, as the system masks the circle; the mark is 10 %
    larger and the dots on the pads are left out."""
    return _svg(
        '<rect width="1024" height="1024" fill="#141416"/>\n'
        '<g transform="translate(512 512) scale(1.1) translate(-512 -512)">\n'
        '<circle cx="512" cy="512" r="352" fill="#1C1E21"/>\n'
        '<circle cx="512" cy="512" r="345" fill="none" stroke="#5E6873" '
        'stroke-width="14"/>\n'
        f'<path d="{COIL}" fill="none" stroke="#9AA5B1" stroke-width="13"/>\n'
        f'<g fill="#FF8A2B">{CHIP}</g>\n'
        '<path d="M562 597 Q577 611 572 628" fill="none" stroke="#FF8A2B" '
        'stroke-width="9" stroke-linecap="round"/>\n'
        "</g>\n"
    )


def svgs() -> dict[str, str]:
    out = {
        f"{SVG_DIR}/flibuddy-{name}.svg": ios_svg(v) for name, v in IOS_VARIANTS.items()
    }
    out[f"{SVG_DIR}/flibuddy-small.svg"] = small_svg()
    out[f"{SVG_DIR}/flibuddy-watch.svg"] = watch_svg()
    return out


def rasterise(svg: str, size: int = 1024) -> Image.Image:
    done = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "--format", "png"],
        input=svg.encode(),
        capture_output=True,
        check=True,
    )
    return Image.open(BytesIO(done.stdout))


def to_png(image: Image.Image, *, gray: bool = False) -> bytes:
    """RGB without alpha (the icons are opaque); `gray` forces r = g = b."""
    flat = Image.new("RGB", image.size, (0, 0, 0))
    flat.paste(image.convert("RGBA"), mask=image.convert("RGBA").getchannel("A"))
    if gray:
        flat = flat.convert("L").convert("RGB")
    out = BytesIO()
    flat.save(out, "PNG")
    return out.getvalue()


def flipper_png() -> bytes:
    image = Image.new("1", (10, 10), 1)
    for y, row in enumerate(APP):
        for x, ch in enumerate(row):
            if ch == "#":
                image.putpixel((x, y), 0)
    out = BytesIO()
    image.save(out, "PNG")
    return out.getvalue()


def build() -> dict[str, bytes]:
    files = svgs()
    out = {path: text.encode() for path, text in files.items()}
    for name, filename in [
        ("light", "AppIcon-Light.png"),
        ("dark", "AppIcon-Dark.png"),
        ("tinted", "AppIcon-Tinted.png"),
    ]:
        out[f"{IOS_SET}/{filename}"] = to_png(
            rasterise(files[f"{SVG_DIR}/flibuddy-{name}.svg"]), gray=name == "tinted"
        )
    out[f"{WATCH_SET}/AppIcon.png"] = to_png(
        rasterise(files[f"{SVG_DIR}/flibuddy-watch.svg"])
    )
    out[FLIPPER_ICON] = flipper_png()
    return out


if __name__ == "__main__":
    for relative, content in build().items():
        path = REPO / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        print(f"wrote {relative}")
