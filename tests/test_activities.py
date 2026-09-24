"""v0.5 step 4: build_activity/build_activities, get_activities(0, 20)
replacing get_last_activity, and the activities entry in CARRY_KEYS.

Amendments quoted below are the Grok QC amendments in docs/plan-v5.md,
which supersede the plan's own earlier task-list/test-plan text where they
conflict — most of what's tested here follows the amendments, not A2/A3
verbatim.
"""
import json

import fixtures
from conftest import load_helper
from fixtures import day
from test_helper import SLEEP, SUMMARY, _with_tokens, run
from test_payload_v2 import FORBIDDEN_ACTIVITY_KEYS, _all_endpoints, _fetch


# --- whitelist -----------------------------------------------------------------

def test_build_activities_from_the_full_key_fixture_drops_every_hostile_key():
    mod = load_helper()
    built = mod.build_activities(fixtures.ACTIVITIES)
    assert len(built) == 3
    blob = json.dumps(built)
    for forbidden in FORBIDDEN_ACTIVITY_KEYS:
        assert forbidden not in blob, forbidden
    assert "Demo User" not in blob and "Nowhereville" not in blob


def test_build_activity_returns_none_for_a_non_dict():
    mod = load_helper()
    assert mod.build_activity(None) is None
    assert mod.build_activity("nope") is None
    assert mod.build_activity([1, 2]) is None


# --- id (amendment 6: accepts int OR digit-string, emitted as a string) --------

def test_id_accepts_int_and_digit_string_emits_string():
    mod = load_helper()
    assert mod.build_activity({"activityId": 123, "type": "running"})["id"] == "123"
    assert mod.build_activity({"activityId": "123", "type": "running"})["id"] == "123"


def test_id_rejects_bool_zero_negative_and_too_large():
    mod = load_helper()
    for bad in (True, False, 0, -5, 2 ** 63, "not-digits", "-5", None):
        assert mod.build_activity({"activityId": bad, "type": "running"})["id"] is None, bad


def test_id_accepts_the_largest_valid_value():
    mod = load_helper()
    top = 2 ** 63 - 1
    assert mod.build_activity({"activityId": top, "type": "running"})["id"] == str(top)


def test_a_row_with_a_null_id_is_still_a_row():
    mod = load_helper()
    row = mod.build_activity({"activityId": "abc", "type": "running",
                              "startTimeLocal": day(0) + " 07:00:00"})
    assert row is not None and row["id"] is None and row["type"] == "running"


def test_id_round_trips_through_json_as_a_string_never_a_number():
    mod = load_helper()
    row = mod.build_activity({"activityId": 20123456789, "type": "running"})
    blob = json.dumps(row)
    parsed = json.loads(blob)
    assert isinstance(parsed["id"], str) and parsed["id"] == "20123456789"


# --- name (A2 + Q3) -------------------------------------------------------------

def test_name_clipped_to_48():
    mod = load_helper()
    long = "Very Long City Name Activity " * 5
    row = mod.build_activity({"activityName": long, "type": "running"})
    assert len(row["name"]) == mod.ACTIVITY_NAME_CLIP


def test_empty_or_whitespace_name_is_null():
    mod = load_helper()
    for bad in ("", "   ", None, 123):
        assert mod.build_activity({"activityName": bad, "type": "running"})["name"] is None, bad


def test_location_name_never_appears_even_when_activity_name_is_null():
    mod = load_helper()
    row = mod.build_activity({"activityName": None, "locationName": "Somewhere",
                              "type": "running"})
    assert row["name"] is None
    assert "Somewhere" not in json.dumps(row)


def test_activity_names_pref_off_drops_the_name():
    mod = load_helper()
    row = mod.build_activity({"activityName": "Morning Run", "type": "running"},
                             activity_names=False)
    assert row["name"] is None


# --- start (amendment 3: bucket/sort on startTimeGMT, display startTimeLocal) --

def test_start_normalised_from_space_separated_with_seconds():
    mod = load_helper()
    row = mod.build_activity({"type": "running",
                              "startTimeLocal": "2026-09-22 07:14:33"})
    assert row["start"] == "2026-09-22T07:14"
    assert row["date"] == "2026-09-22"


def test_start_normalised_from_t_separated_with_fraction():
    mod = load_helper()
    row = mod.build_activity({"type": "running",
                              "startTimeLocal": "2026-09-22T07:14:33.0"})
    assert row["start"] == "2026-09-22T07:14"


def test_start_is_null_when_not_a_string():
    mod = load_helper()
    row = mod.build_activity({"type": "running", "startTimeLocal": None})
    assert row["start"] is None and row["date"] is None


# --- units -----------------------------------------------------------------------

def test_units_seconds_to_minutes_metres_to_km():
    mod = load_helper()
    row = mod.build_activity({"type": "running", "duration": 3120.0, "distance": 8410.3})
    assert row["durationMin"] == 52 and row["distanceKm"] == 8.41


def test_zero_distance_is_null():
    mod = load_helper()
    row = mod.build_activity({"type": "hiking", "duration": 60.0, "distance": 0.0})
    assert row["distanceKm"] is None


# --- sort / cap ------------------------------------------------------------------

def test_sort_newest_first_by_start_time_gmt():
    mod = load_helper()
    built = mod.build_activities(fixtures.ACTIVITIES)
    assert [a["id"] for a in built] == ["10000000001", "10000000002", "10000000003"]


