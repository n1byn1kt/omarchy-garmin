"""v0.2.0 payload extension: extra metrics, day curves, 7-day history."""
import json

import fixtures
from conftest import load_helper
from test_helper import SLEEP, SUMMARY, _with_tokens, run


def _all_endpoints(fake):
    fake.summary, fake.sleep = SUMMARY, SLEEP
    fake.body_battery = fixtures.BODY_BATTERY
    fake.stress = fixtures.STRESS
    fake.hrv = fixtures.HRV
    fake.readiness = fixtures.READINESS
    fake.intensity = fixtures.INTENSITY
    fake.last_activity = fixtures.LAST_ACTIVITY
    fake.weigh_ins = fixtures.WEIGH_INS


def _fetch(mod, capsys):
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert rc == 0
    return out


# --- extra scalar metrics ----------------------------------------------------

def test_extra_metrics_from_real_shapes(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True
    assert out["hrvStatus"] == {"lastNightAvg": 58, "weeklyAvg": 44,
                                "status": "BALANCED"}
    assert out["readiness"] == {"score": 54, "level": "MODERATE"}
    assert out["intensityMinutes"] == {"weekly": 21, "goal": 150}
    assert out["lastActivity"] == {"type": "hiking", "durationMin": 107,
                                   "distanceKm": 12.0, "date": "2026-01-15"}


def test_last_activity_carries_no_coordinates_or_ids(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.last_activity = dict(fixtures.LAST_ACTIVITY,
                                     startLatitude=12.34, startLongitude=-56.78,
                                     activityId=99999999999, ownerFullName="Someone")
    out = _fetch(load_helper(), capsys)
    assert set(out["lastActivity"]) == {"type", "durationMin", "distanceKm", "date"}
    blob = json.dumps(out)
    assert "12.34" not in blob and "ownerFullName" not in blob
    assert "99999999999" not in blob


def test_floors_and_calories_come_from_the_existing_summary(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.summary = dict(SUMMARY, floorsAscended=5.11844,
                               userFloorsAscendedGoal=10,
                               totalKilocalories=2096.0, activeKilocalories=299.0)
    out = _fetch(load_helper(), capsys)
    assert out["floors"] == {"count": 5, "goal": 10}
    assert out["calories"] == {"total": 2096, "active": 299}


def test_absent_metrics_are_null_not_missing(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP  # everything else None
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True
    for key in ("curve", "hrvStatus", "readiness", "intensityMinutes",
                "floors", "calories", "lastActivity", "weight"):
        assert key in out and out[key] is None, key
    # The v0.1 keys the shipped QML reads are untouched.
    assert out["bodyBattery"] == {"current": 61, "high": 90, "low": 30}
    assert out["steps"] == {"count": 8000, "goal": 10000}


# --- per-endpoint isolation --------------------------------------------------

def test_one_failing_endpoint_nulls_only_its_key(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_hrv_data": RuntimeError("500 for user@example.com")}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True and out["stale"] is False
    assert out["hrvStatus"] is None
    assert out["readiness"] == {"score": 54, "level": "MODERATE"}
    assert "user@example.com" not in json.dumps(out)


def test_every_secondary_endpoint_failing_still_yields_ok_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {name: RuntimeError("boom") for name in (
        "get_body_battery", "get_stress_data", "get_hrv_data",
        "get_training_readiness", "get_intensity_minutes_data",
        "get_last_activity", "get_weigh_ins")}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True and out["stale"] is False
    assert out["restingHr"] == 52
    assert out["curve"] is None and out["readiness"] is None


def test_primary_endpoint_failure_still_fails_the_fetch(home, fake_garmin, capsys):
    """Only the *new* calls are individually tolerated — a dead user summary
    must still fall back to the stale cache / error payload as before."""
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_user_summary": ConnectionError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is False and out["error"] == "offline"


def test_malformed_endpoint_payloads_do_not_crash(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.hrv = "not a dict"
    fake_garmin.readiness = []
    fake_garmin.intensity = [1, 2, 3]
    fake_garmin.last_activity = {"activityType": None, "duration": "x"}
    fake_garmin.body_battery = [{"bodyBatteryValuesArray": "nope"}]
    fake_garmin.stress = {"stressValuesArray": [None, [1], {}]}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True
    assert out["hrvStatus"] is None and out["readiness"] is None
    assert out["intensityMinutes"] is None and out["curve"] is None


# --- day curves --------------------------------------------------------------

def test_curve_series_are_downsampled_to_96_points(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    for name in ("bodyBattery", "stress"):
        series = out["curve"][name]
        assert 0 < len(series) <= 96, name
        assert all(isinstance(p, list) and len(p) == 2 for p in series), name
        # monotonic in time, and the last real sample survives downsampling
        assert [p[0] for p in series] == sorted(p[0] for p in series), name
    last_valid = [r for r in fixtures.STRESS["stressValuesArray"] if r[1] >= 0][-1]
    assert out["curve"]["stress"][-1] == last_valid


def test_curve_drops_no_reading_sentinels(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert all(p[1] >= 0 for p in out["curve"]["stress"])


def test_body_battery_curve_prefers_the_denser_source(home, fake_garmin, capsys):
    """get_body_battery returns ~6 marker points a day; the dense minute-level
    body battery series actually lives inside get_stress_data."""
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert len(out["curve"]["bodyBattery"]) > 6


def test_body_battery_curve_falls_back_when_stress_call_fails(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_stress_data": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["curve"]["stress"] is None
    assert out["curve"]["bodyBattery"] == fixtures.BODY_BATTERY[0][
        "bodyBatteryValuesArray"]


# --- 7-day history -----------------------------------------------------------

def test_history_records_today_and_is_returned_in_the_payload(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert out["history"][-1] == {
        "date": mod.datetime.date.today().isoformat(), "sleepScore": 65,
        "steps": 8000, "bodyBatteryHigh": 90, "restingHr": 52}
    on_disk = json.loads(mod.HISTORY_PATH.read_text())
    assert on_disk["days"] == out["history"]


def test_history_updates_todays_entry_in_place(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.summary = dict(SUMMARY, totalSteps=9500)
    out = _fetch(load_helper(), capsys)
    assert len(out["history"]) == 1
    assert out["history"][-1]["steps"] == 9500


def test_history_keeps_at_most_seven_days_newest_last(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    old = [{"date": f"2026-08-{d:02d}", "sleepScore": 50, "steps": 1,
            "bodyBatteryHigh": 2, "restingHr": 3} for d in range(1, 12)]
    mod.HISTORY_PATH.write_text(json.dumps(old))
    out = _fetch(mod, capsys)
    assert len(out["history"]) == 7
    assert [e["date"] for e in out["history"]] == sorted(
        e["date"] for e in out["history"])
    assert out["history"][-1]["date"] == mod.datetime.date.today().isoformat()


def test_corrupt_history_file_starts_fresh(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text("{ not json at all")
    out = _fetch(mod, capsys)
    assert out["ok"] is True
    assert len(out["history"]) == 1


def test_history_file_is_owner_only(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    assert oct(mod.HISTORY_PATH.stat().st_mode & 0o777) == "0o600"


def test_history_write_failure_is_nonfatal(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.mkdir()  # a directory where the file should go
    out = _fetch(mod, capsys)
    assert out["ok"] is True and out["stale"] is False


def test_history_survives_a_failed_fetch(home, fake_garmin, capsys):
    """A stale-cache fetch must not append a bogus entry for today."""
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    before = mod.HISTORY_PATH.read_text()
    fake_garmin.login_exc = ConnectionError("boom")
    out = _fetch(load_helper(), capsys)
    assert out["stale"] is True
    assert mod.HISTORY_PATH.read_text() == before


# --- weight timeline ---------------------------------------------------------

def test_weight_from_weigh_ins_summaries(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    w = out["weight"]
    assert w["current"] == 88.2
    assert w["date"] == "2026-08-24"
    assert w["startDate"] == "2026-08-08"
    assert w["delta"] == -0.7
    series = w["series"]
    assert [p[0] for p in series] == sorted(p[0] for p in series)
    assert series[0] == [1786140429008, 89.5]
    assert series[-1] == [1787567402007, 88.2]
    # Both samples on the 8th survive; this is a timeline of weigh-ins,
    # not a one-per-day rollup.
    assert len(series) == 8


def test_weight_carries_no_ids_or_owner_names(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert set(out["weight"]) == {
        "current", "date", "startDate", "delta", "series"}
    blob = json.dumps(out)
    assert "samplePk" not in blob
    assert "ownerFullName" not in blob
    assert "Someone" not in blob
    assert "99000" not in blob


def test_weight_falls_back_to_latest_weight_when_metrics_are_empty(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {
        "dailyWeightSummaries": [{
            "summaryDate": "2026-08-24",
            "allWeightMetrics": [],
            "latestWeight": fixtures._weigh("2026-08-24", 88199.0, 1787567402007),
        }]}
    out = _fetch(load_helper(), capsys)
    assert out["weight"]["current"] == 88.2
    assert out["weight"]["series"] == [[1787567402007, 88.2]]


def test_weight_non_list_summaries_null_the_card_not_the_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {"dailyWeightSummaries": 3}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True and out["weight"] is None


def test_weight_accepts_the_date_weight_list_envelope(home, fake_garmin, capsys):
    """get_body_composition uses a flat dateWeightList; both shapes parse."""
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = fixtures.WEIGH_INS_DATE_LIST
    out = _fetch(load_helper(), capsys)
    w = out["weight"]
    assert w["current"] == 88.2 and w["date"] == "2026-08-24"
    # dateWeightList is one row per day, so the extra morning sample is gone.
    assert len(w["series"]) == 7


def test_weight_already_in_kg_is_not_divided_again(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {
        "dateWeightList": [
            {"calendarDate": "2026-08-01", "weight": 88.2,
             "timestampGMT": 1786140429008},
            {"calendarDate": "2026-08-24", "weight": 87.4,
             "timestampGMT": 1787567402007},
        ]}
    out = _fetch(load_helper(), capsys)
    assert out["weight"]["current"] == 87.4
    assert out["weight"]["delta"] == -0.8


def test_weight_drops_non_positive_timestamps(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {
        "dateWeightList": [
            {"weight": 88000, "timestampGMT": 0},
            {"weight": 88000, "timestampGMT": -1},
            {"calendarDate": "2026-08-24", "weight": 88199.0,
             "timestampGMT": 1787567402007},
        ]}
    out = _fetch(load_helper(), capsys)
    assert out["weight"]["series"] == [[1787567402007, 88.2]]


def test_weight_drops_zero_negative_and_duplicate_samples(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    ts = 1787567402007
    fake_garmin.weigh_ins = {
        "dateWeightList": [
            {"calendarDate": "2026-08-20", "weight": 0, "timestampGMT": ts - 86400000},
            {"calendarDate": "2026-08-21", "weight": -100, "timestampGMT": ts - 1000},
            {"calendarDate": "2026-08-24", "weight": 88199.0, "timestampGMT": ts},
            {"calendarDate": "2026-08-24", "weight": 88199.0, "timestampGMT": ts},
        ]}
    out = _fetch(load_helper(), capsys)
    assert out["weight"]["series"] == [[ts, 88.2]]
    assert out["weight"]["delta"] is None


def test_weight_malformed_payload_nulls_the_card(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.weigh_ins = {"dailyWeightSummaries": "nope"}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True and out["weight"] is None


def test_weight_endpoint_failure_nulls_only_weight(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_weigh_ins": RuntimeError("500 for user@example.com")}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True and out["weight"] is None
    assert out["readiness"] == {"score": 54, "level": "MODERATE"}
    assert "user@example.com" not in json.dumps(out)


def test_weight_fetch_asks_for_thirty_days(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    weigh_calls = [c for c in fake_garmin.calls if c[0] == "get_weigh_ins"]
    assert len(weigh_calls) == 1
    start, end = weigh_calls[0][1]
    today = load_helper().datetime.date.today()
    assert end == today.isoformat()
    assert start == (today - load_helper().datetime.timedelta(days=29)).isoformat()
