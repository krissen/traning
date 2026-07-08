"""Tests for the WarmRBridge persistent-process optimization.

Hermetic by default: `_warm_bridge_cmd()` is monkeypatched to launch a
tiny Python subprocess that speaks the same base64-framed
newline-delimited-JSON protocol as `inst/mcp_bridge_server.R`, so these
tests exercise WarmRBridge's framing/lock/timeout/fallback logic without
requiring R or real training data.

A real-R integration test is included at the bottom, gated on
TRANING_DATA being set, that drives the actual `inst/mcp_bridge_server.R`
process and compares its output byte-for-byte against the spawn-per-call
`inst/mcp_bridge.R` path.
"""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from traning_cli.mcp import r_bridge
from traning_cli.mcp.r_bridge import (
    MCP_BRIDGE_R,
    TRANING_ROOT,
    WarmBridgeUnavailable,
    WarmRBridge,
    _run_r,
    _warm_bridge_enabled,
)

# --- Fake warm-server scripts ---------------------------------------------
#
# Each fake is a self-contained Python program (run via `python -c`) that
# reads base64-framed JSON requests from stdin and writes base64-framed
# JSON responses to stdout, mimicking inst/mcp_bridge_server.R's
# protocol exactly (see that file's header comment).

_FAKE_ECHO = """
import sys, base64, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(base64.b64decode(line))
    resp = {"id": req["id"], "type": "data", "data": {"func": req["func"]}}
    payload = json.dumps(resp).encode()
    sys.stdout.buffer.write(base64.b64encode(payload) + b"\\n")
    sys.stdout.flush()
"""

_FAKE_HANG = """
import sys, time
time.sleep(3600)
"""

_FAKE_DIES_IMMEDIATELY = """
import sys
sys.exit(1)
"""

_FAKE_GARBAGE = """
import sys
for line in sys.stdin:
    if not line.strip():
        continue
    sys.stdout.write("not valid base64 json!!!\\n")
    sys.stdout.flush()
"""

_FAKE_WRONG_ID = """
import sys, base64, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(base64.b64decode(line))
    resp = {"id": req["id"] + 999, "type": "data", "data": {}}
    payload = json.dumps(resp).encode()
    sys.stdout.buffer.write(base64.b64encode(payload) + b"\\n")
    sys.stdout.flush()
"""

_FAKE_SLOW_ECHO = """
import sys, base64, json, time
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(base64.b64decode(line))
    time.sleep(0.05)
    resp = {"id": req["id"], "type": "data", "data": {"func": req["func"]}}
    payload = json.dumps(resp).encode()
    sys.stdout.buffer.write(base64.b64encode(payload) + b"\\n")
    sys.stdout.flush()
"""

# Regression for ISSUE-001 (Nagelfar review): writes the first few bytes
# of a base64 frame (no trailing "\n") and then hangs forever, never
# completing the line. A pre-fix `readline()`-based reader would block
# on this indefinitely once select() reported the fd readable for those
# first bytes, since select() only bounds the wait for the FIRST byte —
# not the wait for the rest of the line.
_FAKE_PARTIAL_FRAME = """
import sys, time
line = sys.stdin.readline()  # consume the request so the pipe isn't backed up
sys.stdout.buffer.write(b"eyJpZCI6")  # a real base64 prefix, deliberately no "\\n"
sys.stdout.buffer.flush()
time.sleep(3600)
"""


def _fake_cmd(script: str) -> list[str]:
    return [sys.executable, "-u", "-c", script]


@pytest.fixture(autouse=True)
def _reset_singleton(monkeypatch):
    """Every test gets a fresh WarmRBridge — the module-level singleton
    must not leak a subprocess (or its identity) across tests."""
    monkeypatch.setattr(WarmRBridge, "_singleton", None)
    monkeypatch.setenv("VAYU_WARM_BRIDGE", "1")
    yield
    # Best-effort cleanup: kill any subprocess a test spawned.
    inst = WarmRBridge._singleton
    if inst is not None and inst._proc is not None:
        inst._teardown()
    WarmRBridge._singleton = None


# --- Kill switch ------------------------------------------------------------


def test_kill_switch_disables_warm_path(monkeypatch):
    monkeypatch.setenv("VAYU_WARM_BRIDGE", "0")
    assert _warm_bridge_enabled() is False


@pytest.mark.parametrize("val", ["0", "false", "False", "no", "NO"])
def test_kill_switch_values(monkeypatch, val):
    monkeypatch.setenv("VAYU_WARM_BRIDGE", val)
    assert _warm_bridge_enabled() is False


def test_kill_switch_default_enabled(monkeypatch):
    monkeypatch.delenv("VAYU_WARM_BRIDGE", raising=False)
    assert _warm_bridge_enabled() is True


