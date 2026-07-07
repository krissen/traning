"""Tests for the debounce-pending state persistence (server/state.py).

Covers the restart-survival fix: pending health files and the pending
workouts counter must round-trip through ``.pending_state.json`` so a
receiver restart can resume queued work instead of silently dropping it.
"""

from traning_cli.server import state


def test_empty_pending_state_shape():
    assert state.empty_pending_state() == {
        "pending_files": [],
        "pending_workouts_count": 0,
    }


def test_load_pending_state_missing_file_returns_empty(traning_data_dir):
    assert state.load_pending_state() == state.empty_pending_state()


def test_save_and_load_pending_state_roundtrip(traning_data_dir):
    payload = {"pending_files": ["a.json", "b.json"], "pending_workouts_count": 3}

    assert state.save_pending_state(payload) is True

    path = traning_data_dir / ".pending_state.json"
    assert path.is_file()
    # Atomic write: no leftover .tmp.<pid> file after os.replace().
    assert list(traning_data_dir.glob(".pending_state.json.tmp.*")) == []

    assert state.load_pending_state() == payload


def test_save_pending_state_overwrites_previous(traning_data_dir):
    state.save_pending_state({"pending_files": ["a.json"], "pending_workouts_count": 1})
    state.save_pending_state({"pending_files": [], "pending_workouts_count": 0})

    assert state.load_pending_state() == state.empty_pending_state()


def test_load_pending_state_malformed_json_resets(traning_data_dir):
    path = traning_data_dir / ".pending_state.json"
    path.write_text("{not valid json")

    assert state.load_pending_state() == state.empty_pending_state()


def test_load_pending_state_non_dict_resets(traning_data_dir):
    path = traning_data_dir / ".pending_state.json"
    path.write_text("[1, 2, 3]")

    assert state.load_pending_state() == state.empty_pending_state()


def test_load_pending_state_coerces_field_types(traning_data_dir):
    path = traning_data_dir / ".pending_state.json"
    path.write_text('{"pending_files": [1, 2], "pending_workouts_count": "5"}')

    assert state.load_pending_state() == {
        "pending_files": ["1", "2"],
        "pending_workouts_count": 5,
    }


def test_load_pending_state_bad_count_type_defaults_to_zero(traning_data_dir):
    path = traning_data_dir / ".pending_state.json"
    path.write_text('{"pending_files": [], "pending_workouts_count": "not-a-number"}')

    assert state.load_pending_state()["pending_workouts_count"] == 0


def test_save_pending_state_without_traning_data_returns_false(monkeypatch):
    monkeypatch.delenv("TRANING_DATA", raising=False)

    assert state.save_pending_state(state.empty_pending_state()) is False


def test_load_pending_state_without_traning_data_returns_empty(monkeypatch):
    monkeypatch.delenv("TRANING_DATA", raising=False)

    assert state.load_pending_state() == state.empty_pending_state()
