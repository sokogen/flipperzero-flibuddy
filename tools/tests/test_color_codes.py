from bridge import color_codes
from fixtures import make_color_codes
from fixtures.make_color_codes import REPO


def test_swift_table_is_current():
    for relative, content in make_color_codes.build().items():
        assert (REPO / relative).read_text(encoding="utf-8") == content, (
            f"{relative} is stale; regenerate with `uv run python -m fixtures.make_color_codes`"
        )


def test_caramel_by_variant_and_by_colour():
    assert color_codes.find("GFA01", "A01-N3", None)["code"] == "11803"
    row = color_codes.find("GFA01", None, "AE835BFF")
    assert (row["code"], row["name"]) == ("11803", "Caramel")


def test_unknown_or_missing_ids_find_nothing():
    assert color_codes.find(None, "A01-N3", "AE835BFF") is None
    assert color_codes.find("GFA01", "A01-ZZ", "123456FF") is None
    assert color_codes.find("XXXXX", "A01-N3", None) is None


def test_trim_keeps_complete_rows_only():
    source = {"data": [
        {"fila_id": "GFA01", "color_code": "N3", "fila_color_code": "11803",
         "fila_color_name": {"en": "Caramel", "de": "Karamell"}, "fila_color": ["#AE835BFF"]},
        {"fila_id": "GFA01", "color_code": "N4", "fila_color_code": "11804", "fila_color_name": {}},
    ]}
    assert make_color_codes.trim(source) == [
        {"filament_id": "GFA01", "color_id": "N3", "code": "11803", "name": "Caramel", "rgb": "AE835B"},
    ]


def c_rows(header: str) -> list[dict]:
    """The rows of the generated C table, unpacked as bambu_colors.c reads them."""
    import re

    filaments = re.findall(r'^    "(\w+)",$', header.split("bambu_color_filaments")[1].split("};")[0], re.MULTILINE)
    blob = header.split("bambu_color_names[] =")[1].split(";")[0]
    names = re.findall(r'"((?:[^"\\]|\\.)*)\\0"', blob)
    rows = []
    for m in re.finditer(
        r"\{(\d+), (\d+), \"(\w+)\", \{0x(\w\w), 0x(\w\w), 0x(\w\w)\}, \{0x(\w\w), 0x(\w\w), 0x(\w\w)\}\}",
        header.split("bambu_color_rows")[1],
    ):
        f, n, color, r, g, b, c0, c1, c2 = m.groups()
        rows.append({
            "filament_id": filaments[int(f)],
            "color_id": color,
            "code": str(int(c0, 16) | int(c1, 16) << 8 | int(c2, 16) << 16),
            "name": names[int(n)],
            "rgb": (r + g + b).upper(),
        })
    return rows


def test_the_flipper_gets_the_same_table_in_c():
    outputs = make_color_codes.build()
    assert set(outputs) == {make_color_codes.SWIFT, make_color_codes.C_HEADER}
    assert make_color_codes.C_HEADER == "flipper/src/bambu_color_table.h"
    header = outputs[make_color_codes.C_HEADER]
    assert c_rows(header) == make_color_codes.load()
    assert header.isascii()


def test_the_c_table_stays_small():
    # The FAP is loaded into RAM: names are stored once, a row is 12 bytes.
    rows = make_color_codes.load()
    names = {r["name"] for r in rows}
    assert len(names) < 256 and len({r["filament_id"] for r in rows}) < 256
    size = 12 * len(rows) + sum(len(n) + 1 for n in names) + 2 * len(names)
    assert size < 8 * 1024
