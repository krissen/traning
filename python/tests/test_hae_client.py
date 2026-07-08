"""Tests for the shared HAE TCP client (traning_cli.health.hae_client).

Uses a fake socket (monkeypatched into ``socket.socket``) so no live HAE
server is required.
"""

import json
import socket

import pytest
from traning_cli.health import hae_client
from traning_cli.health.hae_client import (
    HAEError,
    HAEQueryError,
    HAEWorkoutsError,
    check_server,
    query_hae,
)


class _FakeSocket:
    """Minimal stand-in for socket.socket, feeding back canned bytes."""

    def __init__(self, response: bytes = b"", raise_on_connect: Exception | None = None,
                 raise_on_recv: Exception | None = None):
        self._response = response
        self._raise_on_connect = raise_on_connect
        self._raise_on_recv = raise_on_recv
        self.sent = b""
        self.connected_to = None
        self._served = False

    def settimeout(self, timeout):
        self.timeout = timeout

    def connect(self, addr):
        if self._raise_on_connect:
            raise self._raise_on_connect
        self.connected_to = addr

    def sendall(self, data: bytes):
        self.sent += data

    def recv(self, bufsize: int) -> bytes:
        if self._raise_on_recv:
            raise self._raise_on_recv
        if self._served:
            return b""
        self._served = True
        return self._response

    def close(self):
        pass


def _install_fake_socket(monkeypatch, fake: _FakeSocket):
    monkeypatch.setattr(hae_client.socket, "socket", lambda *a, **kw: fake)
    return fake


@pytest.fixture(autouse=True)
def _hae_env(monkeypatch):
    monkeypatch.setenv("HAE_HOST", "hae.local")
    monkeypatch.setenv("HAE_PORT", "9000")


# ---------------------------------------------------------------------------
# Request shape
# ---------------------------------------------------------------------------


def test_metrics_query_sends_expected_request(monkeypatch):
    response = json.dumps({"result": {"data": {"metrics": []}}}).encode()
    fake = _install_fake_socket(monkeypatch, _FakeSocket(response))

    query_hae(
        "health_metrics",
        {"start": "2024-01-01 00:00:00 +0100", "end": "2024-01-02 00:00:00 +0100",
         "interval": "days", "aggregate": True},
        request_id="fetch",
    )

    sent = json.loads(fake.sent.decode("utf-8"))
    assert sent["method"] == "callTool"
    assert sent["id"] == "fetch"
    assert sent["params"]["name"] == "health_metrics"
    # Historical health_metrics request carried a top-level empty "metrics" key.
    assert sent["params"]["metrics"] == ""
    assert sent["params"]["arguments"]["aggregate"] is True
    assert fake.connected_to == ("hae.local", 9000)


def test_workouts_query_sends_expected_request(monkeypatch):
    response = json.dumps({"result": {"data": {"workouts": []}}}).encode()
    fake = _install_fake_socket(monkeypatch, _FakeSocket(response))

    query_hae(
        "workouts",
        {"start": "2024-01-01 00:00:00 +0100", "end": "2024-02-01 00:00:00 +0100",
         "includeMetadata": True, "includeRoutes": False,
         "metadataAggregation": "minutes"},
        request_id="fetch_workouts",
    )

    sent = json.loads(fake.sent.decode("utf-8"))
    assert sent["params"]["name"] == "workouts"
    # health_metrics-only quirk must not leak into other tool requests.
    assert "metrics" not in sent["params"]
    assert sent["params"]["arguments"]["includeMetadata"] is True


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------


def test_parses_successful_response(monkeypatch):
    response = json.dumps(
        {"result": {"data": {"metrics": [{"name": "steps", "data": []}]}}}
    ).encode()
    _install_fake_socket(monkeypatch, _FakeSocket(response))

    body = query_hae("health_metrics", {"start": "a", "end": "b"})
    assert body == {"metrics": [{"name": "steps", "data": []}]}


