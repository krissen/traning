"""Tests for the /v1/health and /v1/workouts receiver endpoints.

Covers the pydantic request models (server/models.py) — the old
hand-rolled isinstance/len 422 checks were replaced by FastAPI's
automatic validation, so these tests pin the exact 422 conditions that
must still be rejected and the payload shape that must still be
accepted.

Uses importlib for the same reason as test_app_debounce.py:
``traning_cli/server/__init__.py`` shadows the ``app`` submodule
attribute with a built FastAPI instance.
"""

import importlib

import pytest
from fastapi.testclient import TestClient

app_mod = importlib.import_module("traning_cli.server.app")

API_KEY = "test-api-key"


@pytest.fixture(autouse=True)
def _reset_debounce_globals(monkeypatch):
    """Same isolation as test_app_debounce.py — avoid cross-test timers."""
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


@pytest.fixture
def client(traning_data_dir, monkeypatch):
    monkeypatch.setenv("TRANING_API_KEY", API_KEY)
    # Avoid touching disk/git/R in these endpoint-shape tests — the
    # storage/commit/debounce internals are covered elsewhere
    # (test_app_debounce.py, and the storage/git_utils tests).
    monkeypatch.setattr(app_mod, "save_health_push", lambda payload: (1, []))
    monkeypatch.setattr(app_mod, "save_workout_push", lambda payload: 1)
    monkeypatch.setattr(app_mod, "commit_health_data", lambda **kw: True)
    monkeypatch.setattr(app_mod, "_schedule_health_import", lambda files: None)
    monkeypatch.setattr(app_mod, "_schedule_workouts_import", lambda n: None)

    application = app_mod.create_app()
    with TestClient(application) as c:
        yield c


HEADERS = {"X-API-Key": API_KEY}


# --- /v1/health --------------------------------------------------------------


def test_receive_health_valid_payload_returns_200(client):
    body = {"data": {"metrics": [{"name": "heart_rate", "units": "bpm", "data": [1, 2]}]}}
    resp = client.post("/v1/health", json=body, headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "metrics_saved": 1, "total_samples": 2}


def test_receive_health_missing_data_key_is_422(client):
    resp = client.post("/v1/health", json={"metrics": [{"name": "x", "data": []}]}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_health_missing_metrics_key_is_422(client):
    resp = client.post("/v1/health", json={"data": {}}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_health_metrics_not_a_list_is_422(client):
    resp = client.post("/v1/health", json={"data": {"metrics": "nope"}}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_health_empty_metrics_list_is_422(client):
    resp = client.post("/v1/health", json={"data": {"metrics": []}}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_health_invalid_json_is_422(client):
    resp = client.post(
        "/v1/health", content=b"not json", headers={**HEADERS, "Content-Type": "application/json"},
    )
    assert resp.status_code == 422


def test_receive_health_requires_api_key(client):
    body = {"data": {"metrics": [{"name": "x", "data": [1]}]}}
    resp = client.post("/v1/health", json=body)
    assert resp.status_code == 401


def test_receive_health_wrong_api_key_is_401(client):
    body = {"data": {"metrics": [{"name": "x", "data": [1]}]}}
    resp = client.post("/v1/health", json=body, headers={"X-API-Key": "wrong"})
    assert resp.status_code == 401


# --- /v1/workouts --------------------------------------------------------------


def test_receive_workouts_valid_payload_returns_200(client):
    body = {"data": {"workouts": [{"name": "Running", "start": "2026-01-01 07:00:00 +0100"}]}}
    resp = client.post("/v1/workouts", json=body, headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "workouts_saved": 1}


def test_receive_workouts_missing_data_key_is_422(client):
    resp = client.post("/v1/workouts", json={"workouts": []}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_workouts_missing_workouts_key_is_422(client):
    resp = client.post("/v1/workouts", json={"data": {}}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_workouts_not_a_list_is_422(client):
    resp = client.post("/v1/workouts", json={"data": {"workouts": "nope"}}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_workouts_empty_list_is_422(client):
    resp = client.post("/v1/workouts", json={"data": {"workouts": []}}, headers=HEADERS)
    assert resp.status_code == 422


def test_receive_workouts_requires_api_key(client):
    body = {"data": {"workouts": [{"name": "Running"}]}}
    resp = client.post("/v1/workouts", json=body)
    assert resp.status_code == 401


# --- client logging ----------------------------------------------------------


def test_receive_health_logs_user_agent(client, caplog):
    body = {"data": {"metrics": [{"name": "heart_rate", "units": "bpm", "data": [1]}]}}
    headers = {**HEADERS, "User-Agent": "HealthAutoExport/8.4.1"}
    with caplog.at_level("INFO", logger=app_mod.log.name):
        client.post("/v1/health", json=body, headers=headers)
    assert "/v1/health push from" in caplog.text
    assert "HealthAutoExport/8.4.1" in caplog.text


def test_receive_workouts_logs_user_agent(client, caplog):
    body = {"data": {"workouts": [{"name": "Running"}]}}
    headers = {**HEADERS, "User-Agent": "HealthAutoExport/8.4.1"}
    with caplog.at_level("INFO", logger=app_mod.log.name):
        client.post("/v1/workouts", json=body, headers=headers)
    assert "/v1/workouts push from" in caplog.text
    assert "HealthAutoExport/8.4.1" in caplog.text


def test_client_logging_never_leaks_the_api_key(client, caplog):
    body = {"data": {"metrics": [{"name": "heart_rate", "units": "bpm", "data": [1]}]}}
    with caplog.at_level("INFO", logger=app_mod.log.name):
        client.post("/v1/health", json=body, headers=HEADERS)
    assert API_KEY not in caplog.text


@pytest.mark.parametrize(
    ("path", "body"),
    [
        ("/v1/health", {"data": {"metrics": "not-a-list"}}),
        ("/v1/workouts", {"data": {"workouts": []}}),
    ],
)
def test_rejected_payload_still_logs_user_agent(client, caplog, path, body):
    """A 422 is exactly when the app version matters — log it anyway.

    Validation happens before the handler, so this only holds as long as
    the logging sits in middleware.
    """
    headers = {**HEADERS, "User-Agent": "HealthAutoExport/9.0.0"}
    with caplog.at_level("INFO", logger=app_mod.log.name):
        resp = client.post(path, json=body, headers=headers)
    assert resp.status_code == 422
    assert f"{path} push from" in caplog.text
    assert "HealthAutoExport/9.0.0" in caplog.text


def test_health_probe_is_not_logged_as_a_push(client, caplog):
    """The monitoring probe hits /health every day — keep it out."""
    with caplog.at_level("INFO", logger=app_mod.log.name):
        client.get("/health")
    assert "push from" not in caplog.text


def test_push_is_logged_once(client, caplog):
    body = {"data": {"metrics": [{"name": "heart_rate", "units": "bpm", "data": [1]}]}}
    with caplog.at_level("INFO", logger=app_mod.log.name):
        client.post("/v1/health", json=body, headers=HEADERS)
    assert caplog.text.count("/v1/health push from") == 1
