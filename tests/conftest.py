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


class FakeClient:
    """Stands in for garminconnect's inner Client.

    dump() deliberately writes at the ambient umask, exactly as the real one
    does — that is the whole reason the helper re-chmods afterwards.
    """

    def dump(self, path):
        p = pathlib.Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('{"oauth1": "x"}')
        p.chmod(0o644)


class FakeGarmin:
    """Stands in for garminconnect.Garmin; behavior injected per-test.

    The secondary endpoints default to None (the shape garminconnect returns
    for a day with no such data), so tests written before they existed still
    exercise the "every extra key nulls out" path.
    """
    summary = {}
    sleep = {}
    login_exc = None
    body_battery = None
    stress = None
    hrv = None
    readiness = None
    intensity = None
    last_activity = None
    exc = {}          # method name -> exception to raise

    def __init__(self, *a, **kw):
        self.client = FakeClient()

    def _maybe_raise(self, name):
        e = FakeGarmin.exc.get(name)
        if e:
            raise e

    def login(self, tokenstore=None):
        if FakeGarmin.login_exc:
            raise FakeGarmin.login_exc
        return ("oauth1", "oauth2")

    def get_user_summary(self, cdate):
        self._maybe_raise("get_user_summary")
        return FakeGarmin.summary

    def get_sleep_data(self, cdate):
        self._maybe_raise("get_sleep_data")
        return FakeGarmin.sleep

    def get_body_battery(self, cdate, *a):
        self._maybe_raise("get_body_battery")
        return FakeGarmin.body_battery

    def get_stress_data(self, cdate):
        self._maybe_raise("get_stress_data")
        return FakeGarmin.stress

    def get_hrv_data(self, cdate):
        self._maybe_raise("get_hrv_data")
        return FakeGarmin.hrv

    def get_training_readiness(self, cdate):
        self._maybe_raise("get_training_readiness")
        return FakeGarmin.readiness

    def get_intensity_minutes_data(self, cdate):
        self._maybe_raise("get_intensity_minutes_data")
        return FakeGarmin.intensity

    def get_last_activity(self):
        self._maybe_raise("get_last_activity")
        return FakeGarmin.last_activity


class AuthError(Exception):
    pass


@pytest.fixture
def fake_garmin(monkeypatch):
    fake = types.ModuleType("garminconnect")
    fake.Garmin = FakeGarmin
    fake.GarminConnectAuthenticationError = AuthError
    FakeGarmin.summary, FakeGarmin.sleep, FakeGarmin.login_exc = {}, {}, None
    FakeGarmin.body_battery = None
    FakeGarmin.stress = None
    FakeGarmin.hrv = None
    FakeGarmin.readiness = None
    FakeGarmin.intensity = None
    FakeGarmin.last_activity = None
    FakeGarmin.exc = {}
    monkeypatch.setitem(sys.modules, "garminconnect", fake)
    return FakeGarmin
