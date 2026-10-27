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
