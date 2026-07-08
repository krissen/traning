"""R bridge — subprocess helpers for calling R functions from the MCP server."""

import base64
import json
import logging
import os
import re
import secrets
import select
import stat as stat_lib
import subprocess
import tempfile
import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastmcp.utilities.types import Image

logger = logging.getLogger(__name__)

TRANING_ROOT = Path(__file__).resolve().parent.parent.parent.parent
MCP_BRIDGE_R = TRANING_ROOT / "inst" / "mcp_bridge.R"
MCP_BRIDGE_SERVER_R = TRANING_ROOT / "inst" / "mcp_bridge_server.R"

# Python owns the directory R writes plot PNGs into, so the file
# survives the R subprocess exit. R's own tempdir() is wiped when the
# bridge process ends, which used to race with Python's read.
#
# The directory name carries the process uid + 0o700 perms so another
# local user cannot list/read plots or pre-create a symlinked trap on
# shared hosts. The path is resolved lazily inside _plot_dir() rather
# than at import time: os.getuid() is POSIX-only and would otherwise
# break `import` on Windows even for callers that never plot.
VAYU_PLOTS_MAX_AGE_SEC = 3600


def _plot_dir() -> Path:
    """Compute the per-uid plot directory path (POSIX only).

    Raises:
        OSError: on platforms without os.getuid() (e.g. Windows).
    """
    getuid = getattr(os, "getuid", None)
    if getuid is None:
        raise OSError(
            "vayu plot output requires a POSIX uid; "
            "os.getuid() is not available on this platform"
        )
    return Path(tempfile.gettempdir()) / f"vayu_plots_uid{getuid()}"


# Date expression pattern: YYYY, YYYY-MM, YYYY-MM-DD, or relative (-3w, -1y, etc.)
_DATE_EXPR_RE = re.compile(
    r"^(\d{4}(-\d{2}(-\d{2})?)?|-\d+[dwmy])$"
)

# Functions known to the R bridge
_KNOWN_FUNCTIONS = frozenset({
    # Basic reports
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_datesum", "report_ef", "report_hre", "report_acwr",
    "report_monotony", "report_pmc", "report_recovery_hr",
    "report_hr_zones", "report_decoupling", "report_readiness",
    "report_metric",
    # Report plots
    "plot_monthtop", "plot_runs_month", "plot_monthstatus",
    "plot_monthlast", "plot_yearstop", "plot_datesum",
    # Advanced plots
    "fetch.plot.ef", "fetch.plot.hre", "fetch.plot.acwr",
    "fetch.plot.monotony", "fetch.plot.pmc", "fetch.plot.recovery_hr",
    "fetch.plot.hr_zones", "fetch.plot.decoupling",
    # Löpprofil — yearly characterization
    "fetch.plot.pace_year", "fetch.plot.pace_year_ridges",
    "fetch.plot.pace_tertile_share", "fetch.plot.longest_runs_year",
    "fetch.plot.season_pace", "fetch.plot.heatmap_km",
    "fetch.plot.cumulative_km", "fetch.plot.distance_pace_era",
    # Health plots
    "fetch.plot.resting_hr", "fetch.plot.hrv", "fetch.plot.sleep",
    "fetch.plot.vo2max", "fetch.plot.readiness_score",
    # State-based health insights + data inspection
    "health_insight_readiness", "recent_data_dump", "latest_known_metrics",
    # Multi-sport plots
    "plot_sport_mix", "plot_sport_ctl_overlay", "plot_sport_calendar",
    # Phase 5d race tools
    "compute_taper_plan", "compute_race_readiness",
})


def _sanitize(value: str) -> str:
    """Strip control characters from a string."""
    return re.sub(r"[\x00-\x1f\x7f]", "", str(value))


