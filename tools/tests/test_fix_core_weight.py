"""fix_core_weight: replaces an old empty-spool weight on Bambuddy spools."""

import io

import pytest

import fix_core_weight as fix
from bridge.bambuddy import BambuddyError


def spool(**fields):
    base = {
        "id": 1, "material": "PLA", "subtype": "Basic", "color_name": "Jade White",
        "label_weight": 1000, "core_weight": 325, "weight_used": 300.0,
        "weight_locked": False, "last_scale_weight": 1025, "archived_at": None,
    }
    return {**base, **fields}


def test_a_weighed_spool_gets_the_new_core_and_its_remaining_back():
    [change] = fix.plan([spool()], old=325, new=242)
    assert change.spool_id == 1
    assert change.fields == {"core_weight": 242, "weight_used": 217.0, "weight_locked": False}
    assert (change.remaining_before, change.remaining_after) == (700, 783)


def test_the_weight_lock_is_sent_as_it_was():
    [change] = fix.plan([spool(weight_locked=True)], old=325, new=242)
    assert change.fields["weight_locked"] is True


def test_a_spool_never_weighed_keeps_its_weight_used():
    [change] = fix.plan([spool(last_scale_weight=None, weight_used=120)], old=325, new=242)
    assert change.fields == {"core_weight": 242}
    assert change.remaining_before == change.remaining_after == 880
    assert "never weighed" in change.note


def test_an_archived_spool_keeps_its_weight_used():
    [change] = fix.plan([spool(archived_at="2026-10-01T10:00:00", weight_used=1000)], old=325, new=242)
    assert change.fields == {"core_weight": 242}
    assert change.remaining_after == 0
    assert "archived" in change.note


def test_an_empty_spool_keeps_its_weight_used():
    [change] = fix.plan([spool(weight_used=1000)], old=325, new=242)
    assert change.fields == {"core_weight": 242}
    assert "empty" in change.note


def test_weight_used_never_goes_below_zero():
    [change] = fix.plan([spool(weight_used=50)], old=325, new=242)
    assert change.fields["weight_used"] == 0
    assert change.remaining_after == 1000


def test_spools_with_another_core_are_left_alone():
    assert fix.plan([spool(core_weight=242), spool(id=2, core_weight=250)], old=325, new=242) == []


def test_changes_come_in_spool_id_order():
    changes = fix.plan([spool(id=9), spool(id=3)], old=325, new=242)
    assert [c.spool_id for c in changes] == [3, 9]


class FakeClient:
    def __init__(self, spools, fail_on=None):
        self.spools = spools
        self.fail_on = fail_on
        self.updates = []
        self.listed_archived = None

    def list_spools(self, include_archived=False):
        self.listed_archived = include_archived
        return self.spools

    def update_spool(self, spool_id, fields):
        if spool_id == self.fail_on:
            raise BambuddyError(f"PATCH /inventory/spools/{spool_id}: HTTP 500")
        self.updates.append((spool_id, fields))
        return {}


ENV = {"BAMBUDDY_URL": "https://bambuddy.test", "BAMBUDDY_API_KEY": "bb_testkey"}


def run(argv, client, env=ENV):
    out = io.StringIO()
    made = []

    def factory(url, key):
        made.append((url, key))
        return client

    code = fix.main(argv, env=env, client_factory=factory, out=out)
    return code, out.getvalue(), made


def test_a_dry_run_lists_the_changes_and_writes_nothing():
    client = FakeClient([spool(id=7), spool(id=8, core_weight=242)])
    code, text, made = run([], client)
    assert code == 0
    assert client.updates == []
    assert client.listed_archived is True
    assert made == [("https://bambuddy.test", "bb_testkey")]
    assert "#7" in text and "PLA Basic Jade White" in text and "700 -> 783 g" in text
    assert "#8" not in text
    assert "1 spool(s) with core 325 g" in text
    assert "dry run" in text


def test_the_key_never_reaches_the_output():
    _, text, _ = run([], FakeClient([spool()]))
    assert "bb_testkey" not in text


def test_apply_patches_every_listed_spool():
    client = FakeClient([spool(id=7), spool(id=8, last_scale_weight=None)])
    code, text, _ = run(["--apply"], client)
    assert code == 0
    assert client.updates == [
        (7, {"core_weight": 242, "weight_used": 217.0, "weight_locked": False}),
        (8, {"core_weight": 242}),
    ]
    assert "updated 2 spool(s)" in text


def test_apply_stops_at_the_first_failure():
    client = FakeClient([spool(id=7), spool(id=8), spool(id=9)], fail_on=8)
    code, text, _ = run(["--apply"], client)
    assert code == 1
    assert [spool_id for spool_id, _ in client.updates] == [7]
    assert "HTTP 500" in text and "updated 1 spool(s)" in text


def test_other_weights_can_be_given():
    client = FakeClient([spool(core_weight=250)])
    code, _, _ = run(["--old", "250", "--new", "240", "--apply"], client)
    assert code == 0
    assert client.updates == [(1, {"core_weight": 240, "weight_used": 290.0, "weight_locked": False})]


def test_nothing_to_change_says_so():
    code, text, _ = run(["--apply"], FakeClient([spool(core_weight=242)]))
    assert code == 0
    assert "no spools with core 325 g" in text


@pytest.mark.parametrize("missing", ["BAMBUDDY_URL", "BAMBUDDY_API_KEY"])
def test_missing_environment_is_an_error(missing):
    env = {k: v for k, v in ENV.items() if k != missing}
    code, text, made = run([], FakeClient([]), env=env)
    assert code == 2
    assert missing in text
    assert made == []


def test_a_failed_listing_is_an_error():
    class Broken(FakeClient):
        def list_spools(self, include_archived=False):
            raise BambuddyError("GET /inventory/spools: HTTP 403 forbidden")

    code, text, _ = run([], Broken([]))
    assert code == 1
    assert "HTTP 403" in text


def test_the_same_weights_are_refused():
    code, text, _ = run(["--old", "242", "--new", "242"], FakeClient([]))
    assert code == 2
    assert "differ" in text
