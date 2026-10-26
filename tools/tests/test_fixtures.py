"""Contract checks for protocol/: the schema, sample messages and tag dumps.

Every file in protocol/fixtures/messages validates against the schema unless
its name starts with `invalid_`, in which case it must fail. Every tag dump
in protocol/fixtures/tags has a UID, a type, and 64 blocks or a page list.
Generated fixtures must match what their generator produces today.
"""

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

import bambu_keys
from fixtures import make_bambu_dump, make_message_fixtures, make_ntag_dump

PROTOCOL = Path(__file__).resolve().parents[2] / "protocol"
SCHEMA_PATH = PROTOCOL / "schema" / "message.schema.json"
MESSAGES = PROTOCOL / "fixtures" / "messages"
TAGS = PROTOCOL / "fixtures" / "tags"

MAX_LINE_BYTES = 8192  # including the terminating "\n"


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def compact_line(message) -> bytes:
    return (json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def message_files():
    return sorted(MESSAGES.glob("*.json"))


def tag_files():
    return sorted(TAGS.glob("*.json"))


@pytest.fixture(scope="module")
def validator():
    schema = load(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


# --- schema and messages -----------------------------------------------------


def test_fixture_directories_are_populated():
    assert len(message_files()) >= 12
    assert len(tag_files()) >= 2


def test_every_message_type_has_a_valid_example():
    kinds = {load(p).get("t") for p in message_files() if not p.name.startswith("invalid_")}
    assert kinds == {"hello", "scan", "lookup", "intent", "result"}


def test_every_intent_action_has_an_example():
    actions = {
        load(p)["action"]
        for p in message_files()
        if p.name.startswith("intent_")
    }
    assert actions == {"weigh", "new", "create_on_host", "link_on_host"}


@pytest.mark.parametrize("path", message_files(), ids=lambda p: p.name)
def test_message_matches_schema_as_named(path, validator):
    message = load(path)
    errors = list(validator.iter_errors(message))
    if path.name.startswith("invalid_"):
        assert errors, f"{path.name} should fail the schema"
    else:
        assert not errors, [e.message for e in errors]


@pytest.mark.parametrize("path", message_files(), ids=lambda p: p.name)
def test_message_fits_one_line(path):
    assert len(compact_line(load(path))) <= MAX_LINE_BYTES


def test_invalid_missing_t_fails_only_for_the_missing_t(validator):
    message = load(MESSAGES / "invalid_missing_t.json")
    assert "t" not in message
    assert validator.is_valid({"t": "result", **message})


def test_invalid_bad_action_fails_only_for_the_action(validator):
    message = load(MESSAGES / "invalid_bad_action.json")
    assert message["action"] not in {"weigh", "new", "create_on_host", "link_on_host"}
    assert validator.is_valid({**message, "action": "create_on_host"})


def scan_mfc():
    return load(MESSAGES / "scan_mfc.json")


@pytest.mark.parametrize(
    "mutate",
    [
        pytest.param(lambda m: m.update(v=2), id="wrong-version"),
        pytest.param(lambda m: m.update(extra=1), id="unknown-field"),
        pytest.param(lambda m: m["tag"].update(type="iso15693"), id="bad-tag-type"),
        pytest.param(lambda m: m["tag"].update(uid="04a1b2c3"), id="lower-case-uid"),
        pytest.param(lambda m: m["tag"]["blocks"].update({"64": "00" * 16}), id="block-64"),
        pytest.param(lambda m: m["tag"]["blocks"].update({"1": "00" * 15}), id="short-block"),
        pytest.param(lambda m: m["tag"].update(pages={"0": "04112233"}), id="mfc-with-pages"),
        pytest.param(lambda m: m["tag"].pop("blocks"), id="mfc-without-blocks"),
        pytest.param(lambda m: m["tag"].update(missing=[16]), id="sector-16"),
    ],
)
def test_schema_rejects_broken_scan(mutate, validator):
    message = scan_mfc()
    assert validator.is_valid(message)
    mutate(message)
    assert not validator.is_valid(message)


def test_schema_rejects_ntag_with_blocks(validator):
    message = load(MESSAGES / "scan_ntag.json")
    message["tag"]["blocks"] = {"0": "00" * 16}
    assert not validator.is_valid(message)


@pytest.mark.parametrize(
    "name, mutate",
    [
        ("intent_weigh.json", lambda m: m.pop("grams")),
        ("intent_weigh.json", lambda m: m.pop("mode")),
        ("intent_weigh.json", lambda m: m.update(mode="tare")),
        ("intent_weigh.json", lambda m: m.update(grams=-1)),
        ("lookup_found.json", lambda m: m.pop("spool_id")),
        ("lookup_found.json", lambda m: m.update(lines=["a", "b", "c", "d", "e"])),
        ("lookup_found.json", lambda m: m.update(lines=["x" * 41])),
        ("lookup_found.json", lambda m: m.update(status="maybe")),
        ("lookup_error.json", lambda m: m.pop("error")),
        ("result_error.json", lambda m: m.pop("error")),
        ("result_ok.json", lambda m: m.update(ok="yes")),
        ("hello_flipper.json", lambda m: m.pop("fw")),
    ],
)
def test_schema_rejects_broken_messages(name, mutate, validator):
    message = load(MESSAGES / name)
    assert validator.is_valid(message)
    mutate(message)
    assert not validator.is_valid(message)


def test_intents_repeat_the_tag_of_their_scan():
    scans = {m["scan_id"]: m["tag"] for m in map(load, MESSAGES.glob("scan_*.json"))}
    for path in MESSAGES.glob("intent_*.json"):
        intent = load(path)
        assert intent["tag"] == scans[intent["scan_id"]], path.name


# --- tag dumps -----------------------------------------------------------------


@pytest.mark.parametrize("path", tag_files(), ids=lambda p: p.name)
def test_tag_dump_shape(path):
    tag = load(path)
    assert tag["type"] in {"mfc", "ntag"}
    uid = bytes.fromhex(tag["uid"])
    assert len(uid) in (4, 7, 10)
    assert tag["uid"] == tag["uid"].upper()
    if tag["type"] == "mfc":
        assert len(tag["blocks"]) == 64
        assert all(len(bytes.fromhex(b)) == 16 for b in tag["blocks"])
        assert "pages" not in tag
    else:
        assert 1 <= len(tag["pages"]) <= 231
        assert all(len(bytes.fromhex(p)) == 4 for p in tag["pages"])
        assert "blocks" not in tag


def test_bambu_fixture_layout():
    tag = load(TAGS / "bambu_pla_basic_synthetic.json")
    assert tag["synthetic"] is True
    blocks = [bytes.fromhex(b) for b in tag["blocks"]]
    uid = bytes.fromhex(tag["uid"])

    # block 0: UID, BCC, SAK, ATQA
    assert blocks[0][:4] == uid
    assert blocks[0][4] == uid[0] ^ uid[1] ^ uid[2] ^ uid[3]
    assert blocks[0][5] == tag["sak"] == 0x08
    assert blocks[0][6:8].hex().upper() == tag["atqa"] == "0400"

    assert blocks[1][:8].rstrip(b"\0") == b"A00-W1"
    assert blocks[1][8:].rstrip(b"\0") == b"GFA00"
    assert blocks[2].rstrip(b"\0") == b"PLA"
    assert blocks[4].rstrip(b"\0") == b"PLA Basic"
    assert blocks[5][:4] == bytes.fromhex("FFFFFFFF")
    assert int.from_bytes(blocks[5][4:6], "little") == 1000
    assert len(blocks[9]) == 16 and blocks[9] != bytes(16)

    # every sector trailer carries the HKDF-derived Key A
    keys = bambu_keys.derive_keys(uid)
    for sector in range(16):
        assert blocks[sector * 4 + 3][:6] == keys[sector]


def test_ntag_fixture_layout():
    tag = load(TAGS / "ntag215_blank.json")
    pages = [bytes.fromhex(p) for p in tag["pages"]]
    uid = bytes.fromhex(tag["uid"])
    assert len(pages) == 135
    assert len(uid) == 7
    assert pages[0][:3] == uid[:3]
    assert pages[0][3] == 0x88 ^ uid[0] ^ uid[1] ^ uid[2]
    assert pages[1] == uid[3:]
    assert pages[2][0] == uid[3] ^ uid[4] ^ uid[5] ^ uid[6]
    assert pages[3] == bytes.fromhex("E1103E00")  # NTAG215 capability container


def test_bambu_keys_hkdf_rfc5869_case_1():
    ikm = bytes.fromhex("0b" * 22)
    salt = bytes.fromhex("000102030405060708090a0b0c")
    info = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
    okm = bambu_keys.hkdf_sha256(salt, ikm, info, 42)
    assert okm.hex() == (
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
        "34007208d5b887185865"
    )


def test_bambu_keys_shape():
    keys = bambu_keys.derive_keys(bytes.fromhex("5A3C9E21"))
    assert len(keys) == 16
    assert all(len(k) == 6 for k in keys)
    assert len(set(keys)) == 16
    with pytest.raises(ValueError):
        bambu_keys.derive_keys(bytes(7))


# --- generated fixtures are up to date -----------------------------------------


@pytest.mark.parametrize(
    "generator",
    [make_bambu_dump, make_ntag_dump, make_message_fixtures],
    ids=lambda g: g.__name__.rsplit(".", 1)[-1],
)
def test_generated_fixtures_are_current(generator):
    outputs = generator.build()
    assert outputs
    for relative, content in outputs.items():
        path = PROTOCOL / relative
        assert path.read_text(encoding="utf-8") == content, (
            f"{relative} is stale; regenerate with "
            f"`uv run python -m fixtures.{generator.__name__.rsplit('.', 1)[-1]}`"
        )


def test_scan_mfc_is_the_bambu_dump_with_sector_7_missing():
    dump = load(TAGS / "bambu_pla_basic_synthetic.json")
    tag = scan_mfc()["tag"]
    assert tag["uid"] == dump["uid"]
    assert tag["missing"] == [7]
    expected = {
        str(i): block
        for i, block in enumerate(dump["blocks"])
        if i % 4 != 3 and i // 4 != 7
    }
    assert tag["blocks"] == expected
    assert list(tag["blocks"]) == list(expected)  # ascending block order


def test_scan_mfc_unreadable_has_every_sector_missing_and_no_blocks():
    # A MIFARE Classic whose sectors do not open with the Bambu keys: the
    # host can still match it by UID.
    dump = load(TAGS / "bambu_pla_basic_synthetic.json")
    message = load(MESSAGES / "scan_mfc_unreadable.json")
    tag = message["tag"]
    assert tag["uid"] == dump["uid"]
    assert tag["blocks"] == {}
    assert tag["missing"] == list(range(16))
    assert message["scan_id"] == "s-000014"


def test_scan_ntag_carries_every_page():
    dump = load(TAGS / "ntag215_blank.json")
    tag = load(MESSAGES / "scan_ntag.json")["tag"]
    assert tag["uid"] == dump["uid"]
    assert tag["pages"] == {str(i): p for i, p in enumerate(dump["pages"])}


# --- PROTOCOL.md examples ---------------------------------------------------------


def protocol_examples():
    """Complete one-line examples from PROTOCOL.md (elided ones contain "…")."""
    text = (PROTOCOL / "PROTOCOL.md").read_text(encoding="utf-8")
    blocks = text.split("```json\n")[1:]
    lines = [line for block in blocks for line in block.split("```")[0].splitlines()]
    return [line for line in lines if line.strip() and "…" not in line]


def test_protocol_md_has_examples():
    assert len(protocol_examples()) >= 7


@pytest.mark.parametrize("line", protocol_examples())
def test_protocol_md_example_is_valid(line, validator):
    message = json.loads(line)
    assert not list(validator.iter_errors(message))
    assert message in [load(p) for p in message_files()], "example should mirror a fixture"
