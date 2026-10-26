"""The bridge's protocol handler and line framer, against the message fixtures.

Bambuddy is replaced by a fake with the client's interface, so the handler's
replies can be compared with protocol/fixtures/messages byte for byte.
"""

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from bridge import bambu_tag, bambuddy, session
from fixtures import make_message_fixtures

PROTOCOL = Path(__file__).resolve().parents[2] / "protocol"
MESSAGES = PROTOCOL / "fixtures" / "messages"
SCHEMA = json.loads((PROTOCOL / "schema" / "message.schema.json").read_text())
VALIDATOR = Draft202012Validator(SCHEMA)

SPOOL_42 = {
    "id": 42,
    "material": "PLA",
    "subtype": "PLA Basic",
    "color_name": "Jade White",
    "rgba": "FFFFFFFF",
    "label_weight": 1000,
    "core_weight": 250,
    "weight_used": 516,
    "last_scale_weight": 734,
}


def load(name: str) -> dict:
    return json.loads((MESSAGES / name).read_text(encoding="utf-8"))


def line(message: dict) -> str:
    return json.dumps(message, separators=(",", ":"))


class FakeBambuddy:
    """Stands in for BambuddyClient; records calls."""

    def __init__(self, spools=None, fail=None):
        self.spools = {s["id"]: dict(s) for s in (spools or [])}
        self.fail = fail
        self.calls: list[tuple] = []

    def _maybe_fail(self):
        if self.fail:
            raise bambuddy.BambuddyError(self.fail)

    def find_by_tag(self, tray_uuid, uid):
        self.calls.append(("find_by_tag", tray_uuid, uid))
        self._maybe_fail()
        for spool in self.spools.values():
            if tray_uuid is not None and spool.get("tray_uuid") == tray_uuid:
                return spool
        for spool in self.spools.values():
            if spool.get("tag_uid") == uid:
                return spool
        return None

    def update_weight(self, spool_id, gross):
        self.calls.append(("update_weight", spool_id, gross))
        self._maybe_fail()
        spool = self.spools[spool_id]
        net = max(0, gross - spool["core_weight"])
        spool["weight_used"] = max(0, spool["label_weight"] - net)
        spool["last_scale_weight"] = gross
        return {"status": "ok", "weight_used": spool["weight_used"]}

    def create_spool(self, body):
        self.calls.append(("create_spool", body))
        self._maybe_fail()
        spool = {**body, "id": 100 + len(self.spools)}
        self.spools[spool["id"]] = spool
        return spool


def spool_42_on_tag(**extra) -> dict:
    tag = load("scan_mfc.json")["tag"]
    return {**SPOOL_42, "tray_uuid": bambu_tag.parse_tag(tag).tray_uuid, **extra}


def bridge(fake=None, **kwargs) -> session.Bridge:
    return session.Bridge(fake if fake is not None else FakeBambuddy(), **kwargs)


def replies(b: session.Bridge, message: dict) -> list[dict]:
    out = b.handle_line(line(message))
    for reply in out:
        assert len(reply.encode()) + 1 <= session.MAX_LINE_BYTES
        assert not list(VALIDATOR.iter_errors(json.loads(reply))), reply
    return [json.loads(reply) for reply in out]


# --- hello -------------------------------------------------------------------


def test_hello_is_valid():
    hello = bridge().hello()
    assert not list(VALIDATOR.iter_errors(hello))
    assert hello["app"].startswith("spoolbuddy-bridge/")
    assert "os" in hello and "fw" not in hello


class FakeClock:
    def __init__(self):
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


def test_an_unprompted_flipper_hello_is_answered_with_a_host_hello():
    b = bridge()
    (reply,) = replies(b, load("hello_flipper.json"))
    assert reply == b.hello()
    assert b.flipper == load("hello_flipper.json")


def test_a_flipper_hello_soon_after_ours_answers_it():
    clock = FakeClock()
    b = bridge(clock=clock)
    assert json.loads(b.greet()) == b.hello()
    clock.now += session.HELLO_TIMEOUT - 0.1
    assert replies(b, load("hello_flipper.json")) == []
    assert b.flipper == load("hello_flipper.json")


def test_a_late_flipper_hello_is_answered():
    clock = FakeClock()
    b = bridge(clock=clock)
    b.greet()
    clock.now += session.HELLO_TIMEOUT
    (reply,) = replies(b, load("hello_flipper.json"))
    assert reply == b.hello()


def test_hellos_never_ping_pong():
    """The Flipper answers a host hello sent while it is up with its own; the
    bridge must not answer that one again (PROTOCOL.md, Session)."""
    clock = FakeClock()
    b = bridge(clock=clock)
    clock.now += 10
    assert len(replies(b, load("hello_flipper.json"))) == 1
    clock.now += 0.05
    assert replies(b, load("hello_flipper.json")) == []


