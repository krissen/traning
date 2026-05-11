"""R bridge — subprocess helpers for calling R functions from the MCP server."""

import base64
import getpass
import json
import logging
import os
import re
import secrets
import stat as stat_lib
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

TRANING_ROOT = Path(__file__).resolve().parent.parent.parent.parent
MCP_BRIDGE_R = TRANING_ROOT / "inst" / "mcp_bridge.R"

# Python owns the directory R writes plot PNGs into, so the file
# survives the R subprocess exit. R's own tempdir() is wiped when the
# bridge process ends, which used to race with Python's read.
#
# Per-user dir name + 0o700 perms prevent another local user from
# listing/reading plots or pre-creating a symlinked trap on shared
# hosts. getpass.getuser() avoids hard-coding the username so the
# same code runs under `krisse` on kailash, `krisniem` on macOS, etc.
VAYU_PLOTS_DIR = Path(tempfile.gettempdir()) / f"vayu_plots_{getpass.getuser()}"
VAYU_PLOTS_MAX_AGE_SEC = 3600

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
    "plot_monthlast", "plot_yearstatus", "plot_yearstop", "plot_datesum",
    # Advanced plots
    "fetch.plot.ef", "fetch.plot.hre", "fetch.plot.acwr",
    "fetch.plot.monotony", "fetch.plot.pmc", "fetch.plot.recovery_hr",
    "fetch.plot.hr_zones", "fetch.plot.decoupling",
    # Health plots
    "fetch.plot.resting_hr", "fetch.plot.hrv", "fetch.plot.sleep",
    "fetch.plot.vo2max", "fetch.plot.readiness_score",
    # State-based health insights + data inspection
    "health_insight_readiness", "recent_data_dump", "latest_known_metrics",
    # Multi-sport plots
    "plot_sport_mix", "plot_sport_ctl_overlay", "plot_sport_calendar",
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
    try:
        VAYU_PLOTS_DIR.mkdir(mode=0o700, parents=True, exist_ok=False)
    except FileExistsError:
        # Pre-existing entry — validate it's safe to reuse.
        try:
            st = VAYU_PLOTS_DIR.lstat()
        except OSError as e:
            raise RuntimeError(
                f"vayu plot dir lstat failed: {VAYU_PLOTS_DIR}: {e}"
            ) from e
        if stat_lib.S_ISLNK(st.st_mode):
            raise RuntimeError(
                f"vayu plot dir is a symlink, refusing: {VAYU_PLOTS_DIR}"
            )
        if not stat_lib.S_ISDIR(st.st_mode):
            raise RuntimeError(
                f"vayu plot path is not a directory: {VAYU_PLOTS_DIR}"
            )
        if st.st_uid != os.getuid():
            raise RuntimeError(
                f"vayu plot dir owned by uid {st.st_uid}, expected "
                f"{os.getuid()}: {VAYU_PLOTS_DIR}"
            )

    # Fail-closed chmod: if we cannot lock perms down, the dir is
    # not safe to keep using.
    try:
        os.chmod(VAYU_PLOTS_DIR, 0o700)
    except OSError as e:
        raise RuntimeError(
            f"Could not chmod {VAYU_PLOTS_DIR} to 0o700: {e}"
        ) from e

    cutoff = time.time() - VAYU_PLOTS_MAX_AGE_SEC
    for entry in VAYU_PLOTS_DIR.iterdir():
        try:
            if entry.is_file() and entry.stat().st_mtime < cutoff:
                entry.unlink()
        except OSError as e:
            logger.debug("vayu_plots GC skipped %s: %s", entry, e)
    return VAYU_PLOTS_DIR


def _new_plot_path() -> Path:
    """Generate a unique plot path Python controls.

    Two concurrent calls cannot collide: filename carries both a UTC
    timestamp and 8 hex chars of randomness.
    """
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return VAYU_PLOTS_DIR / f"vayu_{stamp}_{secrets.token_hex(4)}.png"


def _validate_date(expr: str) -> str:
    """Validate and return a date expression, or raise ValueError."""
    expr = _sanitize(expr).strip()
    if not _DATE_EXPR_RE.match(expr):
        raise ValueError(f"Invalid date expression: {expr!r}")
    return expr


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
) -> dict:
    """Call an R plot function and return base64-encoded PNG.

    Returns a dict with type="plot", base64 image data, and summary text.
    """
    _prepare_plot_dir()
    png_path = _new_plot_path()

    raw = _run_r(func, args, plot=True, plot_path=png_path, timeout=timeout)

    if raw.get("type") == "error":
        return raw

    if not png_path.exists():
        return {"type": "error", "message": "Plot file not found"}

    try:
        png_data = png_path.read_bytes()
        b64 = base64.b64encode(png_data).decode("ascii")
    finally:
        try:
            png_path.unlink()
        except OSError as e:
            logger.debug("Failed to unlink %s: %s", png_path, e)

    return {
        "type": "plot",
        "base64": b64,
        "media_type": "image/png",
        "func": func,
    }
