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
    "subtype": "Basic",
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

    def __init__(self, spools=None, fail=None, color_map=None, color_map_error=None, next_id=None, fail_on=()):
        self.spools = {s["id"]: dict(s) for s in (spools or [])}
        self.next_id = next_id
        self.fail = fail
        self.fail_on = set(fail_on)  # method names that fail with "HTTP 500"
        self.colors = color_map if color_map is not None else {"colors": {}, "by_material": {}}
        self.color_map_error = color_map_error
        self.calls: list[tuple] = []

    def _maybe_fail(self):
        if self.fail:
            raise bambuddy.BambuddyError(self.fail)
        if self.calls[-1][0] in self.fail_on:
            raise bambuddy.BambuddyError("HTTP 500")

    def _spool(self, spool_id):
        if spool_id not in self.spools:
            raise bambuddy.SpoolNotFound(spool_id)
        return self.spools[spool_id]

    def set_weight_used(self, spool_id, grams, locked):
        self.calls.append(("set_weight_used", spool_id, grams) + ((True,) if locked else ()))
        self._maybe_fail()
        spool = self._spool(spool_id)
        spool["weight_used"] = grams
        return dict(spool)

    def archive_spool(self, spool_id):
        self.calls.append(("archive_spool", spool_id))
        self._maybe_fail()
        self._spool(spool_id)["archived_at"] = "2026-10-26T10:00:00"

    def restore_spool(self, spool_id):
        self.calls.append(("restore_spool", spool_id))
        self._maybe_fail()
        self._spool(spool_id)["archived_at"] = None

    def delete_spool(self, spool_id):
        self.calls.append(("delete_spool", spool_id))
        self._maybe_fail()
        del self.spools[self._spool(spool_id)["id"]]

    def find_by_tag(self, tray_uuid, uid):
        self.calls.append(("find_by_tag", tray_uuid, uid))
        self._maybe_fail()
        for spool in self.spools.values():
            if tray_uuid is not None and spool.get("tray_uuid") == tray_uuid:
                return dict(spool)
        for spool in self.spools.values():
            if spool.get("tag_uid") == uid:
                return dict(spool)
        return None

    def update_weight(self, spool_id, gross):
        self.calls.append(("update_weight", spool_id, gross))
        self._maybe_fail()
        spool = self.spools[spool_id]
        net = max(0, gross - spool["core_weight"])
        spool["weight_used"] = max(0, spool["label_weight"] - net)
        spool["last_scale_weight"] = gross
        return {"status": "ok", "weight_used": spool["weight_used"]}

    def color_map(self):
        self.calls.append(("color_map",))
        if self.color_map_error:
            raise bambuddy.BambuddyError(self.color_map_error)
        return self.colors

    def create_spool(self, body):
        self.calls.append(("create_spool", body))
        self._maybe_fail()
        spool = {**body, "id": self.next_id or 100 + len(self.spools)}
        self.spools[spool["id"]] = spool
        return dict(spool)


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
    assert hello["v"] == 2
    assert hello["app"].startswith("flibuddy-bridge/")
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


JADE_WHITE = {"colors": {}, "by_material": {"pla basic|ffffff": "Jade White"}}


def named_bridge(fake, **kwargs) -> session.Bridge:
    """A bridge that has loaded a colour map naming the fixture's colour; the
    load is not one of the calls a test then checks."""
    b = bridge(fake, **kwargs)
    b.load_color_map()
    fake.calls.clear()
    return b


def test_unknown_lookup_without_colour_names_takes_bambus_name():
    (reply,) = replies(bridge(FakeBambuddy(), core_weight=250), load("scan_mfc.json"))
    assert reply["tag_info"]["color_name"] == "Jade White"
    assert reply["tag_info"]["code"] == "10100"
    assert reply["tag_info"]["filament_id"] == "GFA00"


