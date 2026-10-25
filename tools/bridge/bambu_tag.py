"""Parse a tag dump (the `tag` object of a `scan`) into spool facts.

Pure functions, no I/O. The Swift `TagParser` mirrors this module. The Bambu
block layout follows the public Bambu RFID tag guide; see
tools/fixtures/make_bambu_dump.py for the fields. The tray UUID location is
not settled yet (Phase 0), so the parser returns candidates in lookup order:

1. block 9 as raw hex (tag guide),
2. blocks 4+5 the way the SpoolBuddy daemon reads them (`_extract_tray_uuid`
   in maziggy/bambuddy `spoolbuddy/daemon/nfc_reader.py`): the first 32 hex
   characters of their ASCII text, else block 4 as raw hex.

All-zero values are skipped and duplicates collapsed.
"""

import struct
from dataclasses import asdict, dataclass, field

HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
ZERO_UUID = "0" * 32
MAX_LINES = 4
MAX_LINE_LEN = 40


@dataclass(frozen=True)
class ParsedTag:
    kind: str  # "bambu" (MIFARE Classic) or "ntag"
    uid: str
    tray_uuid_candidates: list[str] = field(default_factory=list)
    material: str | None = None
    detailed_type: str | None = None
    variant_id: str | None = None
    material_id: str | None = None
    rgba: str | None = None
    label_weight: int | None = None
    diameter: float | None = None
    drying_temp: int | None = None
    drying_hours: int | None = None
    bed_temp: int | None = None
    nozzle_max: int | None = None
    nozzle_min: int | None = None

    @property
    def has_prefill(self) -> bool:
        """Enough data to create a spool from the tag (needs `material`)."""
        return self.material is not None

    def display_lines(self) -> list[str]:
        """Up to four lines of at most 40 characters for `lookup.lines`."""
        if self.kind == "ntag":
            lines = ["NTAG", f"UID {self.uid}"]
        else:
            lines = [self.detailed_type or self.material or "Bambu tag"]
            if self.rgba:
                lines.append(f"#{self.rgba}")
            if self.label_weight:
                lines.append(f"label {self.label_weight} g")
            if len(lines) == 1:
                lines.append(f"UID {self.uid}")
        return [line[:MAX_LINE_LEN] for line in lines[:MAX_LINES]]

    def as_dict(self) -> dict:
        return {**asdict(self), "has_prefill": self.has_prefill}


def _blocks(tag: dict) -> dict[int, bytes]:
    """Block number -> bytes, from a `scan` object or a fixture block list."""
    raw = tag.get("blocks") or {}
    items = enumerate(raw) if isinstance(raw, list) else raw.items()
    missing = set(tag.get("missing") or [])
    return {
        int(number): bytes.fromhex(data)
        for number, data in items
        if int(number) // 4 not in missing
    }


def _ascii(data: bytes | None) -> str | None:
    """NUL-terminated printable ASCII, or None when empty or not text."""
    if data is None:
        return None
    text = data.split(b"\0", 1)[0]
    if not text or any(b < 0x20 or b > 0x7E for b in text):
        return None
    return text.decode("ascii").strip() or None


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _nonzero(value: int) -> int | None:
    return value or None


def _daemon_tray_uuid(block4: bytes, block5: bytes) -> str | None:
    raw = block4 + block5
    hex_chars = "".join(ch for ch in raw.decode("ascii", errors="ignore") if ch in HEX_DIGITS)
    if len(hex_chars) >= 32 and hex_chars[:32] != ZERO_UUID:
        return hex_chars[:32].upper()
    fallback = raw[:16].hex().upper()
    return fallback if fallback != ZERO_UUID else None


def _tray_uuid_candidates(blocks: dict[int, bytes]) -> list[str]:
    candidates = []
    if 9 in blocks:
        candidates.append(blocks[9].hex().upper())
    if 4 in blocks and 5 in blocks:
        candidates.append(_daemon_tray_uuid(blocks[4], blocks[5]))
    out: list[str] = []
    for candidate in candidates:
        if candidate and candidate != ZERO_UUID and candidate not in out:
            out.append(candidate)
    return out


def parse_tag(tag: dict) -> ParsedTag:
    uid = tag["uid"].upper()
    if tag["type"] == "ntag":
        return ParsedTag(kind="ntag", uid=uid)

    blocks = _blocks(tag)
    fields: dict = {}
    if 1 in blocks:
        fields["variant_id"] = _ascii(blocks[1][:8])
        fields["material_id"] = _ascii(blocks[1][8:])
    fields["material"] = _ascii(blocks.get(2))
    fields["detailed_type"] = _ascii(blocks.get(4))
    if 5 in blocks:
        block5 = blocks[5]
        fields["rgba"] = block5[:4].hex().upper()
        fields["label_weight"] = _nonzero(_u16(block5, 4))
        fields["diameter"] = struct.unpack_from("<f", block5, 8)[0] or None
    if 6 in blocks:
        drying_temp, drying_hours, _bed_type, bed_temp, nozzle_max, nozzle_min = (
            struct.unpack_from("<6H", blocks[6])
        )
        fields.update(
            drying_temp=_nonzero(drying_temp),
            drying_hours=_nonzero(drying_hours),
            bed_temp=_nonzero(bed_temp),
            nozzle_max=_nonzero(nozzle_max),
            nozzle_min=_nonzero(nozzle_min),
        )
    return ParsedTag(
        kind="bambu",
        uid=uid,
        tray_uuid_candidates=_tray_uuid_candidates(blocks),
        **fields,
    )