def _prepare_plot_dir() -> Path:
    """Ensure the plot directory exists and prune stale files.

    On a shared `/tmp` an attacker could otherwise pre-create the
    target as a symlink, so `mkdir(..., exist_ok=False)` is used to
    refuse adoption of any pre-existing entry; if creation fails with
    `FileExistsError` we re-validate the existing entry with `lstat()`
    (does not follow symlinks), reject anything that is not a real
    directory owned by the current uid, and only then chmod.
    `chmod` failures are fatal — silently continuing with potentially
    world-readable `/tmp` perms would defeat the point.

    Plot files are unlinked immediately after read, so the directory
    is normally empty. Age-based GC (>1 h) on every call covers
    crashed-bridge cases without needing a separate timer.
    """
    target = _plot_dir()
    try:
        target.mkdir(mode=0o700, parents=True, exist_ok=False)
    except FileExistsError:
        # Pre-existing entry — validate it's safe to reuse.
        try:
            st = target.lstat()
        except OSError as e:
            raise RuntimeError(
                f"vayu plot dir lstat failed: {target}: {e}"
            ) from e
        if stat_lib.S_ISLNK(st.st_mode):
            raise RuntimeError(
                f"vayu plot dir is a symlink, refusing: {target}"
            )
        if not stat_lib.S_ISDIR(st.st_mode):
            raise RuntimeError(
                f"vayu plot path is not a directory: {target}"
            )
        if st.st_uid != os.getuid():
            raise RuntimeError(
                f"vayu plot dir owned by uid {st.st_uid}, expected "
                f"{os.getuid()}: {target}"
            )

    # Fail-closed chmod: if we cannot lock perms down, the dir is
    # not safe to keep using.
    try:
        os.chmod(target, 0o700)
    except OSError as e:
        raise RuntimeError(
            f"Could not chmod {target} to 0o700: {e}"
        ) from e

    cutoff = time.time() - VAYU_PLOTS_MAX_AGE_SEC
    for entry in target.iterdir():
        try:
            if entry.is_file() and entry.stat().st_mtime < cutoff:
                entry.unlink()
        except OSError as e:
            logger.debug("vayu_plots GC skipped %s: %s", entry, e)
    return target


def _new_plot_path() -> Path:
    """Generate a unique plot path Python controls.

    Two concurrent calls cannot collide: filename carries both a UTC
    timestamp and 8 hex chars of randomness.
    """
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
    return _plot_dir() / f"vayu_{stamp}_{secrets.token_hex(4)}.png"


def _validate_date(expr: str) -> str:
    """Validate and return a date expression, or raise ValueError."""
    expr = _sanitize(expr).strip()
    if not _DATE_EXPR_RE.match(expr):
        raise ValueError(f"Invalid date expression: {expr!r}")
    return expr


class WarmBridgeUnavailable(Exception):
    """Raised whenever the warm bridge cannot serve a request right now.

    Every raise site in `WarmRBridge` tears the subprocess down before
    raising, so the NEXT call starts from a clean slate (respawn, subject
    to the bounded-respawn budget). Callers must treat this as "fall back
    to the spawn-per-call path for this one request" — never as fatal.
    """


def _warm_bridge_enabled() -> bool:
    """Kill-switch: VAYU_WARM_BRIDGE=0/false/no disables the warm path.

    Also off by construction on non-POSIX platforms — the warm server's
    protocol relies on `select.select()` over a subprocess pipe fileno,
    which is POSIX-only (same constraint _plot_dir() already documents
    for os.getuid()).
    """
    if os.name != "posix":
        return False
    val = os.environ.get("VAYU_WARM_BRIDGE", "1").strip().lower()
    return val not in ("0", "false", "no")


def _warm_bridge_cmd() -> list[str]:
    """The command used to spawn the warm bridge subprocess.

    Factored out as its own function (rather than inlined in `_spawn`)
    so tests can monkeypatch it to launch a fake/hermetic subprocess
    instead of `Rscript inst/mcp_bridge_server.R` — real R and real
    TRANING_DATA are not required to exercise the framing/lock/timeout/
    fallback logic in `WarmRBridge`.
    """
    return ["Rscript", str(MCP_BRIDGE_SERVER_R)]


