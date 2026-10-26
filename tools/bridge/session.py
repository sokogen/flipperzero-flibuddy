"""Protocol handling for the bridge: framing, hello, scan -> lookup,
intent -> result. Transport-free, so tests feed lines and read replies.

See protocol/PROTOCOL.md. The Swift `Session` follows the same rules.
"""

import json
import platform
import re
import time
from collections.abc import Callable, Iterable
from datetime import UTC, datetime
from pathlib import Path

from jsonschema import Draft202012Validator

import bambu_keys
from bridge import APP, bambu_tag
from bridge.bambuddy import (
    BambuddyError,
    SpoolNotFound,
    color_name,
    is_archived,
    net_to_gross,
    remaining,
    used_after_weighing,
)

VERSION = 2  # protocol version; lines with any other `v` are ignored
MAX_LINE_BYTES = 8192  # including the terminating "\n"
HELLO_TIMEOUT = 2.0  # seconds; a Flipper hello within this of ours answers it
MAX_GRAMS = 9999
MAX_ERROR = 200
MAX_NAME = 40  # material, subtype and colour name in `spool` / `tag_info`
RGBA = re.compile(r"^[0-9A-F]{8}$")
DEFAULT_LABEL = 1000
DEFAULT_CORE = 325  # g: Bambu reusable spool 293 + refill core 32
BRAND = "Bambu Lab"
DATA_ORIGIN = "flipper"
TAG_TYPES = {"bambu": "bambulab", "ntag": "ntag"}
ACCESS_BITS = "87878769"  # Bambu trailers; the Flipper never sends trailers
# The first result line when an action fails.
FAILED = {
    "weigh": "Not saved",
    "new": "Not created",
    "full": "Not saved",
    "empty": "Not saved",
    "delete": "Not deleted",
}
SCHEMA_PATH = Path(__file__).resolve().parents[2] / "protocol" / "schema" / "message.schema.json"


def _validator() -> Draft202012Validator:
    return Draft202012Validator(json.loads(SCHEMA_PATH.read_text(encoding="utf-8")))


def compact(message: dict) -> str:
    return json.dumps(message, separators=(",", ":"), ensure_ascii=True)


def find_flipper_port(devices: Iterable[str]) -> str | None:
    """The first serial device that is a Flipper (`/dev/cu.usbmodemflip_*`)."""
    return next((d for d in devices if "usbmodemflip" in d), None)


def host_os() -> str:
    mac = platform.mac_ver()[0]
    name = f"macOS {mac}" if mac else f"{platform.system()} {platform.release()}"
    return name[:40]


def title(material: str | None, subtype: str | None) -> str | None:
    """Material and subtype for a `lookup` line: "PLA" + "Basic" -> "PLA Basic";
    a subtype that already starts with the material is shown as is."""
    if not subtype:
        return material
    if not material or subtype.lower().startswith(material.lower()):
        return subtype
    return f"{material} {subtype}"


def _grams(value) -> int:
    return max(0, min(MAX_GRAMS, round(value)))


def _lines(*lines: str | None) -> list[str]:
    return [line[: bambu_tag.MAX_LINE_LEN] for line in lines if line][: bambu_tag.MAX_LINES]


def _fields(**fields) -> dict:
    """The given fields without empty ones; names cut to the schema's length,
    a colour that is not RRGGBBAA hex left out."""
    out = {}
    for key, value in fields.items():
        if value is None or value == "":
            continue
        if key == "rgba":
            value = str(value).upper()
            if not RGBA.match(value):
                continue
        elif isinstance(value, str):
            value = value[:MAX_NAME]
        out[key] = value
    return out


def spool_fields(spool: dict) -> dict | None:
    """The `spool` object of a `lookup` or `result` for a Bambuddy spool, or
    None when the spool has no material to show."""
    if not spool.get("material"):
        return None
    label = spool.get("label_weight") or DEFAULT_LABEL
    return _fields(
        id=spool["id"],
        material=spool["material"],
        subtype=spool.get("subtype"),
        color_name=spool.get("color_name"),
        rgba=spool.get("rgba"),
        remaining=_grams(remaining({**spool, "label_weight": label})),
        label=_grams(label),
        core=_grams(spool.get("core_weight") or 0),
        archived=True if is_archived(spool) else None,
    )


def tag_info(parsed: bambu_tag.ParsedTag) -> dict:
    """The `tag_info` object of an `unknown` lookup: what the tag carries."""
    return _fields(
        material=parsed.material,
        subtype=parsed.bambuddy_subtype,
        rgba=parsed.rgba,
        label=_grams(parsed.label_weight) if parsed.label_weight is not None else None,
    )


