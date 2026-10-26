"""The bridge's Bambuddy client, against an httpx.MockTransport."""

import json

import httpx
import pytest

from bridge import bambuddy

BASE = "http://bambuddy.test:8000"
KEY = "bb_testkey"
SPOOL = {"id": 42, "material": "PLA", "label_weight": 1000, "core_weight": 250}


class Recorder:
    """Mock transport handler that records requests and replays responses."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def client(*responses) -> tuple[bambuddy.BambuddyClient, Recorder]:
    recorder = Recorder(*responses)
    return bambuddy.BambuddyClient(BASE, KEY, transport=httpx.MockTransport(recorder)), recorder


def not_found():
    return httpx.Response(404, json={"detail": "Spool not found"})


def test_find_by_tag_tries_the_tray_uuid_then_the_uid():
    c, rec = client(not_found(), httpx.Response(200, json=SPOOL))
    assert c.find_by_tag("AA" * 16, "5A3C9E21") == SPOOL
    assert [dict(r.url.params) for r in rec.requests] == [
        {"tray_uuid": "AA" * 16, "include_archived": "true"},
        {"tag_uid": "5A3C9E21", "include_archived": "true"},
    ]
    assert all(r.url.path == "/api/v1/inventory/spools/by-tag" for r in rec.requests)
    assert all(r.method == "GET" for r in rec.requests)


def test_find_by_tag_stops_at_the_tray_uuid_match():
    c, rec = client(httpx.Response(200, json=SPOOL))
    assert c.find_by_tag("AA" * 16, "5A3C9E21") == SPOOL
    assert len(rec.requests) == 1


def test_find_by_tag_returns_none_when_nothing_matches():
    c, rec = client(not_found())
    assert c.find_by_tag(None, "04112233445566") is None
    assert dict(rec.requests[0].url.params) == {"tag_uid": "04112233445566", "include_archived": "true"}


def test_find_by_tag_raises_on_server_error():
    c, _ = client(httpx.Response(500, text="boom"))
    with pytest.raises(bambuddy.BambuddyError, match="500"):
        c.find_by_tag(None, "04112233445566")


def test_network_errors_become_bambuddy_errors():
    c, _ = client(httpx.ConnectError("connection refused"))
    with pytest.raises(bambuddy.BambuddyError, match="connection refused"):
        c.find_by_tag(None, "04112233445566")


def test_every_request_sends_the_api_key():
    c, rec = client(
        not_found(),
        httpx.Response(200, json={"status": "ok", "weight_used": 516}),
        httpx.Response(200, json={"spoolman_enabled": "false"}),
        httpx.Response(200, json=SPOOL),
    )
    c.find_by_tag(None, "5A3C9E21")
    c.update_weight(42, 734)
    c.spoolman_enabled()
    c.create_spool({"material": "PLA"})
    assert [r.headers["X-API-Key"] for r in rec.requests] == [KEY] * 4


def test_update_weight_posts_gross():
    c, rec = client(httpx.Response(200, json={"status": "ok", "weight_used": 516}))
    assert c.update_weight(42, 734) == {"status": "ok", "weight_used": 516}
    request = rec.requests[0]
    assert request.method == "POST"
    assert request.url.path == "/api/v1/spoolbuddy/scale/update-spool-weight"
    assert json.loads(request.content) == {"spool_id": 42, "weight_grams": 734}


def test_update_weight_404_raises():
    c, _ = client(not_found())
    with pytest.raises(bambuddy.BambuddyError, match="404"):
        c.update_weight(42, 734)


def test_a_non_json_success_body_is_a_bambuddy_error():
    c, _ = client(httpx.Response(200, text="<html>proxy login</html>"))
    with pytest.raises(bambuddy.BambuddyError, match="not JSON"):
        c.get_spool(42)


def test_create_spool_posts_the_body():
    body = {"material": "PLA", "label_weight": 1000, "weight_used": 0}
    c, rec = client(httpx.Response(200, json={**SPOOL, "id": 43}))
    assert c.create_spool(body)["id"] == 43
    assert rec.requests[0].url.path == "/api/v1/inventory/spools"
    assert rec.requests[0].method == "POST"
    assert json.loads(rec.requests[0].content) == body


def test_create_spool_refuses_without_material():
    c, rec = client()
    with pytest.raises(ValueError):
        c.create_spool({"label_weight": 1000})
    with pytest.raises(ValueError):
        c.create_spool({"material": ""})
    assert rec.requests == []


def test_set_weight_used_patches_the_spool():
    c, rec = client(httpx.Response(200, json={**SPOOL, "weight_used": 0}))
    assert c.set_weight_used(42, 0)["weight_used"] == 0
    request = rec.requests[0]
    assert request.method == "PATCH"
    assert request.url.path == "/api/v1/inventory/spools/42"
    assert json.loads(request.content) == {"weight_used": 0}


@pytest.mark.parametrize("name", ["archive", "restore"])
def test_archive_and_restore_post_to_the_spool(name):
    c, rec = client(httpx.Response(200, json={**SPOOL}))
    getattr(c, f"{name}_spool")(42)
    assert rec.requests[0].method == "POST"
    assert rec.requests[0].url.path == f"/api/v1/inventory/spools/42/{name}"


def test_delete_spool_sends_delete():
    c, rec = client(httpx.Response(204))
    c.delete_spool(42)
    assert rec.requests[0].method == "DELETE"
    assert rec.requests[0].url.path == "/api/v1/inventory/spools/42"


@pytest.mark.parametrize(
    "call",
    [
        lambda c: c.set_weight_used(42, 0),
        lambda c: c.archive_spool(42),
        lambda c: c.restore_spool(42),
        lambda c: c.delete_spool(42),
    ],
)
def test_spool_writes_raise_spool_not_found_on_404(call):
    c, _ = client(not_found())
    with pytest.raises(bambuddy.SpoolNotFound) as error:
        call(c)
    assert error.value.spool_id == 42


def test_spool_writes_raise_on_server_error():
    c, _ = client(httpx.Response(500, text="boom"))
    with pytest.raises(bambuddy.BambuddyError, match="500"):
        c.delete_spool(42)


@pytest.mark.parametrize(
    "spool, expected",
    [
        ({}, False),
        ({"archived_at": None}, False),
        ({"archived_at": "2026-10-26T10:00:00"}, True),
        ({"archived_at": "2026-10-26T10:00:00", "archived": False}, False),
        ({"archived": True}, True),
    ],
)
def test_is_archived(spool, expected):
    assert bambuddy.is_archived(spool) is expected


def test_get_spool():
    c, rec = client(httpx.Response(200, json=SPOOL))
    assert c.get_spool(42) == SPOOL
    assert rec.requests[0].url.path == "/api/v1/inventory/spools/42"


@pytest.mark.parametrize(
    "value, expected",
    [("true", True), ("false", False), (True, True), (False, False), ("True", True)],
)
def test_spoolman_enabled(value, expected):
    c, rec = client(httpx.Response(200, json={"spoolman_enabled": value, "spoolman_url": ""}))
    assert c.spoolman_enabled() is expected
    assert rec.requests[0].url.path == "/api/v1/settings/spoolman"


def test_spoolman_enabled_names_the_missing_permission():
    c, _ = client(httpx.Response(403, json={"detail": "Forbidden"}))
    with pytest.raises(bambuddy.PermissionMissing) as error:
        c.spoolman_enabled()
    assert error.value.permission == "settings:read"
    assert "settings:read" in str(error.value)


def test_trailing_slash_in_base_url():
    recorder = Recorder(httpx.Response(200, json=SPOOL))
    c = bambuddy.BambuddyClient(BASE + "/", KEY, transport=httpx.MockTransport(recorder))
    c.get_spool(42)
    assert str(recorder.requests[0].url) == BASE + "/api/v1/inventory/spools/42"


@pytest.mark.parametrize(
    "net, core, gross",
    [(484, 250, 734), (0, 250, 250), (484, 0, 484), (500, 216, 716)],
)
def test_net_to_gross(net, core, gross):
    assert bambuddy.net_to_gross(net, core) == gross


def test_net_to_gross_treats_a_missing_core_as_zero():
    assert bambuddy.net_to_gross(484, None) == 484


@pytest.mark.parametrize(
    "spool, remaining",
    [
        ({"label_weight": 1000, "weight_used": 516}, 484),
        ({"label_weight": 1000, "weight_used": 1200}, 0),
        ({"label_weight": 1000}, 1000),
        ({"label_weight": 1000, "weight_used": 516.4}, 484),
    ],
)
def test_remaining(spool, remaining):
    assert bambuddy.remaining(spool) == remaining


# --- colour names -----------------------------------------------------------

COLOR_MAP = {
    "colors": {"ff9016": "Pumpkin Orange", "ffffff": "White"},
    "by_material": {"pla matte|ffffff": "Ivory White", "pla basic|ffffff": "Jade White"},
}


def test_color_map_reads_both_tables_with_lower_case_keys():
    reply = {"colors": {"FF9016": "Pumpkin Orange"}, "by_material": {"PLA Matte|FFFFFF": "Ivory White"}}
    c, rec = client(httpx.Response(200, json=reply))
    assert c.color_map() == {
        "colors": {"ff9016": "Pumpkin Orange"},
        "by_material": {"pla matte|ffffff": "Ivory White"},
    }
    assert rec.requests[0].method == "GET"
    assert rec.requests[0].url.path == "/api/v1/inventory/colors/map"


def test_color_map_without_tables_is_empty():
    c, _ = client(httpx.Response(200, json={}))
    assert c.color_map() == {"colors": {}, "by_material": {}}


@pytest.mark.parametrize("reply", [
    [],
    None,
    {"colors": ["ff9016"]},
    {"by_material": "none"},
    {"colors": {"ff9016": 7}},
])
def test_color_map_rejects_a_malformed_reply(reply):
    c, _ = client(httpx.Response(200, json=reply))
    with pytest.raises(bambuddy.BambuddyError):
        c.color_map()


def test_color_map_maps_403_to_inventory_read():
    c, _ = client(httpx.Response(403, json={"detail": "Missing permission"}))
    with pytest.raises(bambuddy.PermissionMissing) as error:
        c.color_map()
    assert error.value.permission == "inventory:read"


def test_color_map_reports_server_errors():
    c, _ = client(httpx.Response(500, text="boom"))
    with pytest.raises(bambuddy.BambuddyError, match="HTTP 500"):
        c.color_map()


@pytest.mark.parametrize(
    "rgba, detailed_type, name",
    [
        ("FFFFFFFF", "PLA Matte", "Ivory White"),  # the material table first
        ("FFFFFFFF", "PLA Basic", "Jade White"),
        ("FF9016FF", "PLA Basic", "Pumpkin Orange"),  # then the colour table
        ("FFFFFFFF", "PETG HF", "White"),
        ("FFFFFFFF", None, "White"),
        ("A4DBE8FF", "PLA Pure", None),  # the real PLA Pure spool: no name
        ("FF901600", None, "Pumpkin Orange"),  # alpha ignored
        ("FF9016", None, "Pumpkin Orange"),
        ("#FF9016FF", None, "Pumpkin Orange"),
        ("ff9016ff", None, "Pumpkin Orange"),  # case-insensitive
        ("fFfFfFfF", "pla MATTE", "Ivory White"),
        (None, "PLA Basic", None),
        ("FFF", None, None),
        ("GGGGGGFF", None, None),
    ],
)
def test_color_name(rgba, detailed_type, name):
    assert bambuddy.color_name(COLOR_MAP, rgba, detailed_type) == name


def test_color_name_without_a_map_is_none():
    assert bambuddy.color_name(None, "FF9016FF", "PLA Basic") is None
    assert bambuddy.color_name({}, "FF9016FF", "PLA Basic") is None
