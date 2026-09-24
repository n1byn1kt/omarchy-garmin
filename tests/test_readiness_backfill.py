"""v0.5 extra step: readiness backfill.

garminconnect 0.3.11 has no ranged get_training_readiness (checked in the
venv's typed.py/__init__.py — only the single-day get_training_readiness(
cdate) exists), so unlike every other HISTORY_FIELDS column, readiness for
a day other than today never arrives through _fetch_window. On a burst,
one get_training_readiness(date) call per window day that doesn't already
have a cached score fills the gap instead — this is what lets a laptop
that slept through a weekend end up with readiness for both days once it
wakes up, without ever having been awake for them.
"""
import fixtures
from conftest import load_helper
from fixtures import day
from test_helper import _with_tokens, run
from test_payload_v2 import _all_endpoints
from test_window import _fetch_week, _row, _stock_week


def _fetch(mod, capsys):
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert rc == 0
    return out


def test_a_weekend_gap_backfills_without_the_machine_being_awake(home, fake_garmin, capsys):
    """The laptop was asleep for day(2) and day(1) (no history rows for
    them at all, as if it never polled) and wakes up today. A single burst
    must still end up with readiness for every window day Garmin has one
    for, even the days nothing else was fetched on."""
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    out = _fetch(mod, capsys)
    for back in range(6, -1, -1):
        row = _row(out, back)
        assert row["readiness"] == 54, back


def test_missing_dates_are_computed_from_the_cache_not_refetched_every_burst(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)                                # first burst backfills everything
    readiness_calls_first = [c for c in fake_garmin.calls if c[0] == "get_training_readiness"]
    assert len(readiness_calls_first) == 7             # today + 6 backfilled

    fake_garmin.calls = []
    _fetch_week(load_helper(), capsys)                 # a second, forced burst
    readiness_calls_second = [c for c in fake_garmin.calls if c[0] == "get_training_readiness"]
    assert len(readiness_calls_second) == 1            # only today — every other day is cached now


def test_a_partially_scored_week_only_backfills_the_gap(home, fake_garmin, capsys):
    """Days 3 and 4 already have a cached readiness (as if a previous
    version, or a prior partial burst, had filled them); only the other
    4 non-today days should cost a call."""
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    import json
    mod.HISTORY_PATH.write_text(json.dumps({
        "windowFetchedOn": day(1),
        "days": [{"date": day(3), "readiness": 71}, {"date": day(4), "readiness": 62}]}))
    out = _fetch(mod, capsys)
    readiness_calls = [c for c in fake_garmin.calls if c[0] == "get_training_readiness"]
    assert len(readiness_calls) == 5                   # today + 4 missing (not 3, not 4)
    assert _row(out, 3)["readiness"] == 71              # untouched, not overwritten
    assert _row(out, 4)["readiness"] == 62
    assert _row(out, 2)["readiness"] == 54              # backfilled


def test_backfill_never_overwrites_a_real_cached_number(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    mod.HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    import json
    mod.HISTORY_PATH.write_text(json.dumps({
        "windowFetchedOn": day(1),
        "days": [{"date": day(2), "readiness": 88}]}))
    fake_garmin.readiness = [{"score": 10, "level": "LOW", "timestamp": day(2) + "T06:00:00"}]
    out = _fetch(mod, capsys)
    assert _row(out, 2)["readiness"] == 88


def test_backfill_respects_safe_failed_semantics_one_call_isolated(home, fake_garmin, capsys):
    """A raised get_training_readiness for the backfill must not break the
    fetch, and must not carry a stale value into that day's row — it's a
    history field, not a top-level payload key, so CARRY_KEYS doesn't apply
    here; the day just stays null and gets retried on the next burst."""
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    fake_garmin.exc = {"get_training_readiness": RuntimeError("boom")}
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert out["ok"] is True
    for back in range(6, -1, -1):
        assert _row(out, back)["readiness"] is None


def test_a_day_with_no_other_data_does_not_get_manufactured_by_backfill(home, fake_garmin, capsys):
    """_merge_history drops a non-today day with zero layers entirely;
    readiness backfill must not resurrect a row that doesn't exist just
    because Garmin happened to answer a readiness score for that date."""
    _all_endpoints(fake_garmin)
    fake_garmin.daily_steps = fixtures.week_steps([0])   # only today has any window data
    mod = load_helper()
    out = _fetch(mod, capsys)
    assert [e["date"] for e in out["history"]] == [day(0)]


def test_call_budget_counts_readiness_backfill_calls(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    out = _fetch(load_helper(), capsys)
    assert len(fake_garmin.calls) == 20                # 14 (v0.4 burst) + 6 backfill


def test_today_only_poll_never_backfills(home, fake_garmin, capsys):
    """Backfill is a burst-only feature: a same-day poll must not spend a
    call on every window day just because one of them still lacks a
    readiness score."""
    _all_endpoints(fake_garmin)
    _stock_week(fake_garmin)
    mod = load_helper()
    _fetch(mod, capsys)
    fake_garmin.calls = []
    _fetch(load_helper(), capsys)
    # Exactly one — today's own extras call, not six more for the rest of
    # the window (those only ever fire on a burst).
    readiness_calls = [c for c in fake_garmin.calls if c[0] == "get_training_readiness"]
    assert len(readiness_calls) == 1
    assert len(fake_garmin.calls) == 8
