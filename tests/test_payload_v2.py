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
    fake.activities = fixtures.ACTIVITIES


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
    # activities[0] (newest by startTimeGMT) is the "Morning Run" entry.
    last = out["lastActivity"]
    assert (last["id"], last["type"], last["name"]) == ("10000000001", "running", "Morning Run")
    assert (last["durationMin"], last["distanceKm"]) == (52, 8.41)
    assert last["date"] == fixtures.day(1)


# --- readiness: pick the newest scored reading, not readiness[0] ------------

def test_readiness_picks_newest_by_timestamp_older_first(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.readiness = [
        {"score": 40, "level": "LOW", "timestamp": "2026-08-21T06:00:00.0"},
        {"score": 75, "level": "HIGH", "timestamp": "2026-08-22T06:00:00.0"},
    ]
    out = _fetch(load_helper(), capsys)
    assert out["readiness"] == {"score": 75, "level": "HIGH"}


def test_readiness_picks_newest_by_timestamp_reversed_order(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.readiness = [
        {"score": 75, "level": "HIGH", "timestamp": "2026-08-22T06:00:00.0"},
        {"score": 40, "level": "LOW", "timestamp": "2026-08-21T06:00:00.0"},
    ]
    out = _fetch(load_helper(), capsys)
    assert out["readiness"] == {"score": 75, "level": "HIGH"}


def test_readiness_newest_with_null_score_falls_back_to_older_scored(home, fake_garmin, capsys):
    fake_garmin.readiness = [
        {"score": 40, "level": "LOW", "timestamp": "2026-08-21T06:00:00.0"},
        {"score": None, "level": None, "timestamp": "2026-08-22T06:00:00.0"},
    ]
    out = _fetch(load_helper(), capsys)
    assert out["readiness"] == {"score": 40, "level": "LOW"}


ACTIVITY_KEYS = {"id", "type", "name", "start", "date", "durationMin",
                 "distanceKm", "avgHr", "maxHr", "kcal", "elevM",
                 "paceSecPerKm", "speedKmh"}
FORBIDDEN_ACTIVITY_KEYS = {"startLatitude", "startLongitude", "endLatitude",
                           "endLongitude", "locationName", "ownerId",
                           "ownerDisplayName", "ownerFullName", "deviceId",
                           "timeZoneId", "hasPolyline", "splitSummaries",
                           "activityUUID", "activityId", "activityName",
                           "activityType", "startTimeLocal", "startTimeGMT"}


def test_last_activity_carries_no_coordinates_or_ids(home, fake_garmin, capsys):
    """v0.5 amendment 8: `id` is now expected (a decimal string); the
    coordinates, owner and device fields fixtures.ACTIVITIES also carries
    must still never reach the payload."""
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert set(out["lastActivity"]) == ACTIVITY_KEYS
    assert out["lastActivity"]["id"] == "10000000001"
    blob = json.dumps(out)
    for forbidden in FORBIDDEN_ACTIVITY_KEYS:
        assert forbidden not in blob, forbidden
    assert "Demo User" not in blob and "Nowhereville" not in blob


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
                "floors", "calories", "lastActivity"):
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
        "get_activities")}
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
    fake_garmin.activities = {"activityType": None, "duration": "x"}  # neither shape
    fake_garmin.body_battery = [{"bodyBatteryValuesArray": "nope"}]
    fake_garmin.stress = {"stressValuesArray": [None, [1], {}]}
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True
    assert out["hrvStatus"] is None and out["readiness"] is None
    assert out["intensityMinutes"] is None and out["curve"] is None
    assert out["activities"] == [] and out["lastActivity"] is None


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
    today = out["history"][-1]
    assert today["date"] == mod.datetime.date.today().isoformat()
    assert (today["sleepScore"], today["steps"], today["bbHigh"],
            today["restingHr"]) == (65, 8000, 90, 52)
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


def test_history_keeps_only_the_trailing_week_newest_last(home, fake_garmin, capsys):
    import datetime
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today()
    old = [{"date": (today - datetime.timedelta(days=b)).isoformat(),
            "sleepScore": 50, "steps": 1, "bodyBatteryHigh": 2, "restingHr": 3}
           for b in range(10, 0, -1)]
    mod.HISTORY_PATH.write_text(json.dumps(old))
    out = _fetch(mod, capsys)
    assert len(out["history"]) == 7
    assert [e["date"] for e in out["history"]] == sorted(
        e["date"] for e in out["history"])
    assert out["history"][0]["date"] == (today - datetime.timedelta(days=6)).isoformat()
    assert out["history"][-1]["date"] == today.isoformat()


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
