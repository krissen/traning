"""Tests for the receiver's debounce persistence/resume and the
_flush_pending_workouts decrement-race fix (server/app.py).

The app module is fetched via importlib rather than a plain
``import traning_cli.server.app`` because ``traning_cli/server/__init__.py``
intentionally shadows the ``app`` submodule attribute with the FastAPI
instance it builds (``app = create_app()``, for ASGI-target use as
``traning_cli.server:app``). Going through sys.modules directly sidesteps
that and gets the actual module object with the debounce internals.
"""

import importlib

import pytest
from traning_cli.server import state

app_mod = importlib.import_module("traning_cli.server.app")


@pytest.fixture(autouse=True)
def _reset_debounce_globals(monkeypatch):
    """Every test starts from a known-empty debounce state and any timers
    armed during the test are cancelled afterwards so they can't fire in
    the background during later tests."""
    monkeypatch.setattr(app_mod, "_pending_files", set())
    monkeypatch.setattr(app_mod, "_pending_timer", None)
    monkeypatch.setattr(app_mod, "_pending_workouts_count", 0)
    monkeypatch.setattr(app_mod, "_workouts_timer", None)
    monkeypatch.setattr(app_mod, "_workouts_flushing", False)
    yield
    if app_mod._pending_timer is not None:
        app_mod._pending_timer.cancel()
    if app_mod._workouts_timer is not None:
        app_mod._workouts_timer.cancel()


# --- _decrement_after_flush (pure function) ---------------------------------


def test_decrement_after_flush_success_subtracts_snapshot():
    assert app_mod._decrement_after_flush(5, 5, ok=True) == 0


def test_decrement_after_flush_failure_keeps_current_untouched():
    assert app_mod._decrement_after_flush(8, 5, ok=False) == 8


def test_decrement_after_flush_preserves_concurrent_arrivals():
    # count=5 snapshotted at flush start; 3 more pushes arrive while the
    # (up to 300s) import runs, bumping the live counter to 8. Only the
    # snapshot (5) may be subtracted so the 3 new arrivals survive.
    live_count_during_import = 5 + 3
    result = app_mod._decrement_after_flush(live_count_during_import, 5, ok=True)
    assert result == 3


def test_decrement_after_flush_never_goes_negative():
    assert app_mod._decrement_after_flush(2, 5, ok=True) == 0


# --- _flush_pending_workouts: end-to-end decrement race ---------------------


def test_flush_pending_workouts_decrements_snapshot_not_live_count(
    traning_data_dir, monkeypatch
):
    app_mod._pending_workouts_count = 5

    class FakeResult:
        returncode = 0
        stdout = "Import: 1 pass klart"
        stderr = ""

    def fake_run(*args, **kwargs):
        # New workouts pushed mid-flight, before the flush decrements —
        # this is exactly the race the snapshot-based decrement guards.
        app_mod._pending_workouts_count += 3
        return FakeResult()

    monkeypatch.setattr(app_mod.subprocess, "run", fake_run)

    app_mod._flush_pending_workouts()

    assert app_mod._pending_workouts_count == 3
    assert app_mod._workouts_flushing is False


def test_flush_pending_workouts_failure_keeps_full_batch_pending(
    traning_data_dir, monkeypatch
):
    app_mod._pending_workouts_count = 5

    class FailingResult:
        returncode = 1
        stdout = ""
        stderr = "boom"

    monkeypatch.setattr(app_mod.subprocess, "run", lambda *a, **kw: FailingResult())

    app_mod._flush_pending_workouts()

    assert app_mod._pending_workouts_count == 5
    assert app_mod._workouts_flushing is False


def test_flush_pending_workouts_skips_when_already_in_progress(monkeypatch):
    app_mod._pending_workouts_count = 5
    app_mod._workouts_flushing = True

    def fail_if_called(*a, **kw):
        raise AssertionError("subprocess.run must not run while a flush is in progress")

    monkeypatch.setattr(app_mod.subprocess, "run", fail_if_called)

    app_mod._flush_pending_workouts()

    assert app_mod._pending_workouts_count == 5


def test_flush_pending_workouts_skip_rearms_timer(monkeypatch):
    """A flush skipped because one is already in progress must not strand
    the leftover pending count — it re-arms its own retry timer instead of
    only waiting for the next workout push."""
    app_mod._pending_workouts_count = 5
    app_mod._workouts_flushing = True
    app_mod._workouts_timer = None

    def fail_if_called(*a, **kw):
        raise AssertionError("subprocess.run must not run while a flush is in progress")

    monkeypatch.setattr(app_mod.subprocess, "run", fail_if_called)

    app_mod._flush_pending_workouts()

    assert app_mod._workouts_timer is not None
    assert app_mod._workouts_timer.is_alive()
    assert app_mod._pending_workouts_count == 5


