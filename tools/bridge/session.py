"""Protocol handling for the bridge: framing, hello, scan -> lookup,
intent -> result. Transport-free, so tests feed lines and read replies.

See protocol/PROTOCOL.md. The Swift `Session` follows the same rules.
"""

import json
import platform
from collections.abc import Callable, Iterable
from datetime import UTC, datetime
from pathlib import Path

from jsonschema import Draft202012Validator

import bambu_keys
from bridge import APP, bambu_tag
from bridge.bambuddy import BambuddyError, net_to_gross, remaining

MAX_LINE_BYTES = 8192  # including the terminating "\n"
MAX_GRAMS = 9999
MAX_ERROR = 200
DEFAULT_LABEL = 1000
DEFAULT_CORE = 250
BRAND = "Bambu Lab"
DATA_ORIGIN = "flipper"
TAG_TYPES = {"bambu": "bambulab", "ntag": "ntag"}
ACCESS_BITS = "87878769"  # Bambu trailers; the Flipper never sends trailers
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


def _grams(value) -> int:
    return max(0, min(MAX_GRAMS, round(value)))


def _lines(*lines: str | None) -> list[str]:
    return [line[: bambu_tag.MAX_LINE_LEN] for line in lines if line][: bambu_tag.MAX_LINES]


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
    ):
        self.client = client
        self.core_weight = core_weight
        self.catalog_id = catalog_id
        self.dump_dir = Path(dump_dir) if dump_dir else None
        self.log = log
        self.flipper: dict | None = None
        self._results: dict[str, dict] = {}
        self._validator = _validator()

    def hello(self) -> dict:
        return {"t": "hello", "v": 1, "app": APP, "os": host_os()}

    def handle_line(self, line: str) -> list[str]:
        try:
            message = json.loads(line)
        except ValueError:
            self.log(f"dropped non-JSON line: {line[:80]!r}")
            return []
        if not isinstance(message, dict) or message.get("v") != 1:
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
        lookup = self._lookup(scan["scan_id"], parsed)
        self.log(f"lookup {scan['scan_id']}: {compact(lookup)}")
        return lookup

    def _lookup(self, scan_id: str, parsed: bambu_tag.ParsedTag) -> dict:
        base = {"t": "lookup", "v": 1, "scan_id": scan_id}
        if self.client is None:
            return {**base, "status": "error", "lines": ["No Bambuddy configured"],
                    "error": "bridge started without --bambuddy"}
        try:
            spool = self.client.find_by_tag(parsed.tray_uuid_candidates, parsed.uid)
        except BambuddyError as error:
            return {**base, "status": "error", "lines": ["Lookup failed"],
                    "error": str(error)[:MAX_ERROR]}
        if spool is None:
            lookup = {**base, "status": "unknown"}
            if parsed.has_prefill:
                lookup["prefill"] = True
            lookup["lines"] = parsed.display_lines()
            lookup["defaults"] = {
                "label": _grams(parsed.label_weight or DEFAULT_LABEL),
                "core": _grams(self.core_weight),
            }
            return lookup

        label = spool.get("label_weight") or DEFAULT_LABEL
        core = spool.get("core_weight") or 0
        defaults = {}
        if spool.get("last_scale_weight") is not None:
            defaults["gross"] = _grams(spool["last_scale_weight"])
        defaults.update(label=_grams(label), core=_grams(core))
        color = spool.get("color_name") or (f"#{spool['rgba']}" if spool.get("rgba") else None)
        return {
            **base,
            "status": "found",
            "spool_id": spool["id"],
            "lines": _lines(
                spool.get("subtype") or spool.get("material"),
                color,
                f"{remaining(spool)} g left of {label}",
                f"core {core} g",
            ),
            "defaults": defaults,
        }

    # --- intent ----------------------------------------------------------------

    def _intent(self, intent: dict) -> dict:
        intent_id = intent["id"]
        if intent_id in self._results:
            self.log(f"intent {intent_id}: repeated, cached result")
            return self._results[intent_id]
        self.log(f"intent {intent_id}: {intent['action']} for scan {intent['scan_id']}")
        try:
            result = self._perform(intent)
        except BambuddyError as error:
            failed = {"weigh": "Not saved", "new": "Not created"}.get(intent["action"], "Failed")
            result = self._result(intent_id, False, [failed], str(error))
        else:
            self._results[intent_id] = result  # transient failures may be retried
        self.log(f"result {intent_id}: {compact(result)}")
        return result

    def _result(self, intent_id: str, ok: bool, lines: list[str], error: str | None = None) -> dict:
        result = {"t": "result", "v": 1, "id": intent_id, "ok": ok, "lines": _lines(*lines)}
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
        spool = self.client.find_by_tag(parsed.tray_uuid_candidates, parsed.uid)

        if action == "weigh":
            if spool is None:
                return self._result(intent_id, False, ["Not saved", "Spool not found"],
                                    f"no spool for tag {parsed.uid}")
            grams = intent["grams"]
            gross = grams if intent["mode"] == "gross" else net_to_gross(grams, spool.get("core_weight"))
            response = self.client.update_weight(spool["id"], gross)
            left = remaining({**spool, "weight_used": response.get("weight_used", 0)})
            return self._result(intent_id, True, ["Saved", f"{left} g left"])

        # action == "new"
        if spool is not None:
            return self._result(intent_id, False, ["Already in Bambuddy", f"spool #{spool['id']}"],
                                f"tag already linked to spool {spool['id']}")
        created = self.client.create_spool(self._new_spool(parsed))
        return self._result(intent_id, True, ["Created", f"spool #{created['id']}"])

    def _new_spool(self, parsed: bambu_tag.ParsedTag) -> dict:
        body = {
            "material": parsed.material,
            "subtype": parsed.detailed_type,
            "color_name": f"#{parsed.rgba}" if parsed.rgba else None,
            "rgba": parsed.rgba,
            "brand": BRAND if parsed.kind == "bambu" else None,
            "label_weight": parsed.label_weight or DEFAULT_LABEL,
            "core_weight": self.core_weight,
            "core_weight_catalog_id": self.catalog_id,
            "weight_used": 0,
            "nozzle_temp_min": parsed.nozzle_min,
            "nozzle_temp_max": parsed.nozzle_max,
            "tag_uid": parsed.uid,
            "tray_uuid": parsed.tray_uuid_candidates[0] if parsed.tray_uuid_candidates else None,
            "tag_type": TAG_TYPES[parsed.kind],
            "data_origin": DATA_ORIGIN,
        }
        return {key: value for key, value in body.items() if value is not None}