def test_kill_switch_never_spawns_warm_process(monkeypatch):
    """With the kill switch off, _run_r must take the spawn path — the
    warm bridge should never even be constructed."""
    monkeypatch.setenv("VAYU_WARM_BRIDGE", "0")

    called = {"spawn": False}

    def fake_spawn(self):
        called["spawn"] = True
        raise AssertionError("warm bridge must not spawn when kill switch is set")

    monkeypatch.setattr(WarmRBridge, "_spawn", fake_spawn)

    def fake_run(cmd, **kwargs):
        class R:
            returncode = 0
            stdout = '{"type": "data", "data": {}}'
            stderr = ""
        return R()

    monkeypatch.setattr(subprocess, "run", fake_run)

    result = _run_r("report_monthstatus", {"n": 1})
    assert result["type"] == "data"
    assert called["spawn"] is False


# --- Hermetic protocol tests (fake subprocess) ------------------------------


def test_warm_request_roundtrip(monkeypatch):
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_ECHO))
    bridge = WarmRBridge.singleton()
    resp = bridge.request("report_monthstatus", {"n": 2}, False, None, timeout=10)
    assert resp["type"] == "data"
    assert resp["data"]["func"] == "report_monthstatus"
    assert "id" not in resp  # stripped before returning to the caller


def test_warm_bridge_reused_across_calls(monkeypatch):
    """Second call must reuse the same subprocess (no respawn)."""
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_ECHO))
    bridge = WarmRBridge.singleton()
    bridge.request("report_monthstatus", {}, False, None, timeout=10)
    pid1 = bridge._proc.pid
    bridge.request("report_yearstop", {}, False, None, timeout=10)
    pid2 = bridge._proc.pid
    assert pid1 == pid2


def test_timeout_raises_unavailable_and_kills_process(monkeypatch):
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_HANG))
    bridge = WarmRBridge.singleton()
    with pytest.raises(WarmBridgeUnavailable, match="timeout"):
        bridge.request("report_monthstatus", {}, False, None, timeout=1)
    assert bridge._proc is None  # torn down


def test_partial_frame_does_not_hang_and_releases_lock(monkeypatch):
    """Regression for ISSUE-001 (Nagelfar review): a server that writes
    a PARTIAL frame (no trailing "\\n") and then stalls must not block
    request() past the caller's timeout. Before the fix, only the wait
    for the FIRST byte was select()-bounded — readline() then blocked
    indefinitely waiting for the rest of the line, past the deadline,
    while self._lock was held, wedging the singleton: every subsequent
    warm call would block on lock-acquire and never reach the spawn
    fallback."""
    monkeypatch.setattr(
        r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_PARTIAL_FRAME)
    )
    bridge = WarmRBridge.singleton()
    timeout = 2

    t0 = time.monotonic()
    with pytest.raises(WarmBridgeUnavailable, match="timeout"):
        bridge.request("report_monthstatus", {}, False, None, timeout=timeout)
    elapsed = time.monotonic() - t0
    # Generous margin (2x) over the request timeout — the raise must
    # happen close to the deadline, not "eventually" and not never.
    assert elapsed < 2 * timeout, (
        f"request() took {elapsed:.1f}s for a {timeout}s timeout — "
        "the read loop is not bounding every blocking read"
    )
    assert bridge._proc is None  # torn down, not left stalled

    # The lock must have been released (via the `with self._lock:` in
    # request()) despite the exception path — prove it by making a
    # second call, with a healthy fake this time, and confirming it
    # runs to completion rather than blocking forever on lock-acquire.
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_ECHO))
    t0 = time.monotonic()
    resp = bridge.request("report_monthstatus", {}, False, None, timeout=10)
    elapsed2 = time.monotonic() - t0
    assert resp["type"] == "data"
    assert elapsed2 < 10


def test_timeout_falls_back_to_spawn_path(monkeypatch):
    """_run_r: a warm timeout must fall through to subprocess.run (the
    existing spawn path), not propagate the exception."""
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_HANG))

    spawn_called = {"count": 0}

    def fake_run(cmd, **kwargs):
        spawn_called["count"] += 1
        assert cmd[0] == "Rscript"
        assert str(MCP_BRIDGE_R) in cmd

        class R:
            returncode = 0
            stdout = '{"type": "data", "data": {"spawned": true}}'
            stderr = ""
        return R()

    monkeypatch.setattr(subprocess, "run", fake_run)

    result = _run_r("report_monthstatus", {"n": 1}, timeout=1)
    assert spawn_called["count"] == 1
    assert result["data"]["spawned"] is True


