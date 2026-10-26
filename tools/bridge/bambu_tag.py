"""Parse a tag dump (the `tag` object of a `scan`) into spool facts.

Pure functions, no I/O. The Swift `TagParser` mirrors this module. The Bambu
block layout follows the public Bambu RFID tag guide; see
tools/fixtures/make_bambu_dump.py for the fields. The tray UUID is block 9 as
raw hex: Phase 0 matched it byte for byte with the `tray_uuid` an AMS reported
to Bambuddy. An all-zero block 9 means no tray UUID. Bambu tag UIDs go to
Bambuddy in the form an AMS writes, UID + "00000100" (`bambuddy_tag_uid`).
"""

import struct
from dataclasses import asdict, dataclass

MAX_LINES = 4
MAX_LINE_LEN = 40
AMS_TAG_UID_SUFFIX = "00000100"  # what an AMS writes after a Bambu tag's UID


@dataclass(frozen=True)
class ParsedTag:
    kind: str  # "bambu" (MIFARE Classic) or "ntag"
    uid: str
    tray_uuid: str | None = None  # block 9, 32 upper-case hex chars
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
    def bambuddy_tag_uid(self) -> str:
        """The `tag_uid` sent to Bambuddy: for Bambu tags the UID followed by
        `00000100`, the form an AMS reports, so that spools added by the AMS
        and by the Flipper match; NTAG UIDs as read. Upper-case hex."""
        uid = self.uid.upper()
        return uid + AMS_TAG_UID_SUFFIX if self.kind == "bambu" else uid

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


def _tray_uuid(blocks: dict[int, bytes]) -> str | None:
    """Block 9 as upper-case hex; None when missing or all zero."""
    block9 = blocks.get(9)
    return block9.hex().upper() if block9 and any(block9) else None


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
        tray_uuid=_tray_uuid(blocks),
        **fields,
    )