def test_scan_of_an_unknown_bambu_tag_yields_the_unknown_lookup():
    fake = FakeBambuddy(color_map=JADE_WHITE)
    # The fixture was written with a 250 g core; the wire format does not depend on it.
    (reply,) = replies(named_bridge(fake, core_weight=250), load("scan_mfc.json"))
    assert reply == load("lookup_unknown.json")

    tag = load("scan_mfc.json")["tag"]
    tray_uuid = bambu_tag.parse_tag(tag).tray_uuid
    assert tray_uuid == tag["blocks"]["9"]
    assert fake.calls == [("find_by_tag", tray_uuid, "5A3C9E2100000100")]


def test_scan_of_a_known_spool_yields_the_found_lookup():
    (reply,) = replies(bridge(FakeBambuddy([spool_42_on_tag()])), load("scan_mfc.json"))
    assert reply == load("lookup_found.json")


def test_found_lookup_carries_the_spool_fields():
    fake = FakeBambuddy([spool_42_on_tag(color_name=None, rgba=None, subtype=None, weight_used=1200)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["spool"] == {"id": 42, "material": "PLA", "remaining": 0, "label": 1000, "core": 250}


def test_scan_of_a_blank_ntag_yields_the_blank_lookup():
    (reply,) = replies(bridge(FakeBambuddy(), core_weight=250), load("scan_ntag.json"))
    assert reply == load("lookup_unknown_blank.json")


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


def test_found_lookup_truncates_the_color_name_of_the_spool_object():
    fake = FakeBambuddy([spool_42_on_tag(color_name="X" * 60)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["spool"]["color_name"] == "X" * 40


@pytest.mark.parametrize("rgba", ["#FFFFFF", "ffffffff", "FFFFFF", "FFFFFFFFFF", "GGGGGGGG"])
def test_found_lookup_leaves_out_a_color_that_is_not_rrggbbaa_hex(rgba):
    fake = FakeBambuddy([spool_42_on_tag(rgba=rgba)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    expected = "FFFFFFFF" if rgba == "ffffffff" else None
    assert reply["spool"].get("rgba") == expected


def test_found_lookup_of_a_spool_without_material_has_no_spool_object():
    fake = FakeBambuddy([spool_42_on_tag(material=None)])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["t"] == "lookup"
    assert "spool" not in reply


def test_found_lines_show_the_full_type_for_a_subtype_without_the_material():
    (reply,) = replies(bridge(FakeBambuddy([spool_42_on_tag(subtype="Basic")])), load("scan_mfc.json"))
    assert reply["lines"][0] == "PLA Basic"
    (reply,) = replies(bridge(FakeBambuddy([spool_42_on_tag(subtype=None)])), load("scan_mfc.json"))
    assert reply["lines"][0] == "PLA"


def test_titles_join_material_and_subtype():
    assert session.title("PLA", "PLA Basic") == "PLA Basic"
    assert session.title("PETG", "HF") == "PETG HF"
    assert session.title("ABS", None) == "ABS"
    assert session.title("PLA", "pla matte") == "pla matte"
    assert session.title(None, "Basic") == "Basic"


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


def test_autosave_creates_an_unknown_tag_on_scan():
    fake = FakeBambuddy(color_map=COLOR_MAP, next_id=31)
    b = bridge(fake, core_weight=250)
    b.load_color_map()
    (reply,) = replies(b, load("scan_mfc_autosave.json"))
    assert reply == load("lookup_created.json")
    (_, body) = next(c for c in fake.calls if c[0] == "create_spool")
    assert body["material"] == "PLA" and body["weight_used"] == 0


def test_autosave_off_creates_nothing():
    fake = FakeBambuddy()
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply["status"] == "unknown"
    assert not [c for c in fake.calls if c[0] == "create_spool"]


def test_autosave_never_creates_a_tag_without_material():
    fake = FakeBambuddy()
    scan = {**load("scan_ntag.json"), "autosave": True}
    (reply,) = replies(bridge(fake), scan)
    assert reply["status"] == "unknown"
    assert not [c for c in fake.calls if c[0] == "create_spool"]


def test_a_rescan_of_a_tag_created_on_scan_creates_nothing():
    fake = FakeBambuddy()
    b = bridge(fake)
    replies(b, load("scan_mfc_autosave.json"))
    (reply,) = replies(b, load("scan_mfc_autosave.json"))
    assert reply["status"] == "found"
    assert "created" not in reply
    assert len([c for c in fake.calls if c[0] == "create_spool"]) == 1


def test_a_failed_create_on_scan_answers_unknown():
    fake = FakeBambuddy(fail_on={"create_spool"}, color_map=JADE_WHITE)
    logged = []
    (reply,) = replies(named_bridge(fake, core_weight=250, log=logged.append), load("scan_mfc_autosave.json"))
    assert reply == {**load("lookup_unknown.json"), "scan_id": "s-000015"}
    assert any("create on scan failed" in entry for entry in logged)


def test_scan_of_an_archived_spool_is_found_archived():
    fake = FakeBambuddy([spool_42_on_tag(weight_used=1000, last_scale_weight=None,
                                         archived_at="2026-10-26T10:00:00")])
    (reply,) = replies(bridge(fake), load("scan_mfc.json"))
    assert reply == load("lookup_found_archived.json")


# --- intents -----------------------------------------------------------------


def test_full_marks_the_spool_as_new():
    fake = FakeBambuddy([spool_42_on_tag()])
    (reply,) = replies(bridge(fake), load("intent_full.json"))
    assert reply == load("result_full.json")
    assert [c for c in fake.calls if c[0] != "find_by_tag"] == [("set_weight_used", 42, 0)]


def test_full_keeps_a_weight_lock():
    fake = FakeBambuddy([spool_42_on_tag(weight_locked=True)])
    replies(bridge(fake), load("intent_full.json"))
    assert ("set_weight_used", 42, 0, True) in fake.calls


def test_empty_keeps_a_weight_lock():
    fake = FakeBambuddy([spool_42_on_tag(weight_locked=True)])
    replies(bridge(fake), load("intent_empty.json"))
    assert ("set_weight_used", 42, 1000, True) in fake.calls


def test_full_restores_an_archived_spool_first():
    fake = FakeBambuddy([spool_42_on_tag(weight_used=1000, archived_at="2026-10-26T10:00:00")])
    (reply,) = replies(bridge(fake), load("intent_full.json"))
    assert reply == load("result_full.json")
    assert [c[0] for c in fake.calls] == ["find_by_tag", "restore_spool", "set_weight_used"]


def test_empty_marks_the_spool_as_used_up_and_archives_it():
    fake = FakeBambuddy([spool_42_on_tag()])
    (reply,) = replies(bridge(fake), load("intent_empty.json"))
    assert reply == load("result_empty.json")
    assert [c for c in fake.calls if c[0] != "find_by_tag"] == [
        ("set_weight_used", 42, 1000),
        ("archive_spool", 42),
    ]


def test_empty_on_an_archived_spool_skips_the_archive():
    fake = FakeBambuddy([spool_42_on_tag(archived_at="2026-10-26T10:00:00")])
    (reply,) = replies(bridge(fake), load("intent_empty.json"))
    assert reply == load("result_empty.json")
    assert [c[0] for c in fake.calls] == ["find_by_tag", "set_weight_used"]


def test_delete_deletes_the_spool():
    fake = FakeBambuddy([spool_42_on_tag()])
    (reply,) = replies(bridge(fake), load("intent_delete.json"))
    assert reply == load("result_delete.json")
    assert fake.calls[-1] == ("delete_spool", 42)
    assert fake.spools == {}


def test_delete_of_a_spool_already_gone_counts_as_deleted():
    class Gone(FakeBambuddy):
        def delete_spool(self, spool_id):
            self.calls.append(("delete_spool", spool_id))
            raise bambuddy.SpoolNotFound(spool_id)

    (reply,) = replies(bridge(Gone([spool_42_on_tag()])), load("intent_delete.json"))
    assert reply == load("result_delete.json")


@pytest.mark.parametrize(
    "name, failed",
    [("intent_full.json", "Not saved"), ("intent_empty.json", "Not saved"), ("intent_delete.json", "Not deleted")],
)
def test_marks_and_delete_need_a_linked_spool(name, failed):
    fake = FakeBambuddy()
    (reply,) = replies(bridge(fake), load(name))
    assert reply["ok"] is False
    assert reply["lines"] == [failed, "Spool not found"]
    assert [c[0] for c in fake.calls] == ["find_by_tag"]


@pytest.mark.parametrize(
    "name, method, failed",
    [
        ("intent_full.json", "set_weight_used", "Not saved"),
        ("intent_empty.json", "archive_spool", "Not saved"),
        ("intent_delete.json", "delete_spool", "Not deleted"),
    ],
)
def test_a_failed_mark_or_delete_is_reported_and_retried(name, method, failed):
    fake = FakeBambuddy([spool_42_on_tag()], fail_on={method})
    b = bridge(fake)
    (reply,) = replies(b, load(name))
    assert reply["ok"] is False
    assert reply["lines"] == [failed]
    assert "HTTP 500" in reply["error"]
    fake.fail_on.clear()
    assert replies(b, load(name))[0]["ok"] is True


def test_a_repeated_mark_returns_the_cached_result():
    fake = FakeBambuddy([spool_42_on_tag()])
    b = bridge(fake)
    first = replies(b, load("intent_empty.json"))
    calls = len(fake.calls)
    assert replies(b, load("intent_empty.json")) == first
    assert len(fake.calls) == calls


def test_weigh_gross_matches_the_result_fixture():
    fake = FakeBambuddy([spool_42_on_tag(weight_used=0)])
    (reply,) = replies(bridge(fake), load("intent_weigh.json"))
    assert reply == load("result_ok.json")
    assert fake.calls[-1] == ("update_weight", 42, 734)


def test_weigh_of_an_ams_added_spool_finds_it_by_the_ams_tag_uid():
    intent = load("intent_weigh.json")
    uid = intent["tag"]["uid"]
    fake = FakeBambuddy([{**SPOOL_42, "tag_uid": uid + "00000100"}])
    (reply,) = replies(bridge(fake), intent)
    assert reply["ok"] is True
    assert ("find_by_tag", bambu_tag.parse_tag(intent["tag"]).tray_uuid, uid + "00000100") in fake.calls
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


def test_weigh_of_an_unknown_tag_creates_the_spool_then_weighs_it():
    # "Add and weigh" on the Flipper with Auto-save new off.
    fake = FakeBambuddy(color_map=COLOR_MAP, next_id=42)
    b = bridge(fake, core_weight=250)
    b.load_color_map()
    (reply,) = replies(b, load("intent_weigh.json"))
    assert reply == load("result_ok.json")
    assert [c[0] for c in fake.calls] == ["color_map", "find_by_tag", "create_spool", "update_weight"]
    assert fake.calls[-1] == ("update_weight", 42, 734)


def test_weigh_of_an_unknown_tag_without_material_fails():
    fake = FakeBambuddy()
    intent = {**load("intent_weigh.json"), "tag": load("scan_ntag.json")["tag"]}
    (reply,) = replies(bridge(fake), intent)
    assert reply["ok"] is False
    assert reply["lines"] == ["Not saved", "Spool not found"]
    assert [c[0] for c in fake.calls] == ["find_by_tag"]


def test_a_weigh_retried_after_the_create_went_through_creates_no_second_spool():
    fake = FakeBambuddy(fail_on={"update_weight"})
    b = bridge(fake)
    (first,) = replies(b, load("intent_weigh.json"))
    assert first["ok"] is False
    assert first["lines"] == ["Not saved"]
    fake.fail_on.clear()
    (second,) = replies(b, load("intent_weigh.json"))
    assert second["ok"] is True
    assert len([c for c in fake.calls if c[0] == "create_spool"]) == 1
    assert len(fake.spools) == 1


def test_weigh_of_an_archived_spool_restores_it_first():
    fake = FakeBambuddy([spool_42_on_tag(weight_used=1000, archived_at="2026-10-26T10:00:00")])
    (reply,) = replies(bridge(fake), load("intent_weigh.json"))
    assert reply == load("result_ok.json")
    assert [c[0] for c in fake.calls] == ["find_by_tag", "restore_spool", "update_weight"]
    assert fake.spools[42]["archived_at"] is None


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
        "subtype": "Basic",
        "color_name": "Jade White",  # Bambu's name: the empty map names nothing
        "material_number": "10100",
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


COLOR_MAP = {"colors": {"ffffff": "White"}, "by_material": {"pla basic|ffffff": "Jade White"}}


def test_new_matches_the_result_fixture():
    fake = FakeBambuddy(color_map=COLOR_MAP, next_id=31)
    b = bridge(fake, core_weight=250)
    b.load_color_map()
    (reply,) = replies(b, load("intent_new.json"))
    assert reply == load("result_new.json")


def test_new_sends_the_name_from_the_colour_map():
    fake = FakeBambuddy(color_map=COLOR_MAP)
    b = bridge(fake)
    b.load_color_map()
    (reply,) = replies(b, load("intent_new.json"))
    assert reply["ok"] is True
    (_, body) = fake.calls[-1]
    assert body["color_name"] == "Jade White"


def test_new_names_a_colour_bambuddy_does_not_know_from_bambus_table():
    fake = FakeBambuddy(color_map=COLOR_MAP)
    b = bridge(fake)
    b.load_color_map()
    real = json.loads((PROTOCOL / "fixtures/tags/bambu_pla_pure_real.json").read_text())
    tag = make_message_fixtures.mfc_tag(real, real["missing"])
    (reply,) = replies(b, {**load("intent_new.json"), "tag": tag})
    assert reply["ok"] is True
    (_, body) = fake.calls[-1]
    assert body["rgba"] == "A4DBE8FF"
    # Bambuddy's map does not name it; Bambu's table does, with its code
    assert body["color_name"] == "Baby Blue"
    assert body["material_number"] == "17600"


def test_the_colour_map_is_loaded_once():
    fake = FakeBambuddy(color_map=COLOR_MAP)
    b = bridge(fake)
    b.load_color_map()
    replies(b, load("intent_new.json"))
    assert [c for c in fake.calls if c[0] == "color_map"] == [("color_map",)]


def test_a_failed_colour_map_is_logged_and_never_blocks_a_create():
    fake = FakeBambuddy(color_map=COLOR_MAP, color_map_error="HTTP 500 boom")
    logged = []
    b = bridge(fake, log=logged.append)
    b.load_color_map()
    assert any("colour names unavailable" in entry and "HTTP 500" in entry for entry in logged)
    (reply,) = replies(b, load("intent_new.json"))
    assert reply["ok"] is True
    (_, body) = fake.calls[-1]
    assert body["color_name"] == "Jade White"  # from Bambu's table


def test_loading_the_colour_map_without_bambuddy_does_nothing():
    b = session.Bridge(None)
    b.load_color_map()
    assert b.color_map is None


def test_unknown_lookup_defaults_to_a_242_g_core():
    (reply,) = replies(bridge(FakeBambuddy()), load("scan_mfc.json"))
    assert reply["defaults"]["core"] == 242


def test_new_defaults_to_a_242_g_core():
    fake = FakeBambuddy()
    replies(bridge(fake), load("intent_new.json"))
    (_, body) = fake.calls[-1]
    assert session.DEFAULT_CORE == 242
    assert body["core_weight"] == 242


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
        line({**load("scan_mfc.json"), "v": 1}),
        line({**load("hello_flipper.json"), "v": 1}),
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