class LineFramer:
    """Splits a byte stream into lines; drops a line longer than the limit."""

    def __init__(self, max_bytes: int = MAX_LINE_BYTES):
        self._max = max_bytes - 1  # the limit counts the "\n"
        self._buf = bytearray()
        self._dropping = False

    def feed(self, data: bytes) -> list[str]:
        out = []
        for byte in data:
            if byte == 0x0A:
                if not self._dropping and self._buf:
                    text = bytes(self._buf).removesuffix(b"\r").decode("utf-8", errors="replace")
                    if text:
                        out.append(text)
                self._buf.clear()
                self._dropping = False
            elif not self._dropping:
                self._buf.append(byte)
                if len(self._buf) > self._max:
                    self._buf.clear()
                    self._dropping = True
        return out


def dump_fixture(tag: dict, scan_id: str) -> dict:
    """A scanned tag in the protocol/fixtures/tags format.

    MIFARE Classic sector trailers are rebuilt from the derived Key A (the
    Flipper does not send them); blocks of missing sectors are zero-filled.
    """
    dump = {
        "description": f"Captured by the bridge from scan {scan_id} on "
        f"{datetime.now(UTC):%Y-%m-%d}.",
        "synthetic": False,
        "type": tag["type"],
        "uid": tag["uid"],
        "sak": tag["sak"],
        "atqa": tag["atqa"],
    }
    if tag["type"] == "ntag":
        dump["pages"] = [page for _, page in sorted(tag["pages"].items(), key=lambda kv: int(kv[0]))]
        return dump

    blocks = ["00" * 16] * 64
    for number, data in tag["blocks"].items():
        blocks[int(number)] = data
    uid = bytes.fromhex(tag["uid"])
    missing = tag.get("missing") or []
    if len(uid) == 4:
        dump["description"] += " Sector trailers rebuilt from the derived Key A."
        for sector, key_a in enumerate(bambu_keys.derive_keys(uid)):
            if sector not in missing:
                blocks[sector * 4 + 3] = key_a.hex().upper() + ACCESS_BITS + "00" * 6
    dump["blocks"] = blocks
    if missing:
        dump["missing"] = missing
    return dump


