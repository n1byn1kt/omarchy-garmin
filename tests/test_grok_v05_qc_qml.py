"""Grok v0.5 QC fixes (grok-qc-v05.txt), QML side: #3 weight toggle and
in-flight result, #5 demo multi-monitor sync, #6 the readiness-backfill
flag, #7 Left/h on the activity list. No QML runtime in the venv, so like
test_demo_qml these are grep-shaped guards on the lines that implement each
rule; the behaviour itself is checked by hand on the box.
"""
from test_demo_qml import _body, _read


def test_weight_toggle_refreshes_from_the_primary_only():
    """#3: a weight toggle fetches now, not at the next poll."""
    handler = _body(_read("Service.qml"), "onWeightEnabledChanged:")
    assert "if (!root._started) return" in handler
    assert handler.index("root.canPoll()") < handler.index("root.refresh(false)")


def test_a_weight_result_is_dropped_once_the_card_is_off():
    apply = _body(_read("Service.qml"), "function applyPayload(")
    assert "!root.weightEnabled && payload.weight" in apply
    assert apply.index("payload.weight = null") < apply.index("root.payload = payload")


def test_a_weight_toggle_mid_fetch_queues_a_refresh():
    src = _read("Service.qml")
    refresh = _body(src, "function refresh(week)")
    assert "root._runWeight !== root.weightEnabled" in refresh
    assert "root._runWeight = root.weightEnabled" in refresh
    exited = src[src.index("id: fetchProcess"):src.index("id: watchdog")]
    assert exited.rindex("root._finishStaleRun()") > exited.index("root.applyPayload(")


def test_readiness_backfill_flag_follows_the_deck():
    """#6: the flag is only sent when the readiness card is off, and an
    empty deck (the built-in default) counts as on."""
    src = _read("Service.qml")
    enabled = _body(src, "readonly property bool readinessEnabled:")
    assert enabled.index('=== "") return true') < enabled.index('"readiness"')
    refresh = _body(src, "function refresh(week)")
    assert '!root.readinessEnabled) cmd.push("--no-readiness-backfill")' in refresh


def test_adopt_mismatch_drops_the_local_payload_and_stays_silent():
    """#5: the other world's payload is refused *and* this screen's goes;
    adopt must never emit (publish -> adopt -> emit would loop the bar)."""
    adopt = _body(_read("Service.qml"), "function adopt(")
    mismatch = adopt[adopt.index("isDemo !== root.demoMode"):adopt.index("return")]
    assert "root.payload = null" in mismatch
    for signal in ("refreshed()", "syncWanted()", "customUpdated()"):
        assert signal not in adopt, signal


def test_demo_toggle_and_peer_startup_ask_the_primary_to_publish():
    """#5: in demo no poll ever publishes again, so a screen that flipped
    late or came up late pulls the primary's state."""
    src = _read("Service.qml")
    assert "root.syncWanted()" in _body(src, "onDemoModeChanged:")
    startup = src[src.index("id: startupTimer"):]
    assert "if (!primary) root.syncWanted()" in startup
    bw = _read("BarWidget.qml")
    assert "onSyncWanted: root.syncFromPrimary()" in bw
    sync = _body(bw, "function syncFromPrimary()")
    assert "items[0]" in sync and "primary.publish()" in sync


def test_left_on_the_activity_list_steps_back_to_the_deck():
    """#7: ←/h on the list (no activity open) takes Escape's step."""
    moves = _body(_read("Panel.qml"), "onMoveRequested:")
    branch = moves[moves.index("else if (root.activityPage)"):moves.index("else if (root.editMode)")]
    assert "else if (dx < 0) root.closeDetail()" in branch
