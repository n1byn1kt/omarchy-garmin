"""v0.5 port of PR #1 (weight card, @xshatx).

Ported onto the current fetch layer rather than merged (the PR predates
_safe/FAILED, CARRY_KEYS, and the whitelist-rebuild-on-load discipline):
build_weight/_weight_unit/_rebuild_cached_weight are new here, weigh-ins are
fetched only when the `weight` token is in the effective panel deck (the
`--weight` CLI flag Service.qml passes, the same way it already gates the
`custom` card's command), and the synthetic WEIGH_INS fixture below is
entirely invented for this port — see docs/implementation-notes-v5.md.
"""
import json

import fixtures
from conftest import load_helper
from test_helper import SLEEP, SUMMARY, _with_tokens, run
from test_payload_v2 import _all_endpoints


def _fetch(mod, capsys, weight=False):
    _with_tokens(mod)
    argv = ["fetch", "--weight"] if weight else ["fetch"]
    rc, out = run(mod, argv, capsys)
    assert rc == 0
    return out


# --- build_weight -------------------------------------------------------------

def test_weight_from_weigh_ins_summaries(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    out = _fetch(load_helper(), capsys, weight=True)
    w = out["weight"]
    assert w["current"] == 72.4
    assert w["date"] == fixtures.day(0)
    assert w["startDate"] == fixtures.day(27)
    assert w["delta"] == -0.3
    assert w["unit"] == "kg"
    series = w["series"]
    assert [p[0] for p in series] == sorted(p[0] for p in series)
    # Both samples on the day() (20) survive; this is a timeline of
    # weigh-ins, not a one-per-day rollup.
    assert len(series) == 8


def test_weight_carries_no_ids_or_owner_names(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    out = _fetch(load_helper(), capsys, weight=True)
    assert set(out["weight"]) == {
        "current", "date", "startDate", "delta", "series", "unit"}
    blob = json.dumps(out)
    assert "samplePk" not in blob
    assert "ownerFullName" not in blob
    assert "Widget Tester" not in blob
    assert "1000000001" not in blob


def test_weight_falls_back_to_latest_weight_when_metrics_are_empty(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {
        "dailyWeightSummaries": [{
            "summaryDate": fixtures.day(0),
            "allWeightMetrics": [],
            "latestWeight": fixtures._weigh(0, 7, 72400.0),
        }]}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["current"] == 72.4
    assert len(out["weight"]["series"]) == 1


def test_weight_non_list_summaries_null_the_card_not_the_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {"dailyWeightSummaries": 3}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["ok"] is True and out["weight"] is None


def test_weight_accepts_the_date_weight_list_envelope(home, fake_garmin, capsys):
    """get_body_composition uses a flat dateWeightList; both shapes parse."""
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS_DATE_LIST
    out = _fetch(load_helper(), capsys, weight=True)
    w = out["weight"]
    assert w["current"] == 72.4 and w["date"] == fixtures.day(0)
    # dateWeightList is one row per day, so the extra morning sample is gone.
    assert len(w["series"]) == 7


def test_weight_already_in_kg_is_not_divided_again(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {
        "dateWeightList": [
            {"calendarDate": fixtures.day(10), "weight": 72.4, "timestampGMT": 1},
            {"calendarDate": fixtures.day(0), "weight": 71.6, "timestampGMT": 2},
        ]}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["current"] == 71.6
    assert out["weight"]["delta"] == -0.8


def test_weight_drops_non_positive_timestamps(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {
        "dateWeightList": [
            {"weight": 72000, "timestampGMT": 0},
            {"weight": 72000, "timestampGMT": -1},
            {"calendarDate": fixtures.day(0), "weight": 72400.0, "timestampGMT": 12345},
        ]}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["series"] == [[12345, 72.4]]


def test_weight_drops_zero_negative_and_duplicate_samples(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    ts = 1_800_000_000_000
    fake_garmin.weigh_ins = {
        "dateWeightList": [
            {"calendarDate": fixtures.day(2), "weight": 0, "timestampGMT": ts - 86400000},
            {"calendarDate": fixtures.day(1), "weight": -100, "timestampGMT": ts - 1000},
            {"calendarDate": fixtures.day(0), "weight": 72400.0, "timestampGMT": ts},
            {"calendarDate": fixtures.day(0), "weight": 72400.0, "timestampGMT": ts},
        ]}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["series"] == [[ts, 72.4]]
    assert out["weight"]["delta"] is None


def test_weight_malformed_payload_nulls_the_card(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {"dailyWeightSummaries": "nope"}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["ok"] is True and out["weight"] is None


def test_weight_endpoint_failure_nulls_only_weight(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_weigh_ins": RuntimeError("500 for user@example.com")}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["ok"] is True and out["weight"] is None
    assert out["readiness"] == {"score": 54, "level": "MODERATE"}
    assert "user@example.com" not in json.dumps(out)


def test_weight_fetch_asks_for_thirty_days(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    mod = load_helper()
    _fetch(mod, capsys, weight=True)
    calls = [c for c in fake_garmin.calls if c[0] == "get_weigh_ins"]
    assert len(calls) == 1
    start, end = calls[0][1]
    today = mod.datetime.date.today()
    assert end == today.isoformat()
    assert start == (today - mod.datetime.timedelta(days=29)).isoformat()


# --- fetch only when enabled ---------------------------------------------------

def test_weight_disabled_never_calls_get_weigh_ins(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    out = _fetch(load_helper(), capsys, weight=False)
    assert out["ok"] is True and out["weight"] is None
    assert not any(c[0] == "get_weigh_ins" for c in fake_garmin.calls)
    assert "carried" not in out or "weight" not in out["carried"]


def test_weight_enabled_calls_get_weigh_ins_once(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    out = _fetch(load_helper(), capsys, weight=True)
    calls = [c for c in fake_garmin.calls if c[0] == "get_weigh_ins"]
    assert len(calls) == 1
    assert out["weight"] is not None


def test_weight_disabled_call_budget_is_unchanged(home, fake_garmin, capsys):
    """Today-only budget stays at 8 calls when the card is off — the whole
    point of gating the fetch is that an unrelated user pays nothing."""
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)                                # first fetch of the day bursts
    fake_garmin.calls = []
    _fetch(load_helper(), capsys)
    assert len(fake_garmin.calls) == 8


def test_weight_enabled_call_budget_is_one_more(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    mod = load_helper()
    _fetch(mod, capsys, weight=True)                   # first fetch of the day bursts
    fake_garmin.calls = []
    _fetch(load_helper(), capsys, weight=True)
    assert len(fake_garmin.calls) == 9


# --- units follow Garmin's measurement system ---------------------------------

def test_weight_unit_defaults_to_kg(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    fake_garmin.unit_system = "metric"
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["unit"] == "kg"
    assert out["weight"]["current"] == 72.4


def test_weight_unit_converts_to_lb_for_statute(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    fake_garmin.unit_system = "statute"
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["unit"] == "lb"
    # 72.4 kg * 2.20462 = 159.6 lb (1 decimal)
    assert out["weight"]["current"] == 159.6


def test_weight_unit_falls_back_to_kg_when_unknown(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    fake_garmin.unit_system = None
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["unit"] == "kg"


def test_get_unit_system_raising_falls_back_to_kg(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    fake_garmin.exc = {"get_unit_system": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["weight"]["unit"] == "kg"


# --- weight in CARRY_KEYS ------------------------------------------------------

def test_get_weigh_ins_raising_carries_weight_from_cache(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    _fetch(load_helper(), capsys, weight=True)          # seed a good cache
    fake_garmin.exc = {"get_weigh_ins": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["carried"] == ["weight"]
    assert out["weight"]["current"] == 72.4


def test_nothing_cached_still_marks_weight_carried(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_weigh_ins": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys, weight=True)
    assert out["carried"] == ["weight"]
    assert out["weight"] is None


# --- whitelist-rebuild on cache load (amendment 4) -----------------------------

def test_cached_weight_is_rewhitelisted_on_load(home, fake_garmin, capsys):
    """A planted last.json cannot smuggle an extra field or an oversized
    series past the stale-cache-serving path (same discipline as
    activities, per amendment 4)."""
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    mod = load_helper()
    _fetch(mod, capsys, weight=True)

    planted = json.loads(mod.CACHE_PATH.read_text())
    planted["weight"]["ownerFullName"] = "Planted Name"
    planted["weight"]["series"] = [[i, 70.0 + (i % 5)] for i in range(10000)]
    mod.CACHE_PATH.write_text(json.dumps(planted))

    loaded = mod._load_cache()
    assert "ownerFullName" not in loaded["weight"]
    assert len(loaded["weight"]["series"]) <= mod.CURVE_POINTS
    assert set(loaded["weight"]) == {
        "current", "date", "startDate", "delta", "series", "unit"}


def test_load_cache_refuses_a_non_dict_weight(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    mod = load_helper()
    _fetch(mod, capsys, weight=True)
    planted = json.loads(mod.CACHE_PATH.read_text())
    planted["weight"] = "not a dict"
    mod.CACHE_PATH.write_text(json.dumps(planted))
    loaded = mod._load_cache()
    assert loaded["weight"] is None                    # Grok v0.5 QC #3
    for bad in (["a", "list"], 42, True):
        planted["weight"] = bad
        mod.CACHE_PATH.write_text(json.dumps(planted))
        assert mod._load_cache()["weight"] is None, bad


def test_a_stale_serve_without_the_flag_drops_the_cached_series(home, fake_garmin, capsys):
    """Grok v0.5 QC #3: the card was on (series cached), then turned off;
    an offline serve before any successful poll must not emit the old
    series — the missing `--weight` is the caller saying the card is gone."""
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS
    mod = load_helper()
    assert _fetch(mod, capsys, weight=True)["weight"]["series"]
    fake_garmin.exc = {"get_user_summary": ConnectionError("down")}
    out = _fetch(load_helper(), capsys)
    assert out["stale"] is True and out["weight"] is None
    fake_garmin.calls = []
    out = _fetch(load_helper(), capsys, weight=True)   # back on: still served
    assert out["stale"] is True and out["weight"]["series"]


# --- prefs ----------------------------------------------------------------------

def test_prefs_set_accepts_the_weight_token(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "panelMetrics", "curve,weight,rhr"], capsys)
    assert out["ok"] is True
    assert out["prefs"]["panelMetrics"] == ["curve", "weight", "rhr"]
