import importlib.machinery
import importlib.util
import os
import sys
import types
import pathlib
import datetime
import pytest


def _today():
    return datetime.date.today().isoformat()

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
    # Past-day responses for the one-time backfill, keyed by ISO date. A date
    # with no entry answers {} — what Garmin returns for a day it has nothing
    # for — so backfill tests have to opt into every day they expect filled.
    summary_by_date = {}
    sleep_by_date = {}
    daily_steps = None
    # Ranged (week) endpoints. None means "the source answered with nothing".
    rhr_daily = None
    sleep_daily = None
    hrv_range = None
    calories_daily = None
    body_battery_range = None
    stress_daily = None   # what connectapi() answers for the stress path
    calls = []        # every API method call, in order, for budget assertions
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

    def _maybe_raise(self, name, *args):
        FakeGarmin.calls.append((name, args))
        e = FakeGarmin.exc.get(name)
        if e:
            raise e

    def login(self, tokenstore=None):
        if FakeGarmin.login_exc:
            raise FakeGarmin.login_exc
        return ("oauth1", "oauth2")

    def get_user_summary(self, cdate):
        self._maybe_raise("get_user_summary", cdate)
        if cdate == _today():
            return FakeGarmin.summary
        return FakeGarmin.summary_by_date.get(cdate, {})

    def get_sleep_data(self, cdate):
        self._maybe_raise("get_sleep_data", cdate)
        if cdate == _today():
            return FakeGarmin.sleep
        return FakeGarmin.sleep_by_date.get(cdate, {})

    def get_daily_steps(self, start, end):
        self._maybe_raise("get_daily_steps", start, end)
        return FakeGarmin.daily_steps

    def get_body_battery(self, cdate, *a):
        self._maybe_raise("get_body_battery", cdate, *a)
        return FakeGarmin.body_battery_range if a else FakeGarmin.body_battery

    def get_rhr_daily(self, start, end):
        self._maybe_raise("get_rhr_daily", start, end)
        return FakeGarmin.rhr_daily

    def get_sleep_daily(self, start, end):
        self._maybe_raise("get_sleep_daily", start, end)
        return FakeGarmin.sleep_daily

    def get_hrv_data_range(self, start, end):
        self._maybe_raise("get_hrv_data_range", start, end)
        return FakeGarmin.hrv_range

    def get_calories_daily(self, start, end):
        self._maybe_raise("get_calories_daily", start, end)
        return FakeGarmin.calories_daily

    def connectapi(self, path, **kw):
        self._maybe_raise("connectapi", path)
        if "/stats/stress/daily/" in path:
            return FakeGarmin.stress_daily
        return None

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
    FakeGarmin.summary_by_date = {}
    FakeGarmin.sleep_by_date = {}
    FakeGarmin.daily_steps = None
    FakeGarmin.rhr_daily = None
    FakeGarmin.sleep_daily = None
    FakeGarmin.hrv_range = None
    FakeGarmin.calories_daily = None
    FakeGarmin.body_battery_range = None
    FakeGarmin.stress_daily = None
    FakeGarmin.calls = []
    FakeGarmin.exc = {}
    monkeypatch.setitem(sys.modules, "garminconnect", fake)
    return FakeGarmin
