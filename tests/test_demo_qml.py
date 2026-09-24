"""Demo mode on the QML side (v0.5 plan step 8), pinned statically.

There is no QML runtime in the test venv, so these are grep-shaped guards,
like test_every_qml_text_element_is_plaintext: each names one rule from the
plan's QC amendments and fails if the line that implements it goes away.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _read(name):
    return (ROOT / name).read_text()


def _body(src, header):
    """The brace-balanced block that follows `header` (first occurrence)."""
    start = src.index(header)
    i = src.index("{", start)
    depth = 0
    for j in range(i, len(src)):
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        if depth == 0:
            return src[i:j + 1]
    raise AssertionError("unbalanced: " + header)


def test_manifest_declares_demo_mode_off_by_default():
    bw = json.loads(_read("manifest.json"))["barWidget"]
    assert bw["defaults"]["demoMode"] is False
    entry = [e for e in bw["schema"] if e["key"] == "demoMode"]
    assert len(entry) == 1
    assert entry[0]["type"] == "boolean" and entry[0]["defaultValue"] is False
    assert entry[0]["description"]


def test_service_runs_the_demo_subcommand_and_stops_polling():
    src = _read("Service.qml")
    refresh = _body(src, "function refresh(week)")
    assert '[root.helperPath, "demo"]' in refresh
    assert "root._runGen = root._fetchGen" in refresh
    assert re.search(r"running:\s*!root\.demoMode", src)


def test_toggle_is_guarded_by_started_and_bumps_the_generation():
    src = _read("Service.qml")
    toggle = _body(src, "onDemoModeChanged:")
    assert toggle.index("if (!root._started) return") < toggle.index("root._fetchGen++")
    for reset in ("root.payload = null", 'root.state = "loading"', "root.customCard = null"):
        assert reset in toggle


def test_a_stale_generation_is_dropped_before_it_is_applied():
    src = _read("Service.qml")
    exited = src[src.index("id: fetchProcess"):src.index("id: watchdog")]
    assert exited.index("root._runGen !== root._fetchGen") < exited.index("root.applyPayload(")


def test_adopt_refuses_the_other_worlds_payload_and_custom_card():
    adopt = _body(_read("Service.qml"), "function adopt(")
    assert "isDemo !== root.demoMode" in adopt
    assert adopt.index("isDemo !== root.demoMode") < adopt.index("root.payload = payload")
    assert "root.customCard = null" in adopt


def test_custom_command_never_runs_in_demo():
    run_custom = _body(_read("Service.qml"), "function runCustom()")
    first_if = run_custom[:run_custom.index("return")]
    assert "root.demoMode" in first_if


def test_demo_is_honoured_from_the_primary_only():
    src = _read("BarWidget.qml")
    sync = _body(src, "function syncDemoMode()")
    assert "root.peers()" in sync and "items[0]" in sync
    assert 'root.broadcast("syncDemoMode")' in src


def test_chip_and_tooltip_are_marked():
    src = _read("BarWidget.qml")
    assert 't += " demo"' in _body(src, "readonly property string displayText:")
    assert "DEMO DATA — synthetic, not from your account" in src


def test_panel_marks_demo_and_hides_the_connect_link():
    src = _read("Panel.qml")
    assert "Demo data — synthetic, not from your account" in src
    assert "demoMode false --json" in src
    connect = _body(src, "function openInConnect(id)")
    assert "root.payloadDemo" in connect
    assert re.search(r'"linkable": typeof a\.id === "string".*&& !root\.payloadDemo', src)
