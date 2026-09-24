"""Windowed history: the trailing week is re-fetched, never accumulated.

v0.2/0.3 grew history one poll at a time and backfilled once; a laptop shut
over a weekend left holes that never healed. v0.4 asks Garmin's ranged daily
endpoints for today-6..today — once per calendar day, or on a manual refresh
— and merges the answer over whatever is cached. Three states per field:
a *value* wins by precedence (live today > window > cache), a source that
*answered without* a day leaves the cached value alone, and a source that
*failed* leaves the cached value alone too. Nothing here ever writes a None
over a number.
"""
import datetime
import json

import fixtures
from conftest import load_helper
from fixtures import day
from test_helper import SLEEP, SUMMARY, _with_tokens, run
from test_payload_v2 import _all_endpoints, _fetch

TODAY = datetime.date.today().isoformat()
RANGED = {"get_daily_steps", "get_rhr_daily", "get_sleep_daily", "get_hrv_data_range",
          "get_calories_daily", "connectapi"}
SCHEMA = {"date", "steps", "stepGoal", "sleepScore", "sleepMin", "deepMin", "lightMin",
          "remMin", "awakeMin", "restingHr", "hrvNight", "hrvWeekly", "hrvBalLow",
          "hrvBalHigh", "bbHigh", "bbLow", "bbCharged", "bbDrained", "stressAvg",
          "stressRestMin", "stressLowMin", "stressMedMin", "stressHighMin",
          "calActive", "calResting", "readiness"}


def _stock_week(fake, backs=range(6, -1, -1)):
    fake.daily_steps = fixtures.week_steps(backs)
    fake.rhr_daily = fixtures.week_rhr(backs)
    fake.sleep_daily = fixtures.week_sleep(backs)
    fake.body_battery_range = fixtures.week_body_battery(backs)
    fake.hrv_range = fixtures.week_hrv(backs)
    fake.calories_daily = fixtures.week_calories(backs)
    fake.stress_daily = fixtures.week_stress(backs)


def _fetch_week(mod, capsys):
    _with_tokens(mod)
    rc, out = run(mod, ["fetch", "--week"], capsys)
    assert rc == 0
    return out


def _on_disk(mod):
    return json.loads(mod.HISTORY_PATH.read_text())


def _ranged_calls(fake):
    return [c for c in fake.calls
            if c[0] in RANGED or (c[0] == "get_body_battery" and len(c[1]) == 2)]


def _row(out, back):
    rows = [e for e in out["history"] if e["date"] == day(back)]
    assert len(rows) == 1, f"expected one row for {day(back)}, got {rows}"
    return rows[0]


# --- the first fetch of the day pulls the window -------------------------------