def test_top_level_error_raises(monkeypatch):
    response = json.dumps({"error": "boom"}).encode()
    _install_fake_socket(monkeypatch, _FakeSocket(response))

    with pytest.raises(HAEError, match="HAE returned error"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_nested_result_error_raises(monkeypatch):
    """workouts_tcp.py historically checked for "error" nested in result."""
    response = json.dumps({"result": {"error": "boom"}}).encode()
    _install_fake_socket(monkeypatch, _FakeSocket(response))

    with pytest.raises(HAEError, match="HAE error"):
        query_hae("workouts", {"start": "a", "end": "b"})


def test_missing_result_key_raises(monkeypatch):
    response = json.dumps({"unexpected": True}).encode()
    _install_fake_socket(monkeypatch, _FakeSocket(response))

    with pytest.raises(HAEError, match="unexpected response shape"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_missing_data_key_raises(monkeypatch):
    response = json.dumps({"result": {"no_data_here": True}}).encode()
    _install_fake_socket(monkeypatch, _FakeSocket(response))

    with pytest.raises(HAEError, match="unexpected response shape"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_short_response_raises(monkeypatch):
    _install_fake_socket(monkeypatch, _FakeSocket(b"{}"))

    with pytest.raises(HAEError, match="empty/short response"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_malformed_json_raises(monkeypatch):
    _install_fake_socket(monkeypatch, _FakeSocket(b"not valid json at all here"))

    with pytest.raises(HAEError, match="JSON parse failed"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_connection_error_raises(monkeypatch):
    fake = _FakeSocket(raise_on_connect=ConnectionRefusedError("refused"))
    _install_fake_socket(monkeypatch, fake)

    with pytest.raises(HAEError, match="connection error"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_timeout_on_connect_raises(monkeypatch):
    fake = _FakeSocket(raise_on_connect=TimeoutError("timed out"))
    _install_fake_socket(monkeypatch, fake)

    with pytest.raises(HAEError, match="connection error"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


def test_timeout_during_recv_ends_read_loop(monkeypatch):
    """A TimeoutError during recv() (not connect) ends the read loop instead
    of propagating — matches the historical per-chunk timeout handling."""
    fake = _FakeSocket(raise_on_recv=TimeoutError("timed out"))
    _install_fake_socket(monkeypatch, fake)

    with pytest.raises(HAEError, match="empty/short response"):
        query_hae("health_metrics", {"start": "a", "end": "b"})


# ---------------------------------------------------------------------------
# Host/port resolution
# ---------------------------------------------------------------------------


def test_uses_settings_host_and_port_by_default(monkeypatch):
    response = json.dumps({"result": {"data": {}}}).encode()
    fake = _install_fake_socket(monkeypatch, _FakeSocket(response))

    query_hae("health_metrics", {"start": "a", "end": "b"})
    assert fake.connected_to == ("hae.local", 9000)


def test_explicit_host_and_port_override_settings(monkeypatch):
    response = json.dumps({"result": {"data": {}}}).encode()
    fake = _install_fake_socket(monkeypatch, _FakeSocket(response))

    query_hae("health_metrics", {"start": "a", "end": "b"},
              host="other.local", port=1234)
    assert fake.connected_to == ("other.local", 1234)


def test_check_server_reachable(monkeypatch):
    _install_fake_socket(monkeypatch, _FakeSocket(b""))
    assert check_server() is True


def test_check_server_unreachable(monkeypatch):
    fake = _FakeSocket(raise_on_connect=ConnectionRefusedError())
    _install_fake_socket(monkeypatch, fake)
    assert check_server() is False


# ---------------------------------------------------------------------------
# Backward-compatible exception aliases
# ---------------------------------------------------------------------------


def test_legacy_exception_aliases_are_hae_error():
    assert HAEQueryError is HAEError
    assert HAEWorkoutsError is HAEError


def test_real_socket_module_unaffected():
    """Sanity check the monkeypatch doesn't leak: real socket.socket is a
    builtin type, not our fake."""
    assert socket.socket is not _FakeSocket