def test_dead_process_respawns_on_next_call(monkeypatch):
    monkeypatch.setattr(
        r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_DIES_IMMEDIATELY)
    )
    bridge = WarmRBridge.singleton()
    with pytest.raises(WarmBridgeUnavailable):
        bridge.request("report_monthstatus", {}, False, None, timeout=5)

    # Switch to a working fake for the respawn.
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_ECHO))
    resp = bridge.request("report_monthstatus", {}, False, None, timeout=5)
    assert resp["type"] == "data"


def test_respawn_budget_bounded(monkeypatch):
    """MAX_RESPAWNS failures within the window exhaust the budget; the
    next call must fail fast (WarmBridgeUnavailable) without trying to
    spawn again."""
    monkeypatch.setattr(
        r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_DIES_IMMEDIATELY)
    )
    bridge = WarmRBridge.singleton()
    for _ in range(WarmRBridge.MAX_RESPAWNS):
        with pytest.raises(WarmBridgeUnavailable):
            bridge.request("report_monthstatus", {}, False, None, timeout=5)

    spawn_calls = {"count": 0}
    orig_spawn = WarmRBridge._spawn

    def counting_spawn(self):
        spawn_calls["count"] += 1
        orig_spawn(self)

    monkeypatch.setattr(WarmRBridge, "_spawn", counting_spawn)
    with pytest.raises(WarmBridgeUnavailable, match="respawn budget"):
        bridge.request("report_monthstatus", {}, False, None, timeout=5)
    assert spawn_calls["count"] == 0


def test_malformed_frame_raises_unavailable(monkeypatch):
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_GARBAGE))
    bridge = WarmRBridge.singleton()
    with pytest.raises(WarmBridgeUnavailable, match="malformed frame"):
        bridge.request("report_monthstatus", {}, False, None, timeout=5)


def test_id_desync_raises_unavailable(monkeypatch):
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_WRONG_ID))
    bridge = WarmRBridge.singleton()
    with pytest.raises(WarmBridgeUnavailable, match="id desync"):
        bridge.request("report_monthstatus", {}, False, None, timeout=5)


# --- Concurrency -------------------------------------------------------------


class _TimingLock:
    """Drop-in replacement for threading.Lock that records the wall-clock
    interval each acquire/release pair actually holds the lock.

    Wrapping WarmRBridge's *real* `self._lock` (rather than timing
    around the whole `request()` call, which also includes time spent
    simply blocked waiting for the lock — not evidence of anything)
    gives a direct measurement of the actual critical-section windows.
    A plain threading.Lock trivially cannot produce overlapping
    intervals, so the interesting assertion is the one below it: with
    an unsynchronized write to a single pipe, concurrent threads racing
    to write their base64 request lines could interleave the underlying
    bytes and corrupt the frame boundary — the fact that all 5 requests
    round-trip cleanly (right func, right id, no desync) is the
    behavioural evidence that the lock is actually being taken around
    the write, not just present on the object.
    """

    def __init__(self):
        self._real = threading.Lock()
        self._meta = threading.Lock()
        self.intervals: list[tuple[float, float]] = []
        self._t0 = None

    def acquire(self, *a, **kw):
        ok = self._real.acquire(*a, **kw)
        if ok:
            self._t0 = time.monotonic()
        return ok

    def release(self):
        t1 = time.monotonic()
        with self._meta:
            self.intervals.append((self._t0, t1))
        self._real.release()

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *a):
        self.release()


def test_concurrent_requests_are_serialized(monkeypatch):
    """Two threads calling request() must not interleave: each response
    must correlate to its own request (the lock serializes access to a
    single-threaded R process on the other end of one pipe pair)."""
    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", lambda: _fake_cmd(_FAKE_SLOW_ECHO))
    bridge = WarmRBridge.singleton()
    timing_lock = _TimingLock()
    bridge._lock = timing_lock

    results: list[dict] = []
    errors: list[Exception] = []

    def worker(func_name: str):
        try:
            resp = bridge.request(func_name, {}, False, None, timeout=10)
            results.append(resp)
        except Exception as e:  # pragma: no cover - failure path surfaced via errors
            errors.append(e)

    threads = [
        threading.Thread(target=worker, args=(f"report_func_{i}",))
        for i in range(5)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15)

    assert not errors, errors
    assert len(results) == 5
    # Each response's echoed func must match a requested func, each
    # exactly once — with unsynchronized concurrent writes to the pipe,
    # base64 frames could interleave and corrupt the id/func mapping
    # (surfacing as a dropped/duplicated/wrong result); a clean 1:1
    # mapping is the behavioural evidence the lock serialized the wire
    # traffic, not just the bookkeeping.
    got_funcs = sorted(r["data"]["func"] for r in results)
    assert got_funcs == sorted(f"report_func_{i}" for i in range(5))

    # Direct confirmation: the actual critical-section windows recorded
    # by _TimingLock must be pairwise non-overlapping.
    intervals = sorted(timing_lock.intervals)
    assert len(intervals) == 5
    for (_, end_a), (start_b, _) in zip(intervals, intervals[1:]):
        assert start_b >= end_a


