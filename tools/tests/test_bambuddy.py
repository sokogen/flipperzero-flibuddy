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


def test_find_by_tag_tries_candidates_in_order_then_uid():
    c, rec = client(not_found(), not_found(), httpx.Response(200, json=SPOOL))
    assert c.find_by_tag(["AA" * 16, "BB" * 16], "5A3C9E21") == SPOOL
    assert [dict(r.url.params) for r in rec.requests] == [
        {"tray_uuid": "AA" * 16},
        {"tray_uuid": "BB" * 16},
        {"tag_uid": "5A3C9E21"},
    ]
    assert all(r.url.path == "/api/v1/inventory/spools/by-tag" for r in rec.requests)
    assert all(r.method == "GET" for r in rec.requests)


def test_find_by_tag_stops_at_the_first_match():
    c, rec = client(httpx.Response(200, json=SPOOL))
    assert c.find_by_tag(["AA" * 16, "BB" * 16], "5A3C9E21") == SPOOL
    assert len(rec.requests) == 1


def test_find_by_tag_returns_none_when_nothing_matches():
    c, rec = client(not_found())
    assert c.find_by_tag([], "04112233445566") is None
    assert dict(rec.requests[0].url.params) == {"tag_uid": "04112233445566"}


def test_find_by_tag_raises_on_server_error():
    c, _ = client(httpx.Response(500, text="boom"))
    with pytest.raises(bambuddy.BambuddyError, match="500"):
        c.find_by_tag([], "04112233445566")


def test_network_errors_become_bambuddy_errors():
    c, _ = client(httpx.ConnectError("connection refused"))
    with pytest.raises(bambuddy.BambuddyError, match="connection refused"):
        c.find_by_tag([], "04112233445566")


def test_every_request_sends_the_api_key():
    c, rec = client(
        not_found(),
        httpx.Response(200, json={"status": "ok", "weight_used": 516}),
        httpx.Response(200, json={"spoolman_enabled": "false"}),
        httpx.Response(200, json=SPOOL),
    )
    c.find_by_tag([], "5A3C9E21")
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
