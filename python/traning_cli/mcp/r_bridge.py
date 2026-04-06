"""R bridge — subprocess helpers for calling R functions from the MCP server."""

import base64
import json
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

TRANING_ROOT = Path(__file__).resolve().parent.parent.parent.parent
MCP_BRIDGE_R = TRANING_ROOT / "inst" / "mcp_bridge.R"

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
})


def _sanitize(value: str) -> str:
    """Strip control characters from a string."""
    return re.sub(r"[\x00-\x1f\x7f]", "", str(value))


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
    timeout: int = 120,
) -> dict:
    """Call an R function via mcp_bridge.R and return parsed JSON result.

    Args:
        func: Function name (must be in _KNOWN_FUNCTIONS).
        args: Dict of arguments to pass as JSON.
        plot: If True, request PNG plot output.
        timeout: Subprocess timeout in seconds (clamped to 10-300).

    Returns:
        Parsed JSON dict from R stdout.
    """
    if func not in _KNOWN_FUNCTIONS:
        return {"type": "error", "message": f"Unknown function: {func}"}

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
        cmd.append("--plot")

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
    raw = _run_r(func, args, plot=True, timeout=timeout)

    if raw.get("type") == "error":
        return raw

    png_path = raw.get("path")
    if not png_path or not Path(png_path).exists():
        return {"type": "error", "message": "Plot file not found"}

    try:
        png_data = Path(png_path).read_bytes()
        b64 = base64.b64encode(png_data).decode("ascii")
    finally:
        # Clean up temp file
        try:
            Path(png_path).unlink()
        except OSError:
            pass

    return {
        "type": "plot",
        "base64": b64,
        "media_type": "image/png",
        "func": func,
    }