class WarmRBridge:
    """Owns a persistent `inst/mcp_bridge_server.R` subprocess.

    Pure optimization: every failure mode (timeout, dead process, EOF,
    malformed frame, id desync) tears the subprocess down and raises
    `WarmBridgeUnavailable` so `_run_r` falls back to the existing
    spawn-per-call path. This class must NEVER be the reason an MCP tool
    call hangs — every blocking read is bounded by `select.select()`
    with the caller's timeout.

    Single `threading.Lock` serializes the whole request lifecycle
    (spawn/respawn included) — R is single-threaded on the other end of
    one pipe pair, so there is exactly one in-flight request at a time.
    This is a single-user local server; a connection pool would add
    complexity for no benefit here.
    """

    # Recycle the process after this many requests or this much wall
    # time, whichever comes first — bounds unbounded memory growth in a
    # process that, by design, never exits on its own.
    MAX_REQUESTS = 500
    MAX_AGE_SEC = 3600  # 1 hour

    # Bounded respawn: if the process dies this many times within the
    # window, stop trying and stay in fallback (spawn-per-call) until a
    # request arrives after the window has rolled forward. Prevents a
    # persistently broken warm server (e.g. a bad deploy) from turning
    # every call into a multi-second respawn-then-fail loop.
    MAX_RESPAWNS = 3
    RESPAWN_WINDOW_SEC = 60

    _singleton: "WarmRBridge | None" = None
    _singleton_lock = threading.Lock()

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._next_id = 1
        self._request_count = 0
        self._started_at = 0.0
        self._respawn_times: list[float] = []

    @classmethod
    def singleton(cls) -> "WarmRBridge":
        if cls._singleton is None:
            with cls._singleton_lock:
                if cls._singleton is None:
                    cls._singleton = cls()
        return cls._singleton

    # --- Process lifecycle ---------------------------------------------

    def _spawn(self) -> None:
        env = {**os.environ, "TRANING_OPEN": "false"}
        self._proc = subprocess.Popen(
            _warm_bridge_cmd(),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=str(TRANING_ROOT),
            env=env,
            bufsize=0,
        )
        self._next_id = 1
        self._request_count = 0
        self._started_at = time.monotonic()
        logger.info("WarmRBridge: spawned pid=%s", self._proc.pid)

    def _teardown(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
                proc.wait(timeout=5)
            except Exception as e:
                logger.warning("WarmRBridge: failed to kill pid=%s: %s",
                              getattr(proc, "pid", "?"), e)

    def _ensure_alive(self) -> None:
        """(Re)spawn if needed, subject to the bounded-respawn budget.

        Caller must hold `self._lock`.
        """
        if self._proc is not None and self._proc.poll() is None:
            return
        now = time.monotonic()
        self._respawn_times = [
            t for t in self._respawn_times if now - t < self.RESPAWN_WINDOW_SEC
        ]
        if len(self._respawn_times) >= self.MAX_RESPAWNS:
            raise WarmBridgeUnavailable(
                f"respawn budget exceeded ({self.MAX_RESPAWNS} in "
                f"{self.RESPAWN_WINDOW_SEC}s); staying in fallback"
            )
        self._respawn_times.append(now)
        self._spawn()

    def _maybe_recycle(self) -> None:
        """Planned recycle (age/request-count) — not a failure, so it
        does not consume the failure-respawn budget."""
        if self._proc is None:
            return
        age = time.monotonic() - self._started_at
        if self._request_count >= self.MAX_REQUESTS or age >= self.MAX_AGE_SEC:
            logger.info(
                "WarmRBridge: recycling pid=%s (requests=%d age=%.0fs)",
                self._proc.pid, self._request_count, age,
            )
            self._teardown()
            self._spawn()

    # --- Request/response -------------------------------------------------

    def request(
        self,
        func: str,
        args: dict[str, Any],
        plot: bool,
        plot_path: Path | None,
        timeout: int,
    ) -> dict:
        """Send one framed request and return the parsed response dict.

        Raises `WarmBridgeUnavailable` on any protocol trouble; the
        subprocess is torn down before raising so the next call starts
        clean (respawn permitting).
        """
        with self._lock:
            self._ensure_alive()
            self._maybe_recycle()
            proc = self._proc
            assert proc is not None  # _ensure_alive raises otherwise
            assert proc.stdin is not None
            assert proc.stdout is not None

            req_id = self._next_id
            self._next_id += 1
            request_obj = {
                "id": req_id,
                "func": func,
                "args": args,
                "plot": bool(plot),
                "plot_path": str(plot_path) if plot_path is not None else None,
            }
            try:
                payload = json.dumps(request_obj).encode("utf-8")
                line = base64.b64encode(payload) + b"\n"
                proc.stdin.write(line)
                proc.stdin.flush()
            except (BrokenPipeError, OSError) as e:
                self._teardown()
                raise WarmBridgeUnavailable(f"write failed: {e}") from e

            # Bounded read: readline() would block on a PARTIAL frame
            # (bytes written without a trailing "\n") past the deadline,
            # even though the initial select() only bounds the wait for
            # the FIRST byte to arrive — a stalled/misbehaving server
            # that writes a few bytes and then hangs would otherwise
            # block this call (and, since it's called with self._lock
            # held, every subsequent warm call) forever, defeating the
            # entire "fallback can never hang" guarantee. Every
            # individual read is therefore select()-gated on its own
            # slice of the remaining deadline, and a single `os.read()`
            # call is used instead of `readline()` — per POSIX, once
            # select() reports a fd readable, a single read() syscall
            # returns immediately with whatever is available (possibly
            # less than requested) rather than blocking for a full
            # line, so this cannot itself introduce another unbounded
            # wait.
            deadline = time.monotonic() + timeout
            resp: dict | None = None
            buf = b""
            try:
                while resp is None:
                    newline_idx = buf.find(b"\n")
                    if newline_idx == -1:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise WarmBridgeUnavailable(
                                f"timeout after {timeout}s waiting for warm bridge response"
                            )
                        ready, _, _ = select.select([proc.stdout], [], [], remaining)
                        if not ready:
                            continue
                        chunk = os.read(proc.stdout.fileno(), 65536)
                        if not chunk:
                            raise WarmBridgeUnavailable("warm bridge stdout EOF")
                        buf += chunk
                        continue

                    raw_line, buf = buf[:newline_idx], buf[newline_idx + 1:]
                    raw_line = raw_line.strip()
                    if not raw_line:
                        continue  # defensive: skip stray blank lines
                    try:
                        decoded = base64.b64decode(raw_line)
                        candidate = json.loads(decoded)
                    except Exception as e:
                        raise WarmBridgeUnavailable(f"malformed frame: {e}") from e
                    if candidate.get("id") != req_id:
                        raise WarmBridgeUnavailable(
                            f"id desync: expected {req_id}, got {candidate.get('id')!r}"
                        )
                    resp = candidate
            except WarmBridgeUnavailable:
                self._teardown()
                raise
            except Exception as e:
                self._teardown()
                raise WarmBridgeUnavailable(f"unexpected error: {e}") from e

            self._request_count += 1
            resp.pop("id", None)
            return resp


def _run_r(
    func: str,
    args: dict[str, Any] | None = None,
    *,
    plot: bool = False,
    plot_path: Path | None = None,
    timeout: int = 120,
) -> dict:
    """Call an R function via mcp_bridge.R and return parsed JSON result.

    Args:
        func: Function name (must be in _KNOWN_FUNCTIONS).
        args: Dict of arguments to pass as JSON.
        plot: If True, request PNG plot output.
        plot_path: Target path R should write the PNG to. Required when
            plot=True so the file survives the R subprocess.
        timeout: Subprocess timeout in seconds (clamped to 10-300).

    Returns:
        Parsed JSON dict from R stdout.
    """
    if func not in _KNOWN_FUNCTIONS:
        return {"type": "error", "message": f"Unknown function: {func}"}

    # Enforced rather than fallen-back: a None path would silently
    # reintroduce the R-tempdir race the rest of this module exists
    # to prevent.
    if plot and plot_path is None:
        raise ValueError("_run_r(plot=True) requires plot_path")

    timeout = max(10, min(300, timeout))
    args = args or {}

    # Validate date args
    for key in ("from", "to"):
        if key in args and args[key] is not None:
            args[key] = _validate_date(args[key])

    # Sanitize string args
    clean_args = {}
    for k, v in args.items():
        if isinstance(v, str):
            clean_args[k] = _sanitize(v)
        else:
            clean_args[k] = v

    # Warm path: a persistent inst/mcp_bridge_server.R process, tried
    # AFTER all validation/sanitize/plot_path enforcement above (never
    # before — the warm bridge must see exactly the same clean_args the
    # spawn path below would). Pure optimization: on ANY trouble
    # (timeout, dead process, EOF, malformed frame, id desync, or the
    # VAYU_WARM_BRIDGE kill-switch) it falls straight through to the
    # unchanged spawn-per-call code below.
    if _warm_bridge_enabled():
        try:
            return WarmRBridge.singleton().request(
                func, clean_args, plot, plot_path, timeout
            )
        except WarmBridgeUnavailable as e:
            logger.warning("Warm R bridge unavailable (%s); falling back to spawn", e)

    cmd = [
        "Rscript", str(MCP_BRIDGE_R),
        f"--func={func}",
        f"--args={json.dumps(clean_args)}",
    ]
    if plot:
        # plot_path is non-None here: enforced above.
        cmd.append("--plot")
        cmd.append(f"--plot_path={plot_path}")

    env = {**os.environ, "TRANING_OPEN": "false"}

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(TRANING_ROOT),
            env=env,
        )
    except subprocess.TimeoutExpired:
        return {"type": "error", "message": f"R call timed out after {timeout}s"}

    if result.returncode != 0:
        stderr_tail = (result.stderr or "").strip()[-500:]
        stdout_tail = (result.stdout or "").strip()[-500:]
        # Try to parse JSON error from stdout first
        if stdout_tail:
            try:
                return json.loads(stdout_tail)
            except json.JSONDecodeError:
                pass
        return {
            "type": "error",
            "message": f"R exited with code {result.returncode}",
            "stderr": stderr_tail,
        }

    stdout = result.stdout.strip()
    if not stdout:
        return {"type": "error", "message": "R returned empty output"}

    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return {
            "type": "error",
            "message": "Failed to parse R JSON output",
            "raw": stdout[:500],
        }


