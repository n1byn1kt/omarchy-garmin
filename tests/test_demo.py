"""`garmin-widget demo` (v0.5 plan step 7): synthetic data through the real
builders, deterministic per calendar day, and nothing read or written.

The demo exists for a box with no account and no venv, and for screenshots —
so the tests below pin both halves of that: every card has something to
draw, and the user's own cache/config never enter into it.
"""
import datetime
import hashlib
import json
import os
import random
import sys

import fixtures
from conftest import load_helper
from test_helper import SLEEP, SUMMARY, _with_tokens, run
from test_payload_v2 import _all_endpoints


def _demo(mod, capsys, *args):
    rc, out = run(mod, ["demo", *args], capsys)
    assert rc == 0
    return out


def _raw_demo(mod, capsys, *args):
    assert mod.main(["demo", *args]) == 0
    return capsys.readouterr().out


def _walk_strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield k
            yield from _walk_strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from _walk_strings(x)


# --- shape: every card has something to draw -------------------------------

def test_demo_is_marked_and_ok(home, capsys):
    out = _demo(load_helper(), capsys)
    assert out["ok"] is True and out["stale"] is False
    assert out["demo"] is True
    assert out["asOf"] == "demo"
    assert out["carried"] == []


def test_every_card_key_is_filled(home, capsys):
    out = _demo(load_helper(), capsys)
    for key in ("bodyBattery", "sleep", "steps", "restingHr", "curve",
                "hrvStatus", "readiness", "intensityMinutes", "floors",
                "calories", "activities", "lastActivity"):
        assert out[key] not in (None, [], {}), key
    for group in ("bodyBattery", "sleep", "steps", "hrvStatus", "readiness",
                  "intensityMinutes", "floors", "calories"):
        assert all(v is not None for v in out[group].values()), group
    assert out["bodyBattery"] == {"current": 41, "high": 88, "low": 34}
    assert out["steps"] == {"count": 7480, "goal": 9000}


def test_curve_is_a_full_day_and_drops_the_off_wrist_sentinels(home, capsys):
    curve = _demo(load_helper(), capsys)["curve"]
    bb, stress = curve["bodyBattery"], curve["stress"]
    assert len(bb) == 96
    assert 0 < len(stress) <= 96
    assert all(v >= 0 for _, v in stress)
    assert bb[0][1] == 34 and bb[-1][1] == 41
    assert max(v for _, v in bb) == 88 and min(v for _, v in bb) == 34
    # The raw stress series really does carry -1s: the builder dropped them.
    today = datetime.date.today()
    _, raw_stress = load_helper()._demo_curves(today, random.Random(0))
    assert any(v == -1 for _, v in raw_stress)
    # Timestamps are today's, ending on the synthetic clock.
    end = datetime.datetime.fromtimestamp(bb[-1][0] / 1000)
    assert end.date() == today and end.strftime("%H:%M") <= "18:40"


def test_history_is_seven_full_rows_ending_today(home, capsys):
    mod = load_helper()
    rows = _demo(mod, capsys)["history"]
    assert [r["date"] for r in rows] == [fixtures.day(b) for b in range(6, -1, -1)]
    for r in rows:
        for f in mod.HISTORY_FIELDS:
            assert r[f] is not None, (r["date"], f)
        # Stages sum to the night's total, as Garmin's own do.
        assert r["deepMin"] + r["lightMin"] + r["remMin"] == r["sleepMin"]


def test_activities_are_ten_invented_rows_of_mixed_types(home, capsys):
    mod = load_helper()
    out = _demo(mod, capsys)
    acts = out["activities"]
    assert len(acts) == mod.ACTIVITY_ROWS == 10
    assert out["lastActivity"] == acts[0]
    starts = [a["start"] for a in acts]
    assert starts == sorted(starts, reverse=True)
    types = " ".join(a["type"] for a in acts)
    for family in ("run", "bik", "hik", "strength", "swim"):
        assert family in types, family
    for a in acts:
        for k in ("id", "type", "name", "start", "durationMin", "avgHr", "maxHr", "kcal"):
            assert a[k] is not None, (a["name"], k)
        assert a["id"].isdigit() and a["id"].startswith("9000")
    assert len({a["id"] for a in acts}) == 10


def test_weight_follows_the_same_flag_as_fetch(home, capsys):
    mod = load_helper()
    assert _demo(mod, capsys)["weight"] is None
    w = _demo(mod, capsys, "--weight")["weight"]
    assert w["unit"] == "kg" and w["current"] is not None and w["delta"] is not None
    assert len(w["series"]) >= 10
    assert w["date"] == fixtures.day(0)


def test_every_string_fits_the_label_budget(home, capsys):
    mod = load_helper()
    for s in _walk_strings(_demo(mod, capsys, "--weight")):
        assert len(s) < mod.STR_CLIP, s


# --- deterministic ----------------------------------------------------------