class Bridge:
    """Answers Flipper messages. `client` is a BambuddyClient or None."""

    def __init__(
        self,
        client,
        core_weight: int = DEFAULT_CORE,
        catalog_id: int | None = None,
        dump_dir: Path | None = None,
        log: Callable[[str], None] = lambda _: None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.client = client
        self.core_weight = core_weight
        self.catalog_id = catalog_id
        self.dump_dir = Path(dump_dir) if dump_dir else None
        self.log = log
        self.flipper: dict | None = None
        self.color_map: dict | None = None  # Bambuddy's colour names, see load_color_map
        self._clock = clock
        self._hello_sent_at: float | None = None
        self._results: dict[str, tuple[dict, dict]] = {}  # id -> (intent, result)
        self._validator = _validator()

    def load_color_map(self) -> None:
        """Load Bambuddy's colour names once, after the start-up check. A
        failure is logged and leaves new items without a colour name."""
        if self.client is None:
            return
        try:
            self.color_map = self.client.color_map()
        except BambuddyError as error:
            self.log(f"colour names unavailable: {error}")
            return
        self.log(f"colour names: {len(self.color_map['colors'])} colours, "
                 f"{len(self.color_map['by_material'])} by material")

    def hello(self) -> dict:
        return {"t": "hello", "v": VERSION, "app": APP, "os": host_os()}

    def greet(self) -> str:
        """Our hello line, sent when the port opens."""
        self._hello_sent_at = self._clock()
        return compact(self.hello())

    def handle_line(self, line: str) -> list[str]:
        try:
            message = json.loads(line)
        except ValueError:
            self.log(f"dropped non-JSON line: {line[:80]!r}")
            return []
        if not isinstance(message, dict) or message.get("v") != VERSION:
            return []
        if message.get("t") not in ("hello", "scan", "intent"):
            return []
        errors = list(self._validator.iter_errors(message))
        if errors:
            self.log(f"dropped malformed {message.get('t')}: {errors[0].message[:120]}")
            return []
        return [compact(reply) for reply in self.handle(message)]

    def handle(self, message: dict) -> list[dict]:
        match message["t"]:
            case "hello":
                self.flipper = message
                self.log(f"flipper hello: {message['app']} fw {message.get('fw')}")
                # Like the Flipper's host_link: a hello soon after ours answers
                # it; any other is answered, so the two never ping-pong.
                now = self._clock()
                if self._hello_sent_at is not None and now - self._hello_sent_at < HELLO_TIMEOUT:
                    return []
                self._hello_sent_at = now
                return [self.hello()]
            case "scan":
                return [self._scan(message)]
            case "intent":
                return [self._intent(message)]
        return []

    # --- scan ------------------------------------------------------------------

    def _scan(self, scan: dict) -> dict:
        tag = scan["tag"]
        parsed = bambu_tag.parse_tag(tag)
        self.log(f"scan {scan['scan_id']}: {json.dumps(parsed.as_dict())}")
        if self.dump_dir:
            self.dump_dir.mkdir(parents=True, exist_ok=True)
            path = self.dump_dir / f"{tag['type']}_{tag['uid']}_{scan['scan_id']}.json"
            path.write_text(json.dumps(dump_fixture(tag, scan["scan_id"]), indent=2) + "\n")
            self.log(f"saved {path}")
        lookup = self._lookup(scan["scan_id"], parsed, scan["autosave"])
        self.log(f"lookup {scan['scan_id']}: {compact(lookup)}")
        return lookup

    def _lookup(self, scan_id: str, parsed: bambu_tag.ParsedTag, autosave: bool) -> dict:
        base = {"t": "lookup", "v": VERSION, "scan_id": scan_id}
        if self.client is None:
            return {**base, "status": "error", "lines": ["No Bambuddy configured"],
                    "error": "bridge started without --bambuddy"}
        try:
            spool = self.client.find_by_tag(parsed.tray_uuid, parsed.bambuddy_tag_uid)
        except BambuddyError as error:
            return {**base, "status": "error", "lines": ["Lookup failed"],
                    "error": str(error)[:MAX_ERROR]}
        created = False
        if spool is None and autosave and parsed.has_prefill:
            spool = self._create_on_scan(scan_id, parsed)
            created = spool is not None
        if spool is None:
            lookup = {**base, "status": "unknown"}
            if parsed.has_prefill:
                lookup["prefill"] = True
            info = tag_info(parsed)
            if info:
                lookup["tag_info"] = info
            lookup["lines"] = parsed.display_lines()
            lookup["defaults"] = {
                "label": _grams(parsed.label_weight or DEFAULT_LABEL),
                "core": _grams(self.core_weight),
            }
            return lookup

        label = spool.get("label_weight") or DEFAULT_LABEL
        core = spool.get("core_weight") or 0
        # The last scale weight, or what the spool should weigh now.
        gross = spool.get("last_scale_weight")
        if gross is None:
            gross = remaining({**spool, "label_weight": label}) + core
        defaults = {"gross": _grams(gross), "label": _grams(label), "core": _grams(core)}
        color = spool.get("color_name") or (f"#{spool['rgba']}" if spool.get("rgba") else None)
        found = {**base, "status": "found", "spool_id": spool["id"]}
        fields = spool_fields(spool)
        if fields:
            found["spool"] = fields
        if created:
            found["created"] = True
        return {
            **found,
            "lines": _lines(
                title(spool.get("material"), spool.get("subtype")),
                color,
                "archived" if is_archived(spool) else f"{remaining(spool)} g left of {label}",
                f"core {core} g",
            ),
            "defaults": defaults,
        }

    def _create_on_scan(self, scan_id: str, parsed: bambu_tag.ParsedTag) -> dict | None:
        """Auto-save new: the tag's spool, created at once with the defaults.
        A failure is logged and the scan answered as unknown, so the Flipper
        keeps its own Add."""
        try:
            created = self.client.create_spool(self._new_spool(parsed))
        except BambuddyError as error:
            self.log(f"create on scan failed for {scan_id}: {error}")
            return None
        self.log(f"created on scan {scan_id}: spool #{created['id']}")
        return created

    # --- intent ----------------------------------------------------------------

    def _intent(self, intent: dict) -> dict:
        intent_id = intent["id"]
        # A repeat is the same intent again; a restarted Flipper may reuse an
        # id for another one, which is performed.
        cached = self._results.get(intent_id)
        if cached is not None and cached[0] == intent:
            self.log(f"intent {intent_id}: repeated, cached result")
            return cached[1]
        self.log(f"intent {intent_id}: {intent['action']} for scan {intent['scan_id']}")
        try:
            result = self._perform(intent)
        except BambuddyError as error:
            failed = FAILED.get(intent["action"], "Failed")
            result = self._result(intent_id, False, [failed], str(error))
        else:
            self._results[intent_id] = (intent, result)  # transient failures may be retried
        self.log(f"result {intent_id}: {compact(result)}")
        return result

    def _result(
        self,
        intent_id: str,
        ok: bool,
        lines: list[str],
        error: str | None = None,
        spool: dict | None = None,
    ) -> dict:
        result = {"t": "result", "v": VERSION, "id": intent_id, "ok": ok, "lines": _lines(*lines)}
        fields = spool_fields(spool) if ok and spool else None
        if fields:
            result["spool"] = fields
        if not ok:
            result["error"] = (error or "failed")[:MAX_ERROR]
        return result

    def _perform(self, intent: dict) -> dict:
        intent_id, action = intent["id"], intent["action"]
        if action in ("create_on_host", "link_on_host"):
            self.log(f"flagged {action} for UID {intent['tag']['uid']}; finish it in Bambuddy")
            return self._result(intent_id, True, ["Flagged on host"])
        if self.client is None:
            raise BambuddyError("bridge started without --bambuddy")

        parsed = bambu_tag.parse_tag(intent["tag"])
        if action == "new" and not parsed.has_prefill:
            return self._result(intent_id, False, ["Not created", "No material on tag"],
                                "tag carries no material")
        spool = self.client.find_by_tag(parsed.tray_uuid, parsed.bambuddy_tag_uid)

        if action == "weigh":
            # Looked up first every time: a retry after the create went
            # through and the weight did not weighs that spool.
            if spool is None:
                if not parsed.has_prefill:
                    return self._result(intent_id, False, ["Not saved", "Spool not found"],
                                        f"no spool for tag {parsed.uid}")
                spool = self.client.create_spool(self._new_spool(parsed))
                self.log(f"created for weight {intent['scan_id']}: spool #{spool['id']}")
            if is_archived(spool):
                spool = self._restore(spool)
            grams = intent["grams"]
            gross = grams if intent["mode"] == "gross" else net_to_gross(grams, spool.get("core_weight"))
            response = self.client.update_weight(spool["id"], gross)
            used = response.get("weight_used")
            if used is None:
                used = used_after_weighing(spool, gross)
            weighed = {**spool, "weight_used": used}
            return self._result(intent_id, True, ["Saved", f"{remaining(weighed)} g left"],
                                spool=weighed)

        if action in ("full", "empty", "delete"):
            if spool is None:
                return self._result(intent_id, False, [FAILED[action], "Spool not found"],
                                    f"no spool for tag {parsed.uid}")
            return self._mark(intent_id, action, spool)

        # action == "new"
        if spool is not None:
            return self._result(intent_id, False, ["Already in Bambuddy", f"spool #{spool['id']}"],
                                f"tag already linked to spool {spool['id']}")
        created = self.client.create_spool(self._new_spool(parsed))
        return self._result(intent_id, True, ["Created", f"spool #{created['id']}"], spool=created)

    def _restore(self, spool: dict) -> dict:
        self.client.restore_spool(spool["id"])
        return {**spool, "archived": False, "archived_at": None}

    def _mark(self, intent_id: str, action: str, spool: dict) -> dict:
        """Mark as new (restore if archived, nothing used), Mark as empty (all
        used, then archived) or Delete (a spool already gone counts)."""
        if action == "full":
            restored = self._restore(spool) if is_archived(spool) else spool
            marked = {**restored, **self.client.set_weight_used(spool["id"], 0)}
            if is_archived(spool):
                marked["archived"] = False
            return self._result(intent_id, True, ["Marked as new", f"{remaining(marked)} g left"],
                                spool=marked)
        if action == "empty":
            label = spool.get("label_weight") or DEFAULT_LABEL
            marked = {**spool, **self.client.set_weight_used(spool["id"], label)}
            if not is_archived(spool):
                self.client.archive_spool(spool["id"])
            marked["archived"] = True
            return self._result(intent_id, True, ["Marked as empty", "archived"], spool=marked)
        try:
            self.client.delete_spool(spool["id"])
        except SpoolNotFound:
            self.log(f"spool #{spool['id']} was gone already")
        return self._result(intent_id, True, ["Deleted", f"spool #{spool['id']}"])

    def _new_spool(self, parsed: bambu_tag.ParsedTag) -> dict:
        body = {
            "material": parsed.material,
            "subtype": parsed.bambuddy_subtype,
            "color_name": color_name(self.color_map, parsed.rgba, parsed.detailed_type),
            "rgba": parsed.rgba,
            "brand": BRAND if parsed.kind == "bambu" else None,
            "label_weight": parsed.label_weight or DEFAULT_LABEL,
            "core_weight": self.core_weight,
            "core_weight_catalog_id": self.catalog_id,
            "weight_used": 0,
            "nozzle_temp_min": parsed.nozzle_min,
            "nozzle_temp_max": parsed.nozzle_max,
            "tag_uid": parsed.bambuddy_tag_uid,
            "tray_uuid": parsed.tray_uuid,
            "tag_type": TAG_TYPES[parsed.kind],
            "data_origin": DATA_ORIGIN,
        }
        return {key: value for key, value in body.items() if value is not None}
