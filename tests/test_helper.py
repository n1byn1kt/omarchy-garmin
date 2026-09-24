import json
import os

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


def test_deps_hint_is_venv_install_for_fetch_and_login(home, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["error"] == "deps"
    assert out["hint"] == mod.DEPS_HINT
    assert out["hint"] == (
        "python3 -m venv ~/.local/share/garmin-widget/venv && "
        "~/.local/share/garmin-widget/venv/bin/pip install --require-hashes -r ~/.config/omarchy/plugins/io.github.n1byn1kt.garmin/requirements.txt"
    )
    # Panel.qml carries the same string as its fallback for payloads that
    # arrive without a hint. The two must stay byte-identical or the panel
    # prints an install command the helper has moved on from.
    from conftest import HELPER
    panel = (HELPER.parent.parent / "Panel.qml").read_text()
    assert '"' + mod.DEPS_HINT + '"' in panel
    rc, out = run(mod, ["login"], capsys)
    assert out["error"] == "deps"
    assert out["hint"] == mod.DEPS_HINT


def test_reexec_loop_guard_skips_execv(home, monkeypatch, capsys):
    """GARMIN_WIDGET_REEXEC already set means we already re-exec'd once;
    don't try again even if garminconnect is still missing."""
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.setenv("GARMIN_WIDGET_REEXEC", "1")
    calls = []
    monkeypatch.setattr(os, "execv", lambda *a: calls.append(a))
    # Even with a venv python present, the loop guard must win.
    venv_py = mod._venv_python()
    venv_py.parent.mkdir(parents=True, exist_ok=True)
    venv_py.write_text("#!/bin/sh\n")
    rc, out = run(mod, ["fetch"], capsys)
    assert calls == []
    assert out["ok"] is False and out["error"] == "deps"


def test_reexec_into_venv_when_garminconnect_missing(home, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    venv_py = mod._venv_python()
    venv_py.parent.mkdir(parents=True, exist_ok=True)
    venv_py.write_text("#!/bin/sh\n")
    venv_py.chmod(0o755)

    calls = []
    monkeypatch.setattr(os, "execv", lambda path, args: calls.append((path, args)))
    try:
        mod.main(["fetch"])
        assert len(calls) == 1
        path, args = calls[0]
        assert path == str(venv_py)
        assert args == [str(venv_py), os.path.abspath(mod.__file__), "fetch"]
        assert os.environ.get("GARMIN_WIDGET_REEXEC") == "1"
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


def test_reexec_execv_failure_falls_through_to_deps_payload(home, monkeypatch, capsys):
    """A venv python that exists but can't actually be exec'd (bad perms,
    broken shebang, ENOENT race, partial venv) must not crash the helper —
    fall through to the normal deps payload instead."""
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    venv_py = mod._venv_python()
    venv_py.parent.mkdir(parents=True, exist_ok=True)
    venv_py.write_text("#!/bin/sh\n")

    def fake_execv(path, args):
        raise OSError(13, "Permission denied")

    monkeypatch.setattr(os, "execv", fake_execv)
    try:
        rc, out = run(mod, ["fetch"], capsys)
        assert rc == 0
        assert out["ok"] is False and out["error"] == "deps"
        assert out["hint"] == mod.DEPS_HINT
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


def test_fetch_tightens_tokens_permissions(home, fake_garmin, capsys):
    """garminconnect's Client.dump() rewrites tokens.json at the default umask
    whenever login(tokenstore=) refreshes it, so the helper re-chmods after
    every call that can touch the file."""
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    mod.TOKENS_PATH.chmod(0o644)
    mod.TOKENS_PATH.parent.chmod(0o755)  # what older installs left behind
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is True
    assert oct(mod.TOKENS_PATH.stat().st_mode & 0o777) == "0o600"
    assert oct(mod.TOKENS_PATH.parent.stat().st_mode & 0o777) == "0o700"


def test_fetch_tightens_tokens_permissions_after_failure(home, fake_garmin, capsys):
    """A refresh can rewrite the file and then fail; the chmod must still run."""
    fake_garmin.login_exc = ConnectionError("boom")
    mod = load_helper()
    _with_tokens(mod)
    mod.TOKENS_PATH.chmod(0o644)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False
    assert oct(mod.TOKENS_PATH.stat().st_mode & 0o777) == "0o600"


def test_cache_file_is_owner_only(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    run(mod, ["fetch"], capsys)
    assert oct(mod.CACHE_PATH.stat().st_mode & 0o777) == "0o600"


def test_detail_is_exception_class_name_only(home, fake_garmin, capsys):
    """str(e) can carry the account email or a home-directory path into a
    tooltip; the class name is all the user needs to tell states apart."""
    fake_garmin.login_exc = RuntimeError("bad thing for user@example.com at /home/user")
    mod = load_helper()
    _with_tokens(mod)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["error"] == "api-error"
    assert out["detail"] == "RuntimeError"


def _login_inputs(monkeypatch):
    import builtins
    import getpass
    monkeypatch.setattr(builtins, "input", lambda *a: "user@example.com")
    monkeypatch.setattr(getpass, "getpass", lambda *a, **k: "hunter2")


class TooManyRequestsError(Exception):
    pass


def test_login_rate_limit_is_api_error(home, fake_garmin, monkeypatch, capsys):
    _login_inputs(monkeypatch)
    fake_garmin.login_exc = TooManyRequestsError("429")
    mod = load_helper()
    rc, out = run(mod, ["login"], capsys)
    assert out["ok"] is False
    assert out["error"] == "api-error"
    assert out["detail"] == "TooManyRequestsError"


def test_login_connection_error_is_offline(home, fake_garmin, monkeypatch, capsys):
    _login_inputs(monkeypatch)
    fake_garmin.login_exc = ConnectionError("no route")
    mod = load_helper()
    rc, out = run(mod, ["login"], capsys)
    assert out["ok"] is False and out["error"] == "offline"
    assert out["detail"] == "ConnectionError"


def test_login_bad_credentials_still_auth_expired(home, fake_garmin, monkeypatch, capsys):
    _login_inputs(monkeypatch)
    fake_garmin.login_exc = ValueError("nope")
    mod = load_helper()
    rc, out = run(mod, ["login"], capsys)
    assert out["ok"] is False and out["error"] == "auth-expired"
    assert out["detail"] == "ValueError"


def test_config_dir_is_owner_only(home, fake_garmin, monkeypatch, capsys):
    _login_inputs(monkeypatch)
    mod = load_helper()
    rc, out = run(mod, ["login"], capsys)
    assert out["ok"] is True
    assert oct(mod.TOKENS_PATH.parent.stat().st_mode & 0o777) == "0o700"
    assert oct(mod.TOKENS_PATH.stat().st_mode & 0o777) == "0o600"


def test_unexpected_exception_still_emits_json_and_exit_zero(home, monkeypatch, capsys):
    """The JSON-always/exit-0 contract has to survive helper bugs too — an
    EOFError from a non-interactive login, an AttributeError from a library
    upgrade. A traceback on stdout would blank the bar chip."""
    mod = load_helper()

    def boom():
        raise EOFError("no stdin")

    monkeypatch.setattr(mod, "cmd_status", boom)
    rc, out = run(mod, ["status"], capsys)
    assert rc == 0
    assert out == {"ok": False, "error": "api-error", "detail": "EOFError"}


def test_reexec_not_attempted_when_garminconnect_present(home, fake_garmin, monkeypatch, capsys):
    """Existing fake_garmin-backed tests must stay green: importable
    garminconnect means no re-exec is attempted at all."""
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    assert mod.HAS_GARMINCONNECT is True
    _with_tokens(mod)
    calls = []
    monkeypatch.setattr(os, "execv", lambda *a: calls.append(a))
    rc, out = run(mod, ["fetch"], capsys)
    assert calls == []
    assert out["ok"] is True
