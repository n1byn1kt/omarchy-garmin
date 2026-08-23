import importlib.machinery
import importlib.util
import os
import sys
import types
import pathlib
import pytest

HELPER = pathlib.Path(__file__).resolve().parent.parent / "bin" / "garmin-widget"


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


class FakeGarmin:
    """Stands in for garminconnect.Garmin; behavior injected per-test."""
    summary = {}
    sleep = {}
    login_exc = None

    def __init__(self, *a, **kw):
        pass

    def login(self, tokenstore=None):
        if FakeGarmin.login_exc:
            raise FakeGarmin.login_exc
        return ("oauth1", "oauth2")

    def get_user_summary(self, cdate):
        return FakeGarmin.summary

    def get_sleep_data(self, cdate):
        return FakeGarmin.sleep


class AuthError(Exception):
    pass


@pytest.fixture
def fake_garmin(monkeypatch):
    fake = types.ModuleType("garminconnect")
    fake.Garmin = FakeGarmin
    fake.GarminConnectAuthenticationError = AuthError
    FakeGarmin.summary, FakeGarmin.sleep, FakeGarmin.login_exc = {}, {}, None
    monkeypatch.setitem(sys.modules, "garminconnect", fake)
    return FakeGarmin