def r_report(
    func: str,
    args: dict[str, Any] | None = None,
    *,
    timeout: int = 120,
) -> dict:
    """Call an R report function and wrap result in a standard envelope.

    Returns a dict with schema_version, summary, details, and _meta.
    """
    raw = _run_r(func, args, timeout=timeout)

    if raw.get("type") == "error":
        return {
            "schema_version": "1.0",
            "summary": {"status": "error", "message": raw.get("message", "")},
            "details": [],
            "_meta": {
                "func": func,
                "query_date": datetime.now().isoformat(),
            },
        }

    rows = raw.get("data", [])
    row_count = raw.get("rows", len(rows) if isinstance(rows, list) else 0)

    # Extract date range from data if available
    date_range = {}
    if isinstance(rows, list) and rows:
        for date_key in ("Datum", "date", "sessionStart"):
            if date_key in rows[0]:
                dates = [r[date_key] for r in rows if r.get(date_key)]
                if dates:
                    date_range = {"from": min(dates), "to": max(dates)}
                break

    return {
        "schema_version": "1.0",
        "summary": {
            "status": "ok",
            "record_count": row_count,
            "date_range": date_range,
        },
        "details": rows,
        "_meta": {
            "func": func,
            "query_date": datetime.now().isoformat(),
        },
    }


