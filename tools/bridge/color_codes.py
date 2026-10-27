"""Bambu colour codes (`11803` for PLA Matte Caramel), which the tags do not
carry, from `tools/data/bambu_color_codes.json`; see
`fixtures/make_color_codes.py`."""

import json
from functools import cache
from pathlib import Path

DATA = Path(__file__).resolve().parents[1] / "data" / "bambu_color_codes.json"


@cache
def _rows() -> tuple[dict, ...]:
    return tuple(json.loads(DATA.read_text(encoding="utf-8")))


def find(filament_id: str | None, variant_id: str | None, rgba: str | None) -> dict | None:
    """The row for a tag: by filament id and the colour part of the variant
    id (`A01-N3` -> `N3`), else by filament id and colour; `None` if none."""
    if not filament_id:
        return None
    if variant_id and "-" in variant_id:
        color_id = variant_id.rsplit("-", 1)[1]
        for row in _rows():
            if row["filament_id"] == filament_id and row["color_id"] == color_id:
                return row
    if rgba and len(rgba) >= 6:
        rgb = rgba[:6].upper()
        for row in _rows():
            if row["filament_id"] == filament_id and row["rgb"] == rgb:
                return row
    return None


def for_tag(parsed) -> dict | None:
    return find(parsed.material_id, parsed.variant_id, parsed.rgba)
