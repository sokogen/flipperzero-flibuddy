"""Build a blank NTAG215 dump (135 pages, empty NDEF message).

Writes protocol/fixtures/tags/ntag215_blank.json. Pages 133-134 (PWD,
PACK) read back as zeros on a real tag, so they are zero here too. Run from
tools/: `uv run python -m fixtures.make_ntag_dump`.
"""

from fixtures import to_json, write

UID = bytes.fromhex("04112233445566")
SAK = 0x00
ATQA = bytes.fromhex("0044")
PAGES = 135
OUTPUT = "fixtures/tags/ntag215_blank.json"


def build_pages(uid: bytes = UID) -> list[bytes]:
    pages = [bytes(4)] * PAGES
    bcc0 = 0x88 ^ uid[0] ^ uid[1] ^ uid[2]
    bcc1 = uid[3] ^ uid[4] ^ uid[5] ^ uid[6]
    pages[0] = uid[:3] + bytes([bcc0])
    pages[1] = uid[3:]
    pages[2] = bytes([bcc1, 0x48, 0x00, 0x00])  # BCC1, internal, static lock
    pages[3] = bytes.fromhex("E1103E00")  # capability container, 496 bytes
    pages[4] = bytes.fromhex("0300FE00")  # empty NDEF TLV, terminator
    pages[130] = bytes.fromhex("000000BD")  # dynamic lock, RFUI
    pages[131] = bytes.fromhex("040000FF")  # CFG0: MIRROR, AUTH0 = FF
    pages[132] = bytes.fromhex("00050000")  # CFG1: ACCESS
    return pages


def build() -> dict[str, str]:
    dump = {
        "description": "Blank NTAG215 with an empty NDEF message.",
        "synthetic": True,
        "type": "ntag",
        "uid": UID.hex().upper(),
        "sak": SAK,
        "atqa": ATQA.hex().upper(),
        "pages": [p.hex().upper() for p in build_pages()],
    }
    return {OUTPUT: to_json(dump)}


if __name__ == "__main__":
    write(build())
