import json

from conftest import load_helper


def run(mod, argv, capsys):
    rc = mod.main(argv)
    out = capsys.readouterr().out
    return rc, json.loads(out)


def test_status_no_tokens(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["status"], capsys)
    assert rc == 0
    assert out == {"ok": True, "deps": mod.HAS_GARMINCONNECT, "tokens": False}


def test_status_with_tokens(home, capsys):
    mod = load_helper()
    mod.TOKENS_PATH.parent.mkdir(parents=True)
    mod.TOKENS_PATH.write_text("{}")
    rc, out = run(mod, ["status"], capsys)
    assert rc == 0 and out["tokens"] is True


SUMMARY = {
    "totalSteps": 8000, "dailyStepGoal": 10000, "restingHeartRate": 52,
    "bodyBatteryMostRecentValue": 61, "bodyBatteryHighestValue": 90,
    "bodyBatteryLowestValue": 30,
}
SLEEP = {"dailySleepDTO": {"sleepTimeSeconds": 21180,
                           "sleepScores": {"overall": {"value": 65}}}}


def _with_tokens(mod):
    mod.TOKENS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.TOKENS_PATH.write_text("{}")


def test_fetch_happy(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is True and out["stale"] is False
    assert out["bodyBattery"] == {"current": 61, "high": 90, "low": 30}
    assert out["sleep"] == {"score": 65, "durationMin": 353}
    assert out["steps"] == {"count": 8000, "goal": 10000}
    assert out["restingHr"] == 52 and out["asOf"]


def test_fetch_null_sleep_is_happy(home, fake_garmin, capsys):
    fake_garmin.summary = SUMMARY
    fake_garmin.sleep = {"dailySleepDTO": {"sleepTimeSeconds": None}}
    mod = load_helper()
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is True
    assert out["sleep"] == {"score": None, "durationMin": None}


def test_fetch_writes_cache(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    run(mod, ["fetch"], capsys)
    import json as j
    assert j.loads(mod.CACHE_PATH.read_text())["ok"] is True


def test_fetch_auth_expired(home, fake_garmin, capsys):
    from conftest import AuthError
    fake_garmin.login_exc = AuthError("expired")
    mod = load_helper()
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert out == {"ok": False, "error": "auth-expired",
                   "hint": "run: garmin-widget login"}


def test_fetch_transient_error_serves_stale_cache(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    run(mod, ["fetch"], capsys)          # seed cache
    fake_garmin.login_exc = ConnectionError("boom")
    mod2 = load_helper()
    rc, out = run(mod2, ["fetch"], capsys)
    assert out["ok"] is True and out["stale"] is True
    assert out["bodyBattery"]["current"] == 61


def test_fetch_transient_error_no_cache(home, fake_garmin, capsys):
    fake_garmin.login_exc = ConnectionError("boom")
    mod = load_helper()
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False and out["error"] == "offline"


def test_fetch_cache_write_failure_is_nonfatal(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    # Make CACHE_PATH unwritable by pre-creating it as a directory.
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.mkdir()
    rc, out = run(mod, ["fetch"], capsys)
    assert rc == 0
    assert out["ok"] is True and out["stale"] is False
