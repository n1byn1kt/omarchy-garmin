"""One-time history backfill: a fresh install gets full week strips at once.

Without this the panel's seven-day strips need seven days of polling before
they say anything. The backfill is a single burst on the first successful
fetch, marked on disk so it never runs again.
"""
import datetime
import json

import fixtures
from conftest import load_helper
from test_helper import SLEEP, SUMMARY, _with_tokens, run
from test_payload_v2 import _all_endpoints, _fetch


def _day(back):
    return (datetime.date.today() - datetime.timedelta(days=back)).isoformat()


def _past_sleep(score):
    return {"dailySleepDTO": {"sleepScores": {"overall": {"value": score}}}}


def _stock_past_days(fake):
    """Six past days of steps (ranged) plus per-day sleep and summaries."""
    fake.daily_steps = [{"calendarDate": _day(b), "totalSteps": 1000 + b,
                         "stepGoal": 8000} for b in range(6, 0, -1)]
    fake.sleep_by_date = {_day(b): _past_sleep(50 + b) for b in range(1, 7)}
    fake.summary_by_date = {_day(b): {"restingHeartRate": 60 + b,
                                      "bodyBatteryHighestValue": 70 + b,
                                      "totalSteps": 1}
                            for b in range(1, 7)}


def _on_disk(mod):
    return json.loads(mod.HISTORY_PATH.read_text())


def test_backfill_fills_the_missing_week_on_the_first_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    mod = load_helper()
    out = _fetch(mod, capsys)

    assert [e["date"] for e in out["history"]] == [_day(b) for b in range(6, -1, -1)]
    yesterday = out["history"][-2]
    assert yesterday == {"date": _day(1), "sleepScore": 51, "steps": 1001,
                         "bodyBatteryHigh": 71, "restingHr": 61}
    # today's own entry still comes from the live payload, not the backfill
    assert out["history"][-1]["date"] == datetime.date.today().isoformat()
    assert out["history"][-1]["steps"] == SUMMARY["totalSteps"]


def test_backfill_uses_one_ranged_steps_call_and_stays_under_budget(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    _fetch(load_helper(), capsys)
    ranged = [c for c in fake_garmin.calls if c[0] == "get_daily_steps"]
    assert len(ranged) == 1
    assert ranged[0][1] == (_day(6), _day(1))
    assert len(fake_garmin.calls) <= 21   # 8 poll + 1 ranged + 6 days x 2


def test_payload_history_is_still_a_plain_list_of_day_entries(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert isinstance(out["history"], list)
    assert all(isinstance(e, dict) and "date" in e for e in out["history"])
    # the wrapper is an on-disk detail only
    assert _on_disk(load_helper()) == {"backfilled": True, "days": out["history"]}


def test_backfill_runs_at_most_once(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)                      # nothing to backfill from
    assert _on_disk(mod)["backfilled"] is True

    _stock_past_days(fake_garmin)            # data appears afterwards
    fake_garmin.calls = []
    out = _fetch(load_helper(), capsys)
    assert len(out["history"]) == 1
    assert not [c for c in fake_garmin.calls if c[0] == "get_daily_steps"]


def test_normal_poll_after_backfill_makes_exactly_eight_api_calls(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    _fetch(load_helper(), capsys)
    fake_garmin.calls = []
    _fetch(load_helper(), capsys)
    assert len(fake_garmin.calls) == 8


def test_old_flat_list_history_is_migrated_and_backfilled(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.HISTORY_PATH.write_text(json.dumps(
        [{"date": _day(2), "sleepScore": 11, "steps": 22,
          "bodyBatteryHigh": 33, "restingHr": 44}]))

    out = _fetch(mod, capsys)
    assert len(out["history"]) == 7
    # the pre-existing day is kept as it was, not overwritten by the backfill
    assert out["history"][4] == {"date": _day(2), "sleepScore": 11, "steps": 22,
                                 "bodyBatteryHigh": 33, "restingHr": 44}
    assert _on_disk(mod)["backfilled"] is True


def test_a_failing_backfill_endpoint_only_nulls_its_own_field(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    # the ranged steps call is the one that dies, and no per-day summary
    # carries a step count to fall back on
    fake_garmin.summary_by_date = {d: {k: v for k, v in s.items() if k != "totalSteps"}
                                   for d, s in fake_garmin.summary_by_date.items()}
    fake_garmin.exc = {"get_daily_steps": RuntimeError("boom")}
    mod = load_helper()
    out = _fetch(mod, capsys)
    past = [e for e in out["history"] if e["date"] != datetime.date.today().isoformat()]
    assert len(past) == 6
    assert all(e["steps"] is None for e in past)
    assert all(e["sleepScore"] is not None and e["restingHr"] is not None
               for e in past)


def test_a_day_with_no_data_at_all_is_left_out(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    fake_garmin.daily_steps = [{"calendarDate": _day(3), "totalSteps": 4242}]
    out = _fetch(load_helper(), capsys)
    assert [e["date"] for e in out["history"]] == [
        _day(3), datetime.date.today().isoformat()]
    assert out["history"][0] == {"date": _day(3), "sleepScore": None,
                                 "steps": 4242, "bodyBatteryHigh": None,
                                 "restingHr": None}


def test_no_backfill_on_a_failed_fetch(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_past_days(fake_garmin)
    mod = load_helper()
    _with_tokens(mod)
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert rc == 0 and out["ok"] is False
    assert not mod.HISTORY_PATH.exists()


def test_a_throwing_backfill_still_marks_itself_done(home, fake_garmin, capsys):
    """Whatever goes wrong in there, the burst must not repeat every poll."""
    _all_endpoints(fake_garmin)
    mod = load_helper()
    mod._backfill = lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("boom"))
    out = _fetch(mod, capsys)
    assert out["ok"] is True and len(out["history"]) == 1
    assert _on_disk(mod)["backfilled"] is True
