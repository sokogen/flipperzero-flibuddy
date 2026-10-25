"""Build the `scan` and `intent` sample messages from the tag dumps.

These messages embed a whole tag dump, so they are generated rather than
written by hand. Key order is the order the Flipper emits (see
protocol/PROTOCOL.md); the C encoder tests compare against these files.
Run from tools/ after the tag generators:
`uv run python -m fixtures.make_message_fixtures`.
"""

import json

from fixtures import PROTOCOL, make_bambu_dump, make_ntag_dump, to_json, write

MFC_SCAN_ID = "s-000012"
NTAG_SCAN_ID = "s-000013"
MISSING_SECTORS = [7]  # simulate one sector that failed authentication


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


def scan(scan_id: str, tag: dict) -> dict:
    return {"t": "scan", "v": 1, "scan_id": scan_id, "tag": tag}


def intent(intent_id: str, scan_id: str, action: str, tag: dict, **extra) -> dict:
    return {
        "t": "intent",
        "v": 1,
        "id": intent_id,
        "scan_id": scan_id,
        "action": action,
        **extra,
        "tag": tag,
    }


def build() -> dict[str, str]:
    mfc = mfc_tag(load_tag(make_bambu_dump.OUTPUT), MISSING_SECTORS)
    ntag = ntag_tag(load_tag(make_ntag_dump.OUTPUT))
    messages = {
        "scan_mfc": scan(MFC_SCAN_ID, mfc),
        "scan_ntag": scan(NTAG_SCAN_ID, ntag),
        "intent_weigh": intent(
            "i-000003", MFC_SCAN_ID, "weigh", mfc, grams=734, mode="gross"
        ),
        "intent_new": intent("i-000004", MFC_SCAN_ID, "new", mfc),
        "intent_create_on_host": intent(
            "i-000005", NTAG_SCAN_ID, "create_on_host", ntag
        ),
        "intent_link_on_host": intent("i-000006", NTAG_SCAN_ID, "link_on_host", ntag),
    }
    return {f"fixtures/messages/{name}.json": to_json(m) for name, m in messages.items()}


if __name__ == "__main__":
    write(build())
