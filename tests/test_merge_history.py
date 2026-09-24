"""_merge_history is the pure half of _update_history (v0.5 step 2): no
disk I/O, so it can be called directly with a cache and a fetched_on stamp
instead of whatever history.json happens to hold. test_window.py already
covers behavior through the full cmd_fetch path; this file exercises the
pure function's own contract in isolation.
"""
import fixtures
from conftest import load_helper
from fixtures import day


def test_pure_merge_takes_no_disk_input(home):
    """An empty cache and no fetched_on stamp — as a future demo mode would
    call it — still produces a full week with today's row filled."""
    mod = load_helper()
    payload = {"steps": {"count": 4000, "goal": 8000}}
    rows, fetched_on = mod._merge_history([], None, payload, day(0))
    assert [r["date"] for r in rows] == [day(0)]
    assert rows[0]["steps"] == 4000
    assert fetched_on is None


def test_pure_merge_matches_cached_plus_window_plus_live(home):
    mod = load_helper()
    cached = [{"date": day(1), "steps": 111, "restingHr": 50}]
    window = {"steps": [{"calendarDate": day(2), "totalSteps": 222}]}
    payload = {"steps": {"count": 999, "goal": 8000}}
    rows, fetched_on = mod._merge_history(cached, None, payload, day(0),
                                          window=window, burst=True)
    by_date = {r["date"]: r for r in rows}
    assert by_date[day(1)]["steps"] == 111          # from cache
    assert by_date[day(2)]["steps"] == 222          # from the window
    assert by_date[day(0)]["steps"] == 999          # live today wins
    assert fetched_on == day(0)                      # burst that landed something stamps


def test_pure_merge_does_not_write_anything(home):
    mod = load_helper()
    mod._merge_history([], None, {}, day(0))
    assert not mod.HISTORY_PATH.exists()