def test_byte_identical_across_runs_and_homes(home, tmp_path_factory, monkeypatch, capsys):
    first = _raw_demo(load_helper(), capsys)
    assert _raw_demo(load_helper(), capsys) == first
    other = tmp_path_factory.mktemp("other-home")
    monkeypatch.setenv("HOME", str(other))
    assert _raw_demo(load_helper(), capsys) == first


# --- nothing read, nothing written -------------------------------------------

def test_demo_writes_nothing(home, capsys):
    _demo(load_helper(), capsys, "--weight")
    assert not (home / ".cache" / "garmin-widget").exists()
    assert not (home / ".config" / "garmin-widget").exists()
    assert not (home / ".local").exists()


def test_demo_ignores_and_leaves_a_real_cache_alone(home, fake_garmin, capsys):
    # A real install: tokens, a cached payload, history. The demo must not
    # read any of it (its numbers stay out) or touch it (bytes and mtime).
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _with_tokens(mod)
    run(mod, ["fetch"], capsys)
    files = [mod.CACHE_PATH, mod.HISTORY_PATH, mod.TOKENS_PATH]
    before = {p: (p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest())
              for p in files}
    out = _demo(load_helper(), capsys)
    after = {p: (p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest())
             for p in files}
    assert before == after
    assert out["bodyBattery"]["current"] != SUMMARY["bodyBatteryMostRecentValue"]
    assert out["readiness"]["score"] != fixtures.READINESS[0]["score"]
    assert all(a["id"].startswith("9000") for a in out["activities"])


def test_demo_needs_no_deps_no_tokens_and_never_reexecs(home, monkeypatch, capsys):
    mod = load_helper()
    monkeypatch.setattr(mod, "HAS_GARMINCONNECT", False)
    monkeypatch.delenv("GARMIN_WIDGET_REEXEC", raising=False)
    # A real, trusted interpreter at the venv path — the case where fetch
    # *would* re-exec — so "not called" means demo skipped it, not that the
    # trust check refused a fake.
    venv_py = mod._venv_python()
    venv_py.parent.mkdir(parents=True)
    os.symlink(os.path.realpath(sys.executable), venv_py)
    assert mod._trusted_interpreter(venv_py)
    calls = []
    monkeypatch.setattr(os, "execv", lambda *a: calls.append(a))
    try:
        out = _demo(mod, capsys)
        assert out["ok"] is True and out["demo"] is True
        assert calls == []
        mod.main(["fetch"])            # control: fetch does re-exec here
        capsys.readouterr()
        assert len(calls) == 1
    finally:
        os.environ.pop("GARMIN_WIDGET_REEXEC", None)


# --- a live payload is never demo, and a demo cache is never served ----------

def test_live_payload_has_no_demo_key(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    assert "demo" not in mod.build_payload(SUMMARY, SLEEP, "2026-01-01T00:00")
    _with_tokens(mod)
    _, out = run(mod, ["fetch"], capsys)
    assert "demo" not in out


def _seed_demo_cache(mod, capsys):
    """last.json holding a demo payload — which cmd_demo never writes, so
    this is the hand-planted (or buggy) case amendment 2 is about."""
    demo = _demo(mod, capsys, "--weight")
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(json.dumps(demo))
    return demo


def test_demo_cache_is_never_served_as_stale(home, fake_garmin, capsys):
    mod = load_helper()
    _seed_demo_cache(mod, capsys)
    assert mod._load_cache() is None
    _with_tokens(mod)
    fake_garmin.exc = {"get_user_summary": ConnectionError("down")}
    _, out = run(mod, ["fetch"], capsys)
    assert out["ok"] is False and out["error"] == "offline"
    assert "demo" not in out


def test_demo_cache_is_never_carried_or_rewritten(home, fake_garmin, capsys):
    _all_endpoints(fake_garmin)
    mod = load_helper()
    _seed_demo_cache(mod, capsys)
    _with_tokens(mod)
    fake_garmin.exc = {"get_activities": RuntimeError("boom"),
                       "get_hrv_data": RuntimeError("boom"),
                       "get_weigh_ins": RuntimeError("boom")}
    _, out = run(mod, ["fetch", "--weight"], capsys)
    assert set(out["carried"]) == {"activities", "hrvStatus", "weight"}
    # Carried from nothing: the demo cache was refused, so each is empty.
    assert out["activities"] == [] and out["lastActivity"] is None
    assert out["hrvStatus"] is None and out["weight"] is None
    assert "demo" not in out
    written = json.loads(mod.CACHE_PATH.read_text())
    assert "demo" not in written
    assert not any(a and a.get("id", "").startswith("9000")
                   for a in written.get("activities") or [])


def test_a_non_true_demo_flag_is_stripped_not_trusted(home, capsys):
    mod = load_helper()
    mod.CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    mod.CACHE_PATH.write_text(json.dumps({"ok": True, "demo": "yes",
                                          "bodyBattery": {"current": 50}}))
    cached = mod._load_cache()
    assert cached is not None and "demo" not in cached
