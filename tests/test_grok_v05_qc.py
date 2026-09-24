"""Grok v0.5 QC fixes (grok-qc-v05.txt), helper side: #1 carried domains
stay out of history, #2 activityNames on every cache path, #6 the readiness
backfill's miss memo and deck gate, #8 lastActivity re-derived on load, #9
cycling speed from averageSpeed. #3/#4 live next to the tests they amend
(test_weight.py, test_demo.py); the QML halves of #3/#5/#6/#7 are in
test_grok_v05_qc_qml.py.
"""
import json

import fixtures
from conftest import load_helper
from fixtures import day
from test_helper import _with_tokens, run
from test_payload_v2 import _all_endpoints, _fetch
from test_window import _fetch_week, _on_disk, _row, _stock_week


def _plant_cache(mod, obj):
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(json.dumps(obj))


def _readiness_calls(fake):
    return [c for c in fake.calls if c[0] == "get_training_readiness"]


# --- #1: a carried value is not today's measurement ---------------------------

def test_yesterdays_carried_readiness_and_hrv_never_become_todays_history(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    # Yesterday's last good payload; no history row for today yet.
    _plant_cache(mod, {"ok": True,
                       "readiness": {"score": 80, "level": "HIGH"},
                       "hrvStatus": {"lastNightAvg": 61, "weeklyAvg": 50,
                                     "status": "BALANCED"}})
    fake_garmin.exc = {"get_training_readiness": RuntimeError("boom"),
                       "get_hrv_data": RuntimeError("boom")}
    out = _fetch(mod, capsys)
    assert out["readiness"]["score"] == 80              # the card still shows it
    assert {"readiness", "hrvStatus"} <= set(out["carried"])
    today = _row(out, 0)
    assert today["readiness"] is None                    # left for a later burst
    assert today["hrvNight"] is None and today["hrvWeekly"] is None
    disk = [r for r in _on_disk(mod)["days"] if r["date"] == day(0)][0]
    assert disk["readiness"] is None


def test_a_same_day_carry_keeps_the_real_number_already_in_history(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)                        # real 54 recorded today
    fake_garmin.exc = {"get_training_readiness": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert "readiness" in out["carried"]
    assert _row(out, 0)["readiness"] == 54


# --- #2: activityNames off applies to cache load, carry and stale serve -------

def _names_on_then_off(fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    first = _fetch(mod, capsys)
    assert any(a["name"] for a in first["activities"])  # names cached
    run(load_helper(), ["prefs", "set", "activityNames", "false"], capsys)


def test_names_off_is_honoured_when_activities_are_carried(home, fake_garmin, capsys):
    _names_on_then_off(fake_garmin, capsys)
    fake_garmin.exc = {"get_activities": RuntimeError("boom")}
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert "activities" in out["carried"]
    assert out["activities"] and all(a["name"] is None for a in out["activities"])
    assert out["lastActivity"]["name"] is None
    written = json.loads(mod.CACHE_PATH.read_text())
    assert all(a["name"] is None for a in written["activities"])


def test_names_off_is_honoured_on_a_stale_serve(home, fake_garmin, capsys):
    _names_on_then_off(fake_garmin, capsys)
    fake_garmin.exc = {"get_user_summary": ConnectionError("down")}
    out = _fetch(load_helper(), capsys)
    assert out["stale"] is True
    assert all(a["name"] is None for a in out["activities"])
    assert out["lastActivity"]["name"] is None


# --- #6: readiness backfill miss memo + deck gate -----------------------------

def test_a_backfill_miss_is_not_asked_again_the_same_day(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.readiness = []                           # answers, never a score
    mod = load_helper()
    _fetch(mod, capsys)
    assert len(_readiness_calls(fake_garmin)) == 7       # today + 6 asked once
    memo = _on_disk(mod)["readinessAsked"]
    assert memo == {day(b): day(0) for b in range(1, 7)}

    fake_garmin.calls = []
    _fetch_week(load_helper(), capsys)                   # forced burst, same day
    assert len(_readiness_calls(fake_garmin)) == 1       # only today's own call


def test_a_raised_backfill_call_is_memoed_too(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.exc = {"get_training_readiness": RuntimeError("boom")}
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.calls = []
    _fetch_week(load_helper(), capsys)
    assert len(_readiness_calls(fake_garmin)) == 1


def test_the_memo_expires_the_next_day_and_a_real_score_clears_it(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.readiness = []
    mod = load_helper()
    _fetch(mod, capsys)
    disk = _on_disk(mod)
    disk["readinessAsked"] = {d: day(1) for d in disk["readinessAsked"]}  # asked yesterday
    mod.HISTORY_PATH.write_text(json.dumps(disk))

    fake_garmin.calls = []
    fake_garmin.readiness = fixtures.READINESS          # Garmin has scores now
    out = _fetch_week(load_helper(), capsys)
    assert len(_readiness_calls(fake_garmin)) == 7       # asked again
    assert all(_row(out, b)["readiness"] == 54 for b in range(1, 7))
    assert "readinessAsked" not in _on_disk(mod)         # nothing left to remember


def test_a_planted_memo_cannot_suppress_calls_beyond_its_own_day(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps({
        "windowFetchedOn": day(1), "days": [],
        "readinessAsked": {day(2): "9999-12-31", day(3): 5, "junk": day(0)}}))
    _fetch(mod, capsys)
    assert len(_readiness_calls(fake_garmin)) == 7


def test_no_backfill_when_the_readiness_card_is_not_in_the_deck(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _with_tokens(mod)
    rc, out = run(mod, ["fetch", "--no-readiness-backfill"], capsys)
    assert out["ok"] is True and out["readiness"]["score"] == 54   # today still asked
    assert len(_readiness_calls(fake_garmin)) == 1
    assert len(fake_garmin.calls) == 14                  # the v0.4 burst, no backfill
    assert all(_row(out, b)["readiness"] is None for b in range(1, 7))


# --- #8: lastActivity is derived, never trusted -------------------------------

def test_load_cache_rederives_last_activity_from_the_list(home):
    mod = load_helper()
    _plant_cache(mod, {"ok": True, "activities": [],
                       "lastActivity": {"type": "running", "start": day(0) + "T07:00",
                                        "startLatitude": 1.23,
                                        "ownerFullName": "Planted Name"}})
    assert mod._load_cache()["lastActivity"] is None


def test_load_cache_whitelists_a_lone_last_activity(home):
    mod = load_helper()
    _plant_cache(mod, {"ok": True,
                       "lastActivity": {"type": "running", "date": "2026-01-15",
                                        "startLatitude": 1.23, "locationName": "X",
                                        "ownerFullName": "Planted Name"}})
    la = mod._load_cache()["lastActivity"]
    assert la["type"] == "running" and la["date"] == "2026-01-15"
    blob = json.dumps(la)
    assert "startLatitude" not in blob and "Planted" not in blob and "locationName" not in blob
    _plant_cache(mod, {"ok": True, "lastActivity": {"startLatitude": 1.23}})
    assert mod._load_cache()["lastActivity"] is None


# --- #9: cycling speed from averageSpeed --------------------------------------

def test_speed_prefers_average_speed_and_survives_a_cache_rebuild():
    mod = load_helper()
    raw = {"activityType": {"typeKey": "road_biking"}, "duration": 3600.0,
           "distance": 30000.0, "averageSpeed": 10.0}   # moving avg beats elapsed
    row = mod.build_activity(raw)
    assert row["speedKmh"] == 36.0
    assert mod.build_activity(row)["speedKmh"] == 36.0  # not recomputed to 30.0


def test_non_positive_average_speed_falls_back_to_distance_over_time():
    mod = load_helper()
    for bad in (0, -1.0, None, "fast", True):
        row = mod.build_activity({"type": "indoor_cycling", "duration": 3600.0,
                                  "distance": 30000.0, "averageSpeed": bad})
        assert row["speedKmh"] == 30.0, bad


def test_ride_is_a_cycling_hint():
    mod = load_helper()
    row = mod.build_activity({"type": "virtual_ride", "duration": 3600.0,
                              "distance": 30000.0, "averageSpeed": 9.0})
    assert row["speedKmh"] == 32.4 and row["paceSecPerKm"] is None