# --- scan -> lookup ------------------------------------------------------------


def test_scan_of_an_unknown_bambu_tag_yields_the_unknown_lookup():
    fake = FakeBambuddy()
    # The fixture was written with a 250 g core; the wire format does not depend on it.
    (reply,) = replies(bridge(fake, core_weight=250), load("scan_mfc.json"))
    assert reply == load("lookup_unknown.json")
    tag = load("scan_mfc.json")["tag"]
    tray_uuid = bambu_tag.parse_tag(tag).tray_uuid
    assert tray_uuid == tag["blocks"]["9"]
    assert fake.calls == [("find_by_tag", tray_uuid, "5A3C9E2100000100")]


def test_scan_of_a_known_spool_yields_the_found_lookup():
    (reply,) = replies(bridge(FakeBambuddy([spool_42_on_tag()])), load("scan_mfc.json"))
    assert reply == load("lookup_found.json")


def test_found_lookup_without_a_scale_weight_suggests_remaining_plus_core():
    fake = FakeBambuddy([spool_42_on_tag(last_scale_weight=None, color_name=None, weight_used=400)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["defaults"] == {"gross": 850, "label": 1000, "core": 250}
    assert reply["lines"][1] == "#FFFFFFFF"


def test_found_lookup_of_an_unused_unweighed_spool_suggests_label_plus_core():
    fake = FakeBambuddy([spool_42_on_tag(last_scale_weight=None, weight_used=0)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["defaults"]["gross"] == 1250


def test_found_lookup_clamps_defaults_to_the_schema_range():
    fake = FakeBambuddy([spool_42_on_tag(last_scale_weight=12345.6, label_weight=1000)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["defaults"]["gross"] == 9999


def test_found_lookup_truncates_long_names():
    fake = FakeBambuddy([spool_42_on_tag(color_name="X" * 60)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["lines"][1] == "X" * 40


def test_scan_of_an_ntag_is_unknown_without_prefill():
    (reply,) = replies(bridge(), load("scan_ntag.json"))
    assert reply["status"] == "unknown"
    assert "prefill" not in reply
    assert reply["lines"] == ["NTAG", "UID 04112233445566"]


def test_scan_of_an_ntag_is_looked_up_by_the_uid_as_read():
    fake = FakeBambuddy()
    replies(bridge(fake), load("scan_ntag.json"))
    assert fake.calls == [("find_by_tag", None, "04112233445566")]


def test_scan_of_an_unreadable_mfc_is_looked_up_by_uid():
    fake = FakeBambuddy()
    scan = load("scan_mfc_unreadable.json")
    (reply,) = replies(bridge(fake), scan)
    assert reply["status"] == "unknown"
    assert reply["scan_id"] == scan["scan_id"]
    assert "prefill" not in reply
    assert fake.calls == [("find_by_tag", None, scan["tag"]["uid"] + "00000100")]


def test_a_spool_added_by_an_ams_is_found_by_the_uid_alone():
    fake = FakeBambuddy([{**SPOOL_42, "tag_uid": "5A3C9E2100000100"}])
    (reply,) = replies(bridge(fake), load("scan_mfc_unreadable.json"))
    assert reply["status"] == "found"
    assert reply["spool_id"] == 42


def test_lookup_failure_yields_an_error_lookup():
    (reply,) = replies(bridge(FakeBambuddy(fail="connection refused")), load("scan_mfc.json"))
    assert reply["status"] == "error"
    assert reply["lines"] == ["Lookup failed"]
    assert "connection refused" in reply["error"]


def test_scan_without_bambuddy_yields_an_error_lookup():
    b = session.Bridge(None)
    (reply,) = replies(b, load("scan_mfc.json"))
    assert reply["status"] == "error"
    assert reply["lines"] == ["No Bambuddy configured"]


def test_scan_is_logged_with_the_parsed_tag():
    logged = []
    replies(bridge(log=logged.append), load("scan_mfc.json"))
    text = "\n".join(logged)
    assert "PLA Basic" in text
    assert "s-000012" in text


# --- intents -----------------------------------------------------------------


def test_weigh_gross_matches_the_result_fixture():
    fake = FakeBambuddy([spool_42_on_tag(weight_used=0)])
    (reply,) = replies(bridge(fake), load("intent_weigh.json"))
    assert reply == load("result_ok.json")
    assert fake.calls[-1] == ("update_weight", 42, 734)


def test_weigh_net_adds_the_core_weight():
    fake = FakeBambuddy([spool_42_on_tag(core_weight=216)])
    intent = {**load("intent_weigh.json"), "grams": 484, "mode": "net"}
    (reply,) = replies(bridge(fake), intent)
    assert reply["ok"] is True
    assert fake.calls[-1] == ("update_weight", 42, 700)


def test_weigh_net_with_a_zero_core():
    fake = FakeBambuddy([spool_42_on_tag(core_weight=0)])
    intent = {**load("intent_weigh.json"), "grams": 484, "mode": "net"}
    replies(bridge(fake), intent)
    assert fake.calls[-1] == ("update_weight", 42, 484)


def test_weigh_without_weight_used_in_the_response_computes_it():
    class NoUsed(FakeBambuddy):
        def update_weight(self, spool_id, gross):
            super().update_weight(spool_id, gross)
            return {"status": "ok"}

    fake = NoUsed([spool_42_on_tag(weight_used=0)])
    (reply,) = replies(bridge(fake), load("intent_weigh.json"))
    assert reply == load("result_ok.json")


def test_weigh_of_an_unknown_tag_fails():
    fake = FakeBambuddy()
    (reply,) = replies(bridge(fake), load("intent_weigh.json"))
    assert reply["ok"] is False
    assert reply["lines"] == ["Not saved", "Spool not found"]
    assert not [c for c in fake.calls if c[0] == "update_weight"]


def test_weigh_failure_is_reported():
    (reply,) = replies(bridge(FakeBambuddy(fail="HTTP 500")), load("intent_weigh.json"))
    assert reply["ok"] is False
    assert reply["lines"] == ["Not saved"]
    assert "HTTP 500" in reply["error"]


def test_repeated_intent_id_returns_the_cached_result():
    fake = FakeBambuddy([spool_42_on_tag(weight_used=0)])
    b = bridge(fake)
    first = replies(b, load("intent_weigh.json"))
    calls = len(fake.calls)
    second = replies(b, load("intent_weigh.json"))
    assert second == first
    assert len(fake.calls) == calls  # no second API call


def test_a_reused_intent_id_with_another_payload_is_performed_again():
    # A restarted Flipper may reuse an id the bridge still remembers.
    fake = FakeBambuddy([spool_42_on_tag(weight_used=0)])
    b = bridge(fake)
    replies(b, load("intent_weigh.json"))
    other = {**load("intent_weigh.json"), "grams": 500}
    (reply,) = replies(b, other)
    assert reply["ok"] is True
    assert fake.calls[-1] == ("update_weight", 42, 500)


def test_failed_intent_is_retried_on_repeat():
    fake = FakeBambuddy([spool_42_on_tag()], fail="timeout")
    b = bridge(fake)
    assert replies(b, load("intent_weigh.json"))[0]["ok"] is False
    fake.fail = None
    assert replies(b, load("intent_weigh.json"))[0]["ok"] is True


def test_new_creates_a_full_spool_from_the_tag():
    fake = FakeBambuddy()
    (reply,) = replies(bridge(fake, core_weight=250, catalog_id=7), load("intent_new.json"))
    assert reply["ok"] is True
    assert reply["lines"] == ["Created", "spool #100"]
    (_, body) = fake.calls[-1]
    tag = load("intent_new.json")["tag"]
    parsed = bambu_tag.parse_tag(tag)
    assert body == {
        "material": "PLA",
        "subtype": "PLA Basic",
        "color_name": "#FFFFFFFF",
        "rgba": "FFFFFFFF",
        "brand": "Bambu Lab",
        "label_weight": 1000,
        "core_weight": 250,
        "core_weight_catalog_id": 7,
        "weight_used": 0,
        "nozzle_temp_min": 190,
        "nozzle_temp_max": 230,
        "tag_uid": "5A3C9E2100000100",
        "tray_uuid": parsed.tray_uuid,
        "tag_type": "bambulab",
        "data_origin": "flipper",
    }


def test_unknown_lookup_defaults_to_a_325_g_core():
    (reply,) = replies(bridge(FakeBambuddy()), load("scan_mfc.json"))
    assert reply["defaults"]["core"] == 325


def test_new_defaults_to_a_325_g_core():
    fake = FakeBambuddy()
    replies(bridge(fake), load("intent_new.json"))
    (_, body) = fake.calls[-1]
    assert session.DEFAULT_CORE == 325
    assert body["core_weight"] == 325


def test_new_without_a_catalog_id_omits_it():
    fake = FakeBambuddy()
    replies(bridge(fake), load("intent_new.json"))
    (_, body) = fake.calls[-1]
    assert "core_weight_catalog_id" not in body


def test_new_falls_back_to_a_1000_g_label():
    tag = make_message_fixtures.mfc_tag(
        json.loads((PROTOCOL / "fixtures/tags/bambu_pla_basic_synthetic.json").read_text()),
        [1],
    )
    fake = FakeBambuddy()
    (reply,) = replies(bridge(fake), {**load("intent_new.json"), "tag": tag})
    assert reply["ok"] is True
    (_, body) = fake.calls[-1]
    assert body["label_weight"] == 1000
    assert "rgba" not in body and "subtype" not in body


def test_new_refuses_a_tag_without_material():
    fake = FakeBambuddy()
    intent = {**load("intent_new.json"), "tag": load("scan_ntag.json")["tag"]}
    (reply,) = replies(bridge(fake), intent)
    assert reply["ok"] is False
    assert reply["lines"] == ["Not created", "No material on tag"]
    assert not [c for c in fake.calls if c[0] == "create_spool"]


def test_new_refuses_a_tag_that_is_already_linked():
    fake = FakeBambuddy([spool_42_on_tag()])
    (reply,) = replies(bridge(fake), load("intent_new.json"))
    assert reply["ok"] is False
    assert reply["lines"] == ["Already in Bambuddy", "spool #42"]
    assert not [c for c in fake.calls if c[0] == "create_spool"]


@pytest.mark.parametrize("name", ["intent_create_on_host.json", "intent_link_on_host.json"])
def test_host_side_actions_are_only_flagged(name):
    fake = FakeBambuddy()
    logged = []
    (reply,) = replies(bridge(fake, log=logged.append), load(name))
    assert reply["ok"] is True
    assert reply["id"] == load(name)["id"]
    assert fake.calls == []
    assert any(load(name)["action"] in entry for entry in logged)


def test_intent_without_bambuddy_fails():
    (reply,) = replies(session.Bridge(None), load("intent_weigh.json"))
    assert reply["ok"] is False


# --- malformed input ---------------------------------------------------------


@pytest.mark.parametrize(
    "raw",
    [
        "not json",
        "[1,2]",
        line(load("invalid_missing_t.json")),
        line(load("invalid_bad_action.json")),
        line({**load("scan_mfc.json"), "v": 2}),
        line({"t": "telemetry", "v": 1}),
        line(load("lookup_found.json")),  # host-bound message from the wrong side
        "",
    ],
)
def test_malformed_or_foreign_lines_are_ignored(raw):
    fake = FakeBambuddy()
    assert bridge(fake).handle_line(raw) == []
    assert fake.calls == []


# --- dump dir ----------------------------------------------------------------


def test_dump_dir_saves_scans_as_tag_fixtures(tmp_path):
    scan = load("scan_mfc.json")
    replies(bridge(dump_dir=tmp_path), scan)
    (path,) = tmp_path.glob("*.json")
    assert path.name == "mfc_5A3C9E21_s-000012.json"
    dump = json.loads(path.read_text())
    assert dump["synthetic"] is False
    assert dump["type"] == "mfc" and dump["uid"] == "5A3C9E21"
    assert len(dump["blocks"]) == 64
    assert dump["missing"] == [7]
    assert bambu_tag.parse_tag(dump) == bambu_tag.parse_tag(scan["tag"])
    synthetic = json.loads((PROTOCOL / "fixtures/tags/bambu_pla_basic_synthetic.json").read_text())
    # read sectors and the rebuilt trailers match the source dump
    for i, block in enumerate(dump["blocks"]):
        if i // 4 != 7:
            assert block == synthetic["blocks"][i], i


def test_dump_dir_saves_ntag_pages(tmp_path):
    scan = load("scan_ntag.json")
    replies(bridge(dump_dir=tmp_path), scan)
    (path,) = tmp_path.glob("*.json")
    dump = json.loads(path.read_text())
    assert dump["pages"] == [scan["tag"]["pages"][str(i)] for i in range(len(dump["pages"]))]
    assert "blocks" not in dump


# --- framing -----------------------------------------------------------------


def test_framer_reassembles_partial_packets():
    framer = session.LineFramer()
    assert framer.feed(b'{"t":"hel') == []
    assert framer.feed(b'lo"}\r\n{"a"') == ['{"t":"hello"}']
    assert framer.feed(b":1}\n\n") == ['{"a":1}']


def test_framer_drops_over_long_lines():
    framer = session.LineFramer()
    long = b"x" * session.MAX_LINE_BYTES
    assert framer.feed(long[:5000]) == []
    assert framer.feed(long[5000:] + b"\nok\n") == ["ok"]


def test_framer_keeps_a_line_of_exactly_the_limit():
    framer = session.LineFramer()
    body = "y" * (session.MAX_LINE_BYTES - 1)
    assert framer.feed(body.encode() + b"\n") == [body]


def test_framer_replaces_invalid_utf8():
    assert session.LineFramer().feed(b"\xff\n") == ["�"]


# --- port discovery ----------------------------------------------------------


def test_find_flipper_port_picks_the_flipper():
    devices = ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.usbmodemflip_Anaram1", "/dev/cu.usbmodem1101"]
    assert session.find_flipper_port(devices) == "/dev/cu.usbmodemflip_Anaram1"


def test_find_flipper_port_returns_none_without_a_flipper():
    assert session.find_flipper_port(["/dev/cu.usbmodem1101"]) is None