def r_plot(
    func: str,
    args: dict[str, Any] | None = None,
    *,
    timeout: int = 120,
) -> Image | dict:
    """Call an R plot function and return MCP-spec image content.

    Returns a FastMCP ``Image`` on success, which FastMCP serialises as
    the standard MCP ``ImageContent`` (``{type: "image", data, mimeType}``).
    The previous bespoke dict shape (``{type: "plot", base64, ...}``)
    was not recognised by spec-compliant clients (e.g. OpenClaw
    webchat) and silently swallowed.

    On failure: ``{"type": "error", "message": ...}`` — kept as a dict
    so the error surfaces as readable text in the chat rather than as
    a broken image attempt.
    """
    _prepare_plot_dir()
    png_path = _new_plot_path()

    raw = _run_r(func, args, plot=True, plot_path=png_path, timeout=timeout)

    if raw.get("type") == "error":
        return raw

    # Defend against a future bridge refactor that returns a non-plot
    # envelope for a plot request — would otherwise surface as the
    # misleading "Plot file not found" below.
    if raw.get("type") != "plot":
        return {
            "type": "error",
            "message": (
                f"Unexpected response from R bridge: type="
                f"{raw.get('type')!r}"
            ),
        }
    if raw.get("path") and raw["path"] != str(png_path):
        return {
            "type": "error",
            "message": (
                f"R bridge wrote to unexpected path: {raw['path']!r} "
                f"(expected {str(png_path)!r})"
            ),
        }

    if not png_path.exists():
        return {"type": "error", "message": "Plot file not found"}

    try:
        png_data = png_path.read_bytes()
    finally:
        try:
            png_path.unlink()
        except OSError as e:
            logger.debug("Failed to unlink %s: %s", png_path, e)

    return Image(data=png_data, format="png")
