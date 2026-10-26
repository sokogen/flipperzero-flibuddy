"""Build the `scan` and `intent` sample messages from the tag dumps, and
the `invalid_*` samples that must fail the schema.

These messages embed a whole tag dump, so they are generated rather than
written by hand. Key order is the order the Flipper emits (see
protocol/PROTOCOL.md); the C encoder tests compare against these files.
Run from tools/ after the tag generators:
`uv run python -m fixtures.make_message_fixtures`.
"""

import json

from fixtures import PROTOCOL, make_bambu_dump, make_ntag_dump, to_json, write

VERSION = 2
MFC_SCAN_ID = "s-000012"
NTAG_SCAN_ID = "s-000013"
UNREADABLE_SCAN_ID = "s-000014"
AUTOSAVE_SCAN_ID = "s-000015"  # the Bambu dump again, with Auto-save new on
MISSING_SECTORS = [7]  # simulate one sector that failed authentication
ALL_SECTORS = list(range(16))  # a MIFARE Classic the Bambu keys do not open


def load_tag(relative: str) -> dict:
    return json.loads((PROTOCOL / relative).read_text(encoding="utf-8"))


def mfc_tag(dump: dict, missing: list[int]) -> dict:
    blocks = {
        str(i): block
        for i, block in enumerate(dump["blocks"])
        if i % 4 != 3 and i // 4 not in missing  # trailers are never sent
    }
    tag = {
        "type": "mfc",
        "uid": dump["uid"],
        "sak": dump["sak"],
        "atqa": dump["atqa"],
        "blocks": blocks,
    }
    if missing:
        tag["missing"] = missing
    return tag


def ntag_tag(dump: dict) -> dict:
    return {
        "type": "ntag",
        "uid": dump["uid"],
        "sak": dump["sak"],
        "atqa": dump["atqa"],
        "pages": {str(i): page for i, page in enumerate(dump["pages"])},
    }


def scan(scan_id: str, tag: dict, autosave: bool = False) -> dict:
    return {"t": "scan", "v": VERSION, "scan_id": scan_id, "autosave": autosave, "tag": tag}


def intent(intent_id: str, scan_id: str, action: str, tag: dict, **extra) -> dict:
    return {
        "t": "intent",
        "v": VERSION,
        "id": intent_id,
        "scan_id": scan_id,
        "action": action,
        **extra,
        "tag": tag,
    }


def short_ntag() -> dict:
    """A two-page NTAG, enough for the invalid samples to fail on one field only."""
    return {
        "type": "ntag",
        "uid": "04112233445566",
        "sak": 0,
        "atqa": "0044",
        "pages": {"0": "041122BF", "1": "33445566"},
    }


def invalid_samples() -> dict[str, dict]:
    """Each fails the schema for one reason (tools/tests/test_fixtures.py)."""
    tag = short_ntag()
    no_autosave = scan("s-000016", tag)
    del no_autosave["autosave"]
    return {
        "invalid_bad_action": intent("i-000007", NTAG_SCAN_ID, "undo", tag),
        "invalid_scan_no_autosave": no_autosave,
        "invalid_weigh_no_grams": intent("i-000011", NTAG_SCAN_ID, "weigh", tag, mode="gross"),
    }


def build() -> dict[str, str]:
    mfc = mfc_tag(load_tag(make_bambu_dump.OUTPUT), MISSING_SECTORS)
    unreadable = mfc_tag(load_tag(make_bambu_dump.OUTPUT), ALL_SECTORS)
    ntag = ntag_tag(load_tag(make_ntag_dump.OUTPUT))
    messages = {
        "scan_mfc": scan(MFC_SCAN_ID, mfc),
        "scan_mfc_unreadable": scan(UNREADABLE_SCAN_ID, unreadable),
        "scan_ntag": scan(NTAG_SCAN_ID, ntag),
        "scan_mfc_autosave": scan(AUTOSAVE_SCAN_ID, mfc, autosave=True),
        "intent_weigh": intent(
            "i-000003", MFC_SCAN_ID, "weigh", mfc, grams=734, mode="gross"
        ),
        "intent_new": intent("i-000004", MFC_SCAN_ID, "new", mfc),
        "intent_full": intent("i-000008", MFC_SCAN_ID, "full", mfc),
        "intent_empty": intent("i-000009", MFC_SCAN_ID, "empty", mfc),
        "intent_delete": intent("i-000010", MFC_SCAN_ID, "delete", mfc),
        "intent_create_on_host": intent(
            "i-000005", NTAG_SCAN_ID, "create_on_host", ntag
        ),
        "intent_link_on_host": intent("i-000006", NTAG_SCAN_ID, "link_on_host", ntag),
        **invalid_samples(),
    }
    return {f"fixtures/messages/{name}.json": to_json(m) for name, m in messages.items()}


if __name__ == "__main__":
    write(build())
