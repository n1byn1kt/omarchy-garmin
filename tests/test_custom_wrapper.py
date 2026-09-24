"""The custom-card wrapper in Service.qml, run for real.

The wrapper is extracted from the QML source rather than copied, so these
tests fail if the shipped string changes shape. Timeouts are shortened by
rewriting the literal `9` so the suite stays fast.
"""
import re
import subprocess
import time
from pathlib import Path

SERVICE = Path(__file__).resolve().parent.parent / "Service.qml"


def _wrapper(seconds=9):
    src = SERVICE.read_text()
    m = re.search(r'customProcess\.command = \["bash", "-c",\s*"((?:[^"\\]|\\.)*)"', src)
    assert m, "custom wrapper not found in Service.qml"
    script = m.group(1).encode().decode("unicode_escape")
    assert "timeout -k 1 9 " in script
    return script.replace("timeout -k 1 9 ", f"timeout -k 1 {seconds} ")


def _run(cmd, seconds=9):
    return subprocess.run(["bash", "-c", _wrapper(seconds), "garmin-custom", cmd],
                          capture_output=True, text=True, timeout=30)


def test_good_card_exits_zero():
    r = _run('echo \'{"title":"a","value":"1"}\'')
    assert r.returncode == 0
    assert r.stdout.strip() == '{"title":"a","value":"1"}'


def test_own_nonzero_exit_is_masked():
    r = _run('echo \'{"title":"a","value":"1"}\'; exit 3')
    assert r.returncode == 0


def test_command_exiting_124_keeps_its_output():
    # Indistinguishable from a timeout by code alone; Service.qml keeps the
    # output as the verdict, so it must arrive intact.
    r = _run('echo \'{"title":"a","value":"1"}\'; exit 124')
    assert r.returncode == 124
    assert '"title":"a"' in r.stdout


def test_hang_is_124_with_no_output_and_kills_the_tree(tmp_path):
    marker = tmp_path / "survived"
    start = time.monotonic()
    r = _run(f'(sleep 3; touch {marker}) & sleep 30', seconds=1)
    assert r.returncode == 124
    assert r.stdout == ""
    assert time.monotonic() - start < 5
    time.sleep(3)
    assert not marker.exists(), "a backgrounded child outlived the timeout"


def test_output_is_capped():
    r = _run("head -c 20000 /dev/zero | tr '\\0' x")
    assert len(r.stdout) == 8193
