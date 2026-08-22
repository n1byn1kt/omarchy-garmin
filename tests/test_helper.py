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
