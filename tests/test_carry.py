"""Per-domain freshness (v0.5 A5): a secondary endpoint that *raises* keeps
its last cached value instead of blanking its card. This is step 1 of the
v0.5 plan — the FAILED sentinel and the carry-forward for hrvStatus,
readiness and intensityMinutes. `activities` joins CARRY_KEYS in a later
step, once it exists.
"""
import fixtures
from conftest import load_helper
from test_helper import SLEEP, SUMMARY, _with_tokens, run
from test_payload_v2 import _all_endpoints, _fetch


def test_failed_call_is_the_failed_sentinel_not_none(home):
    mod = load_helper()
    assert mod._safe(lambda: 1 / 0) is mod.FAILED
    assert mod._safe(lambda: 42) == 42


def test_a_raised_hrv_call_carries_the_cached_value(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)                     # a good fetch to seed the cache
    fake_garmin.exc = {"get_hrv_data": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["hrvStatus"] == {"lastNightAvg": 58, "weeklyAvg": 44,
                                "status": "BALANCED"}
    assert out["carried"] == ["hrvStatus"]


def test_a_raised_readiness_and_intensity_both_carry(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.exc = {"get_training_readiness": RuntimeError("boom"),
                       "get_intensity_minutes_data": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["readiness"] == {"score": 54, "level": "MODERATE"}
    assert out["intensityMinutes"] == {"weekly": 21, "goal": 150}
    assert set(out["carried"]) == {"readiness", "intensityMinutes"}


def test_nothing_cached_still_marks_carried_with_a_null_value(home, fake_garmin, capsys):
    """No prior good fetch: the endpoint raised and there is nothing to
    substitute, but it's still recorded as carried (a fetch that once
    succeeds will fill it back in)."""
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_hrv_data": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["hrvStatus"] is None
    assert out["carried"] == ["hrvStatus"]


def test_an_empty_answer_is_not_a_failure_and_is_not_carried(home, fake_garmin, capsys):
    """readiness answering [] (not raising) is a real, current "nothing for
    today" — carrying yesterday's score over it would be a lie."""
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.readiness = []
    out = _fetch(load_helper(), capsys)
    assert out["readiness"] is None
    assert "readiness" not in out["carried"]


def test_carried_is_empty_on_a_clean_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert out["carried"] == []


def test_carried_is_not_accumulated_across_fetches(home, fake_garmin, capsys):
    """Each fetch recomputes `carried` from scratch — it never grows."""
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.exc = {"get_hrv_data": RuntimeError("boom")}
    _fetch(load_helper(), capsys)                     # carries hrvStatus
    fake_garmin.exc = {}
    out = _fetch(load_helper(), capsys)                # hrv recovers
    assert out["carried"] == []


def test_the_carried_payload_is_what_gets_written_to_cache(home, fake_garmin, capsys):
    """So the next failure carries the same value again."""
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.exc = {"get_hrv_data": RuntimeError("boom")}
    _fetch(load_helper(), capsys)
    fake_garmin.exc = {"get_hrv_data": RuntimeError("boom again")}
    out = _fetch(load_helper(), capsys)
    assert out["hrvStatus"] == {"lastNightAvg": 58, "weeklyAvg": 44,
                                "status": "BALANCED"}
    assert out["carried"] == ["hrvStatus"]


def test_load_cache_drops_a_planted_carried_key(home):
    mod = load_helper()
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(
        '{"ok": true, "stale": false, "carried": ["hrvStatus"]}')
    cached = mod._load_cache()
    assert "carried" not in cached


def test_stale_fetch_still_reports_an_empty_carried_list(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.login_exc = ConnectionError("boom")
    out = _fetch(load_helper(), capsys)
    assert out["stale"] is True
    assert out["carried"] == []
