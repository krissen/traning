"""Tests for the Garmin partial-download completeness contract
(garmin/download.py).

A partial download (summary saved, but details and/or TCX failing) must
NOT be treated as complete: get_existing_activity_ids() dedups purely on
the presence of a "*_summary.json" file, so a summary left behind after a
failed TCX download would make the activity look "already fetched"
forever and it would never be retried.
"""

import pytest
from traning_cli.garmin import download as dl

ACTIVITY = {
    "activityId": 123,
    "activityName": "Morning Run",
    "startTimeGMT": "2023-11-18 19:48:49",
}


class FakeGarminClient:
    def __init__(self, fail_details=False, fail_tcx=False):
        self.fail_details = fail_details
        self.fail_tcx = fail_tcx

    def get_activity(self, activity_id):
        if self.fail_details:
            raise RuntimeError("boom details")
        return {"activityId": activity_id, "detail": True}

    def download_activity(self, activity_id):
        if self.fail_tcx:
            raise RuntimeError("boom tcx")
        return b"<TrainingCenterDatabase/>"


@pytest.fixture
def gc_tc_dirs(tmp_path):
    gc_dir = tmp_path / "gconnect"
    tc_dir = tmp_path / "tcx"
    gc_dir.mkdir()
    tc_dir.mkdir()
    return gc_dir, tc_dir


@pytest.fixture
def data_dir(tmp_path):
    """A TRANING_DATA-style root with the gconnect/tcx subtree fetch_new_activities expects."""
    (tmp_path / "kristian" / "filer" / "gconnect").mkdir(parents=True)
    (tmp_path / "kristian" / "filer" / "tcx").mkdir(parents=True)
    return tmp_path


# --- _download_activity: completeness contract ------------------------------


def test_download_activity_success_returns_true_and_writes_all_artifacts(gc_tc_dirs):
    gc_dir, tc_dir = gc_tc_dirs
    client = FakeGarminClient()

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is True
    names = sorted(p.name for p in gc_dir.iterdir())
    assert any(n.endswith("_summary.json") for n in names)
    assert any(n.endswith("_details.json") for n in names)
    assert any(n.endswith(".tcx") for n in names)
    assert list(tc_dir.iterdir()), "expected a symlink to be created in tcx/"


def test_download_activity_tcx_failure_returns_false_and_removes_summary(gc_tc_dirs):
    gc_dir, tc_dir = gc_tc_dirs
    client = FakeGarminClient(fail_tcx=True)

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is False
    assert list(gc_dir.glob("*_summary.json")) == []


def test_download_activity_details_failure_returns_false_and_removes_summary(gc_tc_dirs):
    gc_dir, tc_dir = gc_tc_dirs
    client = FakeGarminClient(fail_details=True)

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is False
    assert list(gc_dir.glob("*_summary.json")) == []


def test_download_activity_both_fail_returns_false_and_removes_summary(gc_tc_dirs):
    gc_dir, tc_dir = gc_tc_dirs
    client = FakeGarminClient(fail_details=True, fail_tcx=True)

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is False
    assert list(gc_dir.glob("*_summary.json")) == []


def test_incomplete_download_is_invisible_to_dedup_scan(gc_tc_dirs):
    gc_dir, tc_dir = gc_tc_dirs
    client = FakeGarminClient(fail_tcx=True)

    dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert dl.get_existing_activity_ids(gc_dir) == set()


def test_complete_download_is_visible_to_dedup_scan(gc_tc_dirs):
    gc_dir, tc_dir = gc_tc_dirs
    client = FakeGarminClient()

    dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert dl.get_existing_activity_ids(gc_dir) == {123}


# --- fetch_new_activities: not counted, retried next run --------------------


def test_fetch_new_activities_does_not_count_incomplete_download(data_dir, monkeypatch):
    monkeypatch.setattr(dl.time, "sleep", lambda *_: None)

    class AlwaysFailsTcxClient:
        def get_activities(self, start, limit):
            return [dict(ACTIVITY)] if start == 0 else []

        def get_activity(self, activity_id):
            return {"activityId": activity_id}

        def download_activity(self, activity_id):
            raise RuntimeError("boom tcx")

    n = dl.fetch_new_activities(AlwaysFailsTcxClient(), data_dir, limit=10)

    assert n == 0
    gc_dir = dl.gconnect_dir(data_dir)
    assert list(gc_dir.glob("*_summary.json")) == []


def test_fetch_new_activities_retries_incomplete_activity_on_next_run(data_dir, monkeypatch):
    monkeypatch.setattr(dl.time, "sleep", lambda *_: None)
    attempts = {"n": 0}

    class FlakyThenOkClient:
        def get_activities(self, start, limit):
            return [dict(ACTIVITY)] if start == 0 else []

        def get_activity(self, activity_id):
            return {"activityId": activity_id}

        def download_activity(self, activity_id):
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise RuntimeError("boom tcx (first attempt)")
            return b"<TrainingCenterDatabase/>"

    client = FlakyThenOkClient()
    gc_dir = dl.gconnect_dir(data_dir)

    n1 = dl.fetch_new_activities(client, data_dir, limit=10)
    assert n1 == 0
    assert list(gc_dir.glob("*_summary.json")) == []

    n2 = dl.fetch_new_activities(client, data_dir, limit=10)
    assert n2 == 1
    assert len(list(gc_dir.glob("*_summary.json"))) == 1


