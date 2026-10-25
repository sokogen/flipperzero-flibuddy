"""Build a synthetic Bambu Lab MIFARE Classic 1K dump.

Writes protocol/fixtures/tags/bambu_pla_basic_synthetic.json, laid out per
the public Bambu RFID tag guide (Bambu-Research-Group/RFID-Tag-Guide):

  block 0   UID, BCC, SAK, ATQA, manufacturer data
  block 1   material variant id (8 ASCII) + material id (8 ASCII)
  block 2   filament type (ASCII)
  block 4   detailed filament type (ASCII)
  block 5   colour RGBA, label weight uint16 LE (g), diameter float32 LE (mm)
  block 6   drying temp, drying time, bed temp type, bed temp,
            max / min hotend temp (uint16 LE each)
  block 8   X cam info, nozzle diameter float32 LE at bytes 12-15
  block 9   tray UID (16 raw bytes)
  block 10  spool width uint16 LE (mm x 100) at bytes 4-5
  block 12  production date (ASCII)
  block 14  filament length uint16 LE (m) at bytes 4-5
  block 16  format id, colour count, second colour
  40..62    RSA signature (pseudo-random here)
  trailers  HKDF-derived Key A, access bits 87 87 87 69, Key B zero

Until Phase 0 captures a real dump, this file stands in for one and is
marked `synthetic: true`. Run from tools/: `uv run python -m fixtures.make_bambu_dump`.
"""

import hashlib
import struct

import bambu_keys
from fixtures import to_json, write

UID = bytes.fromhex("5A3C9E21")
SAK = 0x08
ATQA = bytes.fromhex("0400")
OUTPUT = "fixtures/tags/bambu_pla_basic_synthetic.json"

ACCESS_BITS = bytes.fromhex("87878769")
KEY_B = bytes(6)


def pseudo_random(label: str, length: int) -> bytes:
    """Deterministic filler bytes, stable across runs."""
    out = b""
    counter = 0
    while len(out) < length:
        out += hashlib.sha256(f"{label}/{counter}".encode()).digest()
        counter += 1
    return out[:length]


def ascii_block(*fields: tuple[str, int]) -> bytes:
    """Concatenate NUL-padded ASCII fields into one 16-byte block."""
    data = b"".join(text.encode("ascii").ljust(width, b"\0") for text, width in fields)
    assert len(data) == 16
    return data


def build_blocks(uid: bytes = UID) -> list[bytes]:
    blocks = [bytes(16)] * 64

    bcc = uid[0] ^ uid[1] ^ uid[2] ^ uid[3]
    blocks[0] = uid + bytes([bcc, SAK]) + ATQA + pseudo_random("manufacturer", 8)
    blocks[1] = ascii_block(("A00-W1", 8), ("GFA00", 8))
    blocks[2] = ascii_block(("PLA", 16))
    blocks[4] = ascii_block(("PLA Basic", 16))
    blocks[5] = (
        bytes.fromhex("FFFFFFFF")  # RGBA, Jade White
        + struct.pack("<H", 1000)  # label weight, g
        + bytes(2)
        + struct.pack("<f", 1.75)  # diameter, mm
        + bytes(4)
    )
    blocks[6] = struct.pack("<6H", 55, 8, 1, 35, 230, 190) + bytes(4)
    blocks[8] = pseudo_random("xcam", 12) + struct.pack("<f", 0.2)
    blocks[9] = pseudo_random("tray-uid", 16)
    blocks[10] = bytes(4) + struct.pack("<H", 6625) + bytes(10)
    blocks[12] = ascii_block(("2026_08_14_09_31", 16))
    blocks[13] = ascii_block(("26_08_14_09", 16))
    blocks[14] = bytes(4) + struct.pack("<H", 330) + bytes(10)
    blocks[16] = struct.pack("<HH", 2, 1) + bytes(12)

    for block in range(40, 63):
        if block % 4 != 3:
            blocks[block] = pseudo_random(f"signature/{block}", 16)

    for sector, key_a in enumerate(bambu_keys.derive_keys(uid)):
        blocks[sector * 4 + 3] = key_a + ACCESS_BITS + KEY_B

    assert all(len(b) == 16 for b in blocks)
    return blocks


def build() -> dict[str, str]:
    dump = {
        "description": "Synthetic Bambu Lab PLA Basic Jade White 1 kg tag "
        "built from the documented block layout; replace with a real dump "
        "after Phase 0.",
        "synthetic": True,
        "type": "mfc",
        "uid": UID.hex().upper(),
        "sak": SAK,
        "atqa": ATQA.hex().upper(),
        "blocks": [b.hex().upper() for b in build_blocks()],
    }
    return {OUTPUT: to_json(dump)}


if __name__ == "__main__":
    write(build())