# --- Real-R integration (gated on TRANING_DATA) -----------------------------

_TRANING_DATA = os.environ.get("TRANING_DATA", "")


def _run_spawn_bridge(func: str, args: str = "{}", plot: bool = False,
                      plot_path: str | None = None) -> dict:
    cmd_args = [
        "Rscript", str(MCP_BRIDGE_R),
        f"--func={func}", f"--args={args}",
    ]
    if plot:
        cmd_args.append("--plot")
    if plot_path:
        cmd_args.append(f"--plot_path={plot_path}")
    env = {**os.environ, "TRANING_BRIDGE_LOADER": "load_all"}
    result = subprocess.run(
        cmd_args, capture_output=True, text=True, cwd=str(TRANING_ROOT),
        env=env, timeout=60,
    )
    return json.loads(result.stdout.strip())


@pytest.mark.skipif(not _TRANING_DATA, reason="TRANING_DATA not set")
def test_real_warm_server_matches_spawn_output(monkeypatch, tmp_path):
    """Byte-for-byte (structurally-equal) comparison of the warm path
    vs. the spawn-per-call path for a representative function."""
    monkeypatch.setenv("TRANING_BRIDGE_LOADER", "load_all")

    def real_cmd():
        return ["Rscript", str(TRANING_ROOT / "inst" / "mcp_bridge_server.R")]

    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", real_cmd)
    bridge = WarmRBridge.singleton()

    warm = bridge.request("report_monthstatus", {"n": 2}, False, None, timeout=60)
    spawn = _run_spawn_bridge("report_monthstatus", '{"n":2}')

    assert warm["type"] == spawn["type"] == "data"
    assert warm.get("rows") == spawn.get("rows")
    assert warm["data"] == spawn["data"]


@pytest.mark.skipif(not _TRANING_DATA, reason="TRANING_DATA not set")
def test_real_warm_server_plot_matches_spawn(monkeypatch, tmp_path):
    monkeypatch.setenv("TRANING_BRIDGE_LOADER", "load_all")

    def real_cmd():
        return ["Rscript", str(TRANING_ROOT / "inst" / "mcp_bridge_server.R")]

    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", real_cmd)
    bridge = WarmRBridge.singleton()

    warm_plot_path = tmp_path / "warm.png"
    warm = bridge.request(
        "fetch.plot.ef", {"from": "2025-01-01"}, True, warm_plot_path, timeout=60
    )
    assert warm["type"] == "plot"
    assert warm["path"] == str(warm_plot_path)
    assert warm_plot_path.exists()
    assert warm_plot_path.stat().st_size > 1000

    spawn_plot_path = tmp_path / "spawn.png"
    spawn = _run_spawn_bridge(
        "fetch.plot.ef", '{"from":"2025-01-01"}', plot=True,
        plot_path=str(spawn_plot_path),
    )
    assert spawn["type"] == "plot"
    assert spawn_plot_path.exists()
    assert spawn_plot_path.stat().st_size > 1000


@pytest.mark.skipif(not _TRANING_DATA, reason="TRANING_DATA not set")
def test_real_warm_server_survives_mid_session_cache_touch(monkeypatch, tmp_path):
    """Manual verification of the R-side mtime-reload logic: touching
    summaries.RData's mtime mid-session must not error or hang the next
    call. (The unit-testable half of the mtime-compare logic — whether a
    reload was actually TRIGGERED — is verified by reading
    inst/mcp_bridge_server.R's own stderr log line
    "(re)loading summaries.RData from disk"; see the PR report for a
    manual trace of that log line appearing exactly on cold-start and
    post-touch calls, and not on the intervening warm-hit call.)"""
    monkeypatch.setenv("TRANING_BRIDGE_LOADER", "load_all")

    def real_cmd():
        return ["Rscript", str(TRANING_ROOT / "inst" / "mcp_bridge_server.R")]

    monkeypatch.setattr(r_bridge, "_warm_bridge_cmd", real_cmd)
    bridge = WarmRBridge.singleton()

    summaries_path = Path(_TRANING_DATA) / "cache" / "summaries.RData"
    r1 = bridge.request("report_monthstatus", {"n": 2}, False, None, timeout=60)
    os.utime(summaries_path, None)
    r2 = bridge.request("report_monthstatus", {"n": 2}, False, None, timeout=60)
    assert r1["type"] == r2["type"] == "data"
    assert r1["data"] == r2["data"]