def test_first_fetch_of_the_day_fills_the_whole_week(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert [e["date"] for e in out["history"]] == [day(b) for b in range(6, -1, -1)]
    assert _on_disk(mod)["windowFetchedOn"] == TODAY
    assert "backfilled" not in _on_disk(mod)


def test_window_rows_carry_the_full_schema_with_units_normalised(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    out = _fetch(load_helper(), capsys)
    y = _row(out, 1)
    assert set(y) == SCHEMA
    assert (y["steps"], y["stepGoal"]) == (5100, 8010)
    assert y["restingHr"] == 51                      # 51.0 → int
    assert y["sleepScore"] == 61
    assert y["sleepMin"] == 361 and y["deepMin"] == 61   # seconds → minutes
    assert (y["lightMin"], y["remMin"], y["awakeMin"]) == (240, 30, 10)
    assert (y["bbHigh"], y["bbLow"]) == (71, 21)     # leading null skipped
    assert (y["bbCharged"], y["bbDrained"]) == (41, 31)
    assert (y["hrvNight"], y["hrvWeekly"]) == (51, 44)
    assert (y["hrvBalLow"], y["hrvBalHigh"]) == (44, 63)
    assert (y["calActive"], y["calResting"]) == (301, 1600)
    assert y["stressAvg"] == 26
    assert (y["stressRestMin"], y["stressLowMin"]) == (600, 121)
    assert (y["stressMedMin"], y["stressHighMin"]) == (60, 30)
    # v0.5 extra step: no ranged readiness endpoint exists, so a burst
    # backfills it with one get_training_readiness(date) call per missing
    # day instead — see test_readiness_backfill.py.
    assert y["readiness"] == 54


def test_bb_levels_drops_negative_sentinels(home):
    """_bb_levels() feeds the ranged day's high/low — same -1/-2 "no valid
    reading" sentinel _series() drops for the curve must not sneak a
    negative low into a day's Body Battery range."""
    mod = load_helper()
    day_entry = {
        "bodyBatteryValueDescriptorDTOList": [
            {"bodyBatteryValueDescriptorKey": "timestamp", "index": 0},
            {"bodyBatteryValueDescriptorKey": "bodyBatteryLevel", "index": 1},
        ],
        "bodyBatteryValuesArray": [
            [1000, -1], [2000, 40], [3000, -2], [4000, 55],
        ],
    }
    assert mod._bb_levels(day_entry) == [40, 55]


def test_burst_budget_is_fourteen_calls_with_body_battery_asked_once(home, fake_garmin, capsys):
    """v0.5 extra step: a burst against an empty cache also backfills
    readiness for every one of the 6 non-today window days (none of them
    have a cached score yet), one get_training_readiness(date) call each —
    14 + 6 = 20. See test_readiness_backfill.py for the budget shrinking
    once some of those days are already scored."""
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    _fetch(load_helper(), capsys)
    assert len(fake_garmin.calls) == 20
    readiness_calls = [c for c in fake_garmin.calls if c[0] == "get_training_readiness"]
    assert len(readiness_calls) == 7                 # today + 6 backfilled days
    bb = [c for c in fake_garmin.calls if c[0] == "get_body_battery"]
    assert bb == [("get_body_battery", (day(6), TODAY))]


def test_body_battery_range_feeds_todays_curve_on_a_burst(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.stress = None          # otherwise the dense stress series wins
    out = _fetch(load_helper(), capsys)
    today_bb = fixtures.week_body_battery([0])[0]
    assert out["curve"]["bodyBattery"] == [[p[0], p[1]] for p in
                                           today_bb["bodyBatteryValuesArray"] if p[1] is not None]


def test_a_failed_body_battery_range_falls_back_to_the_day_call(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.stress = None
    fake_garmin.body_battery_range = None
    out = _fetch(load_helper(), capsys)
    assert out["curve"]["bodyBattery"] == fixtures.BODY_BATTERY[0]["bodyBatteryValuesArray"]
    bb = [c[1] for c in fake_garmin.calls if c[0] == "get_body_battery"]
    assert bb == [(day(6), TODAY), (TODAY,)]


# --- later polls the same day are today-only and must not lose the week ---------

def test_same_day_poll_is_today_only_and_keeps_every_window_field(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.calls = []
    fake_garmin.summary = dict(SUMMARY, totalSteps=9500)
    out = _fetch(load_helper(), capsys)
    assert len(fake_garmin.calls) == 8
    assert _ranged_calls(fake_garmin) == []
    assert len(out["history"]) == 7
    assert _row(out, 1)["stressAvg"] == 26           # yesterday untouched
    t = _row(out, 0)
    assert t["steps"] == 9500                        # live wins for today
    assert t["stressAvg"] == 25 and t["deepMin"] == 60   # window-only fields survive


def test_manual_week_refresh_bursts_again_the_same_day(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.calls = []
    _fetch_week(load_helper(), capsys)
    assert len(_ranged_calls(fake_garmin)) == 7


def test_no_reburst_on_a_short_or_gappy_week_once_stamped(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin, backs=[3, 0])          # Garmin only has two days
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert [e["date"] for e in out["history"]] == [day(3), TODAY]
    fake_garmin.calls = []
    _fetch(load_helper(), capsys)
    assert _ranged_calls(fake_garmin) == []


def test_stale_stamp_from_yesterday_bursts_and_heals_gaps(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps({
        "windowFetchedOn": day(1),
        "days": [{"date": day(b), "steps": 1} for b in (6, 5, 2, 1)]}))
    out = _fetch(mod, capsys)
    assert [e["date"] for e in out["history"]] == [day(b) for b in range(6, -1, -1)]
    assert _row(out, 4)["steps"] == 5400              # the hole is filled
    assert _row(out, 5)["steps"] == 5500              # and a cached value is refreshed


# --- precedence: value > (absent | failed) ---------------------------------------

def test_live_value_beats_window_for_today(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    out = _fetch(load_helper(), capsys)
    t = _row(out, 0)
    assert t["steps"] == SUMMARY["totalSteps"]        # 8000, not the window's 5000
    assert t["stepGoal"] == SUMMARY["dailyStepGoal"]
    assert t["sleepScore"] == 65 and t["sleepMin"] == 353
    assert t["bbHigh"] == 90 and t["bbLow"] == 30
    assert t["restingHr"] == 52
    assert t["readiness"] == 54                       # from get_training_readiness
    assert t["hrvNight"] == 58 and t["hrvWeekly"] == 44


def test_a_live_none_does_not_overwrite_a_window_number(home, fake_garmin, capsys):
    """Empty morning: the watch has not synced, the summary has no RHR yet."""
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.summary = {k: v for k, v in SUMMARY.items() if k != "restingHeartRate"}
    out = _fetch(load_helper(), capsys)
    assert out["restingHr"] is None
    assert _row(out, 0)["restingHr"] == 50


def test_a_failed_ranged_call_leaves_cached_fields_untouched(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.rhr_daily = [{"calendarDate": day(1), "value": 99.0}]
    fake_garmin.exc = {"get_rhr_daily": RuntimeError("boom")}
    out = _fetch_week(load_helper(), capsys)
    assert out["ok"] is True
    assert _row(out, 1)["restingHr"] == 51            # not 99, not None
    assert _row(out, 1)["steps"] == 5100              # the other sources still landed


def test_a_source_that_answers_without_a_day_keeps_the_cached_value(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.sleep_daily = fixtures.week_sleep([6, 5, 4, 0])   # nights 1–3 gone
    out = _fetch_week(load_helper(), capsys)
    assert _row(out, 2)["sleepScore"] == 62
    assert _row(out, 2)["deepMin"] == 62


def test_a_null_inside_a_window_row_does_not_overwrite(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    hrv = fixtures.week_hrv()
    hrv["hrvSummaries"][5]["lastNightAvg"] = None     # yesterday, watch off
    fake_garmin.hrv_range = hrv
    out = _fetch_week(load_helper(), capsys)
    assert _row(out, 1)["hrvNight"] == 51


def test_the_raw_stress_path_failing_costs_only_its_fields(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.exc = {"connectapi": RuntimeError("404")}
    out = _fetch(load_helper(), capsys)
    y = _row(out, 1)
    assert y["stressAvg"] is None and y["stressRestMin"] is None
    assert y["steps"] == 5100 and y["sleepScore"] == 61


def test_readiness_accumulates_and_survives_a_burst(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.readiness = None                      # endpoint gone this poll
    out = _fetch_week(load_helper(), capsys)
    assert _row(out, 0)["readiness"] == 54


# --- degraded bursts ----------------------------------------------------------------

def test_every_ranged_call_raising_leaves_the_stamp_unset_and_rebursts(home, fake_garmin, capsys):
    """A burst that lands nothing (every ranged source raised) must not stamp
    windowFetchedOn — stamping on an empty burst would strand the week at
    whatever the cache had until tomorrow. Leaving it unset means the very
    next poll bursts again, e.g. once the rate limit clears."""
    class TooManyRequestsError(Exception):
        pass
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.exc = {n: TooManyRequestsError("429") for n in RANGED | {"get_body_battery"}}
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert out["ok"] is True
    assert [e["date"] for e in out["history"]] == [TODAY]
    assert _row(out, 0)["steps"] == 8000
    assert _on_disk(mod)["windowFetchedOn"] is None
    fake_garmin.calls = []
    _fetch(load_helper(), capsys)
    assert _ranged_calls(fake_garmin) != []           # retried on the very next poll


def test_today_row_exists_even_when_everything_is_null(home, fake_garmin, capsys):
    mod = load_helper()
    out = _fetch(mod, capsys)                          # every source empty
    assert out["ok"] is True
    assert [e["date"] for e in out["history"]] == [TODAY]
    assert set(out["history"][0]) == SCHEMA


def test_no_history_write_on_a_failed_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _with_tokens(mod)
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch", "--week"], capsys)
    assert rc == 0 and out["ok"] is False
    assert not mod.HISTORY_PATH.exists()


# --- pruning and legacy files -----------------------------------------------------------

def test_rows_outside_the_calendar_window_are_pruned_even_from_a_short_file(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps({
        "windowFetchedOn": TODAY,
        "days": [{"date": day(9), "steps": 9}, {"date": day(7), "steps": 7},
                 {"date": day(6), "steps": 6}, {"date": day(2), "steps": 2}]}))
    out = _fetch(mod, capsys)
    assert [e["date"] for e in out["history"]] == [day(6), day(2), TODAY]


def test_legacy_bare_list_with_bodyBatteryHigh_is_upgraded(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps(
        [{"date": day(2), "sleepScore": 11, "steps": 22,
          "bodyBatteryHigh": 33, "restingHr": 44}]))
    out = _fetch(mod, capsys)
    old = _row(out, 2)
    assert old["bbHigh"] == 33 and "bodyBatteryHigh" not in old
    assert (old["sleepScore"], old["steps"], old["restingHr"]) == (11, 22, 44)
    assert set(old) == SCHEMA
    assert len(_ranged_calls(fake_garmin)) == 7       # no stamp → burst


def test_legacy_backfilled_wrapper_is_read_and_dropped(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps({
        "backfilled": True,
        "days": [{"date": day(1), "sleepScore": 51, "steps": 1001,
                  "bodyBatteryHigh": 71, "restingHr": 61}]}))
    out = _fetch(mod, capsys)
    assert _row(out, 1)["bbHigh"] == 71
    disk = _on_disk(mod)
    assert set(disk) == {"windowFetchedOn", "days"}


def test_planted_non_numeric_values_are_dropped_on_load(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps({
        "windowFetchedOn": TODAY,
        "days": [{"date": day(1), "steps": "<script>", "bbHigh": True,
                  "restingHr": 55, "unknownField": 1}]}))
    out = _fetch(mod, capsys)
    y = _row(out, 1)
    assert y["steps"] is None and y["bbHigh"] is None and y["restingHr"] == 55
    assert "unknownField" not in y


def test_payload_history_is_a_plain_list_and_the_wrapper_is_on_disk_only(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert isinstance(out["history"], list)
    assert _on_disk(mod) == {"windowFetchedOn": TODAY, "days": out["history"]}