def test_flush_pending_workouts_noop_when_nothing_pending(monkeypatch):
    app_mod._pending_workouts_count = 0

    def fail_if_called(*a, **kw):
        raise AssertionError("subprocess.run must not run with nothing pending")

    monkeypatch.setattr(app_mod.subprocess, "run", fail_if_called)

    app_mod._flush_pending_workouts()

    assert app_mod._workouts_flushing is False


def test_flush_pending_workouts_resets_guard_when_persist_raises(
    traning_data_dir, monkeypatch
):
    # Regression test: an unhandled exception anywhere in the flush body
    # (not just a subprocess failure, which is already caught internally)
    # must still clear _workouts_flushing via the try/finally — otherwise
    # the guard sticks forever and every future flush silently
    # early-returns, permanently stopping workout imports until restart.
    app_mod._pending_workouts_count = 5

    real_save_pending_state = app_mod.save_pending_state
    calls = {"n": 0}

    def flaky_save_pending_state(payload):
        calls["n"] += 1
        if calls["n"] == 1:
            # Simulate the disk-full/rename-error case the coordinator
            # flagged: _persist_pending_state's first call (before the
            # subprocess even runs) raises.
            raise OSError("disk full")
        return real_save_pending_state(payload)

    monkeypatch.setattr(app_mod, "save_pending_state", flaky_save_pending_state)

    def fail_if_called(*a, **kw):
        raise AssertionError(
            "subprocess.run must not run once _persist_pending_state already raised"
        )

    monkeypatch.setattr(app_mod.subprocess, "run", fail_if_called)

    with pytest.raises(OSError):
        app_mod._flush_pending_workouts()

    # Guard cleared and the snapshot left un-decremented despite the
    # exception, so the whole batch retries on the next push.
    assert app_mod._workouts_flushing is False
    assert app_mod._pending_workouts_count == 5
    # The finally block's own persist call (the 2nd, non-raising one)
    # should have gone through and reflect the un-decremented count.
    assert calls["n"] == 2
    assert state.load_pending_state()["pending_workouts_count"] == 5


def test_flush_pending_workouts_can_flush_again_after_a_raising_attempt(
    traning_data_dir, monkeypatch
):
    # Follow-up to the guard-reset test above: once the guard has been
    # correctly reset, a subsequent flush must be able to proceed and
    # succeed normally (i.e. the guard isn't stuck).
    app_mod._pending_workouts_count = 5

    def raise_once(payload, _state={"raised": False}):
        if not _state["raised"]:
            _state["raised"] = True
            raise OSError("disk full")
        return state.save_pending_state(payload)

    monkeypatch.setattr(app_mod, "save_pending_state", raise_once)
    monkeypatch.setattr(app_mod.subprocess, "run", lambda *a, **kw: None)

    with pytest.raises(OSError):
        app_mod._flush_pending_workouts()
    assert app_mod._workouts_flushing is False

    class OkResult:
        returncode = 0
        stdout = "Import: 1 pass klart"
        stderr = ""

    monkeypatch.setattr(app_mod.subprocess, "run", lambda *a, **kw: OkResult())

    app_mod._flush_pending_workouts()

    assert app_mod._workouts_flushing is False
    assert app_mod._pending_workouts_count == 0


# --- Persistence + resume across a simulated restart ------------------------


def test_persist_pending_state_writes_current_globals(traning_data_dir):
    app_mod._pending_files = {"b.json", "a.json"}
    app_mod._pending_workouts_count = 4

    app_mod._persist_pending_state()

    assert state.load_pending_state() == {
        "pending_files": ["a.json", "b.json"],
        "pending_workouts_count": 4,
    }


def test_schedule_health_import_persists_pending_files(traning_data_dir):
    app_mod._schedule_health_import(["/tmp/x.json", "/tmp/y.json"])

    persisted = state.load_pending_state()
    assert sorted(persisted["pending_files"]) == ["/tmp/x.json", "/tmp/y.json"]
    assert app_mod._pending_timer is not None


def test_schedule_workouts_import_persists_count(traning_data_dir):
    app_mod._schedule_workouts_import(3)

    assert state.load_pending_state()["pending_workouts_count"] == 3
    assert app_mod._workouts_timer is not None


def test_resume_pending_state_reloads_and_rearms_timers(traning_data_dir):
    state.save_pending_state(
        {"pending_files": ["x.json"], "pending_workouts_count": 2}
    )

    app_mod._resume_pending_state()

    assert app_mod._pending_files == {"x.json"}
    assert app_mod._pending_timer is not None
    assert app_mod._pending_workouts_count == 2
    assert app_mod._workouts_timer is not None


def test_resume_pending_state_no_persisted_file_is_noop(traning_data_dir):
    app_mod._resume_pending_state()

    assert app_mod._pending_files == set()
    assert app_mod._pending_timer is None
    assert app_mod._pending_workouts_count == 0
    assert app_mod._workouts_timer is None
