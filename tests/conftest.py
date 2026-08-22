import importlib.machinery
import importlib.util
import os
import sys
import pathlib
import pytest

HELPER = pathlib.Path(__file__).resolve().parent.parent / "plugin" / "bin" / "garmin-widget"


def load_helper():
    """Import the extensionless helper script as a module (fresh each call)."""
    spec = importlib.util.spec_from_loader(
        "garmin_widget", importlib.machinery.SourceFileLoader("garmin_widget", str(HELPER))
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path