def test_null_starts_sort_last():
    mod = load_helper()
    raw = [{"activityId": 1, "type": "running", "startTimeGMT": None},
          {"activityId": 2, "type": "running", "startTimeGMT": day(0) + " 07:00:00"}]
    built = mod.build_activities(raw)
    assert [a["id"] for a in built] == ["2", "1"]


def test_activity_list_dict_form_is_accepted():
    mod = load_helper()
    built = mod.build_activities(fixtures.ACTIVITIES_DICT_FORM)
    assert len(built) == 3


def test_a_ten_thousand_entry_response_costs_activity_rows_not_ten_thousand():
    mod = load_helper()
    raw = [{"activityId": i, "type": "running",
           "startTimeGMT": f"2026-01-01 00:{i % 60:02d}:00"} for i in range(1, 10001)]
    built = mod.build_activities(raw)
    assert len(built) == mod.ACTIVITY_ROWS


def test_non_list_garbage_yields_empty_activities_and_null_last(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.activities = "not a list"
    out = _fetch(load_helper(), capsys)
    assert out["ok"] is True
    assert out["activities"] == [] and out["lastActivity"] is None


def test_entries_with_neither_type_nor_start_are_dropped():
    mod = load_helper()
    built = mod.build_activities([{"activityId": 1}, fixtures.ACTIVITIES[0]])
    assert len(built) == 1


# --- lastActivity ------------------------------------------------------------

def test_last_activity_equals_activities_zero(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert out["lastActivity"] == out["activities"][0]


# --- call budget ---------------------------------------------------------------

def test_get_activities_called_once_with_zero_and_twenty(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    out = _fetch(load_helper(), capsys)
    calls = [c for c in fake_garmin.calls if c[0] == "get_activities"]
    assert calls == [("get_activities", (0, 20))]
    assert not any(c[0] == "get_last_activity" for c in fake_garmin.calls)


def test_today_only_call_budget_is_still_eight(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)                                # first fetch of the day bursts
    fake_garmin.calls = []
    _fetch(load_helper(), capsys)
    assert len(fake_garmin.calls) == 8


# --- carry-forward (amendment 5 + activities in CARRY_KEYS) --------------------

def test_get_activities_raising_carries_activities_from_cache(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)                      # seed a good cache
    fake_garmin.exc = {"get_activities": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["carried"] == ["activities"]
    assert out["activities"][0]["id"] == "10000000001"
    assert out["lastActivity"] == out["activities"][0]


def test_get_activities_answering_none_is_also_failed_and_carries(home, fake_garmin, capsys):
    """amendment 5: an answer that isn't a list or {"activityList": [...]}
    (None here) is FAILED, not an empty-but-valid answer."""
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.activities = None
    out = _fetch(load_helper(), capsys)
    assert out["carried"] == ["activities"]
    assert out["activities"][0]["id"] == "10000000001"


def test_nothing_cached_still_marks_activities_carried(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.exc = {"get_activities": RuntimeError("boom")}
    out = _fetch(load_helper(), capsys)
    assert out["carried"] == ["activities"]
    assert out["activities"] == [] and out["lastActivity"] is None


def test_a_genuine_empty_list_is_not_carried(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.activities = []
    out = _fetch(load_helper(), capsys)
    assert out["activities"] == [] and out["lastActivity"] is None
    assert "activities" not in out["carried"]


# --- cached activities re-run through build_activities (amendment 4) -----------

def test_load_cache_rewhitelists_planted_coordinates_and_caps_row_count(home):
    mod = load_helper()
    planted = [{"id": str(i), "type": "running", "start": day(0) + "T07:00",
               "startLatitude": 1.23} for i in range(10000)]
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(json.dumps({"ok": True, "stale": False,
                                          "activities": planted}))
    cached = mod._load_cache()
    assert len(cached["activities"]) <= mod.ACTIVITY_ROWS
    assert "startLatitude" not in json.dumps(cached["activities"])


def test_load_cache_migrates_legacy_date_only_activities(home):
    """A pre-v0.5 row has `date` but no `start`; _load_cache must not lose
    it to build_activities' lookup (amendment 8's legacy migration)."""
    mod = load_helper()
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(json.dumps({
        "ok": True, "stale": False,
        "activities": [{"id": "5", "type": "hiking", "date": "2026-01-15"}]}))
    cached = mod._load_cache()
    assert cached["activities"][0]["id"] == "5"
    assert cached["activities"][0]["type"] == "hiking"


# --- pace vs speed (Q6) ---------------------------------------------------------

def test_pace_for_running_walking_hiking():
    mod = load_helper()
    for type_key in ("running", "trail_running", "walking", "hiking"):
        row = mod.build_activity({"type": type_key, "duration": 1800.0, "distance": 5000.0})
        assert row["paceSecPerKm"] is not None and row["speedKmh"] is None, type_key


def test_speed_for_cycling_biking():
    mod = load_helper()
    for type_key in ("road_biking", "indoor_cycling", "mountain_biking"):
        row = mod.build_activity({"type": type_key, "duration": 3600.0, "distance": 30000.0})
        assert row["speedKmh"] == 30.0 and row["paceSecPerKm"] is None, type_key


def test_neither_pace_nor_speed_for_other_types():
    mod = load_helper()
    row = mod.build_activity({"type": "yoga", "duration": 1800.0, "distance": 0.0})
    assert row["paceSecPerKm"] is None and row["speedKmh"] is None