# --- retry cap: give up on permanently-failing activities --------------------


def test_partial_download_gives_up_after_max_attempts(data_dir, monkeypatch):
    """A permanently-failing activity is retried up to MAX_PARTIAL_ATTEMPTS
    times, then the summary is kept in place (so dedup skips it) instead of
    being retried forever."""
    monkeypatch.setattr(dl.time, "sleep", lambda *_: None)
    attempts = {"n": 0}

    class AlwaysFailsTcxClient:
        def get_activities(self, start, limit):
            return [dict(ACTIVITY)] if start == 0 else []

        def get_activity(self, activity_id):
            return {"activityId": activity_id}

        def download_activity(self, activity_id):
            attempts["n"] += 1
            raise RuntimeError("boom tcx (permanent)")

    client = AlwaysFailsTcxClient()
    gc_dir = dl.gconnect_dir(data_dir)

    for i in range(1, dl.MAX_PARTIAL_ATTEMPTS + 1):
        n = dl.fetch_new_activities(client, data_dir, limit=10)
        assert n == 0
        assert attempts["n"] == i

    # Given up: summary is kept in place so the dedup scan skips it, and
    # the retry-state entry for this activity has been cleared.
    assert len(list(gc_dir.glob("*_summary.json"))) == 1
    state = dl._load_retry_state(dl._retry_state_path(data_dir))
    assert str(ACTIVITY["activityId"]) not in state

    # A further run must NOT call download_activity again — the activity
    # is already "known" via the dedup scan of existing summary files.
    n_final = dl.fetch_new_activities(client, data_dir, limit=10)
    assert n_final == 0
    assert attempts["n"] == dl.MAX_PARTIAL_ATTEMPTS


def test_partial_download_giveup_sends_notification(data_dir, monkeypatch):
    """When an activity is given up on, the user is notified with a message
    mentioning the activity."""
    monkeypatch.setattr(dl.time, "sleep", lambda *_: None)

    class AlwaysFailsTcxClient:
        def get_activities(self, start, limit):
            return [dict(ACTIVITY)] if start == 0 else []

        def get_activity(self, activity_id):
            return {"activityId": activity_id}

        def download_activity(self, activity_id):
            raise RuntimeError("boom tcx (permanent)")

    calls = []

    def fake_notify(title, message):
        calls.append((title, message))
        return True

    monkeypatch.setattr("traning_cli.server.notify.notify", fake_notify)

    client = AlwaysFailsTcxClient()
    for _ in range(dl.MAX_PARTIAL_ATTEMPTS):
        dl.fetch_new_activities(client, data_dir, limit=10)

    assert len(calls) == 1
    title, message = calls[0]
    assert "Garmin" in title
    assert str(ACTIVITY["activityId"]) in message


def test_partial_download_giveup_notification_failure_does_not_break_flow(data_dir, monkeypatch):
    """A raising notify() must not prevent the give-up from completing."""
    monkeypatch.setattr(dl.time, "sleep", lambda *_: None)

    class AlwaysFailsTcxClient:
        def get_activities(self, start, limit):
            return [dict(ACTIVITY)] if start == 0 else []

        def get_activity(self, activity_id):
            return {"activityId": activity_id}

        def download_activity(self, activity_id):
            raise RuntimeError("boom tcx (permanent)")

    def raising_notify(title, message):
        raise RuntimeError("notify boom")

    monkeypatch.setattr("traning_cli.server.notify.notify", raising_notify)

    client = AlwaysFailsTcxClient()
    gc_dir = dl.gconnect_dir(data_dir)

    for _ in range(dl.MAX_PARTIAL_ATTEMPTS):
        n = dl.fetch_new_activities(client, data_dir, limit=10)
        assert n == 0

    # Give-up completed despite the notify exception: summary kept, retry
    # counter cleared.
    assert len(list(gc_dir.glob("*_summary.json"))) == 1
    state = dl._load_retry_state(dl._retry_state_path(data_dir))
    assert str(ACTIVITY["activityId"]) not in state


def test_partial_download_success_clears_retry_counter(gc_tc_dirs, tmp_path):
    """A successful full download clears any prior failed-attempt counter."""
    gc_dir, tc_dir = gc_tc_dirs
    retry_state_path = dl._retry_state_path(tmp_path)
    dl._save_retry_state(retry_state_path, {str(ACTIVITY["activityId"]): 2})

    client = FakeGarminClient()
    ok = dl._download_activity(
        client, ACTIVITY, gc_dir, tc_dir, retry_state_path=retry_state_path
    )

    assert ok is True
    state = dl._load_retry_state(retry_state_path)
    assert str(ACTIVITY["activityId"]) not in state
