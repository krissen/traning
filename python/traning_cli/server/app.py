"""FastAPI application for receiving HAE health data."""

import logging
import os
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from .auth import require_api_key
from .notify import log_notification, notify
from .storage import commit_health_data, save_health_push, save_workout_push

log = logging.getLogger(__name__)

# Path to Rscript CLI
_CLI_R = Path(__file__).resolve().parent.parent.parent.parent / "inst" / "cli.R"


def _run_import_garmin() -> tuple[str, str | None]:
    """Run R import to rebuild Garmin summaries.RData cache.

    Returns (summary, error). On success, summary is the human-readable
    import line ("Import: 1 pass (22 apr), 6.5 km totalt.") or "klart".
    On failure, error contains a short reason and summary is "".
    """
    cmd = ["Rscript", str(_CLI_R), "--import"]
    t0 = time.time()
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300,
        )
        elapsed = int(time.time() - t0)
        if result.returncode != 0:
            log.warning("Import garmin failed (%ds): %s",
                        elapsed, result.stderr.strip()[-300:])
            return "", "MISSLYCKADES"
        log.info("Import garmin OK (%ds)", elapsed)
        lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
        summary = "klart"
        for line in reversed(lines):
            low = line.lower()
            if any(w in low for w in ["import", "inget att"]):
                summary = line.strip()
                break
        return summary, None
    except subprocess.TimeoutExpired:
        elapsed = int(time.time() - t0)
        log.warning("Import garmin timed out after %ds", elapsed)
        return "", f"timeout efter {elapsed // 60} min"


def _run_insight_garmin() -> str:
    """Generate a short insight string from cached summaries. Returns "" on failure."""
    cmd = ["Rscript", "-e", (
        'devtools::load_all(".", quiet=TRUE); '
        'td <- Sys.getenv("TRANING_DATA"); '
        'tl <- my_dbs_load(file.path(td,"cache","summaries.RData"), '
        'file.path(td,"cache","myruns.RData")); '
        'cat(report_insight(tl[["summaries"]]))'
    )]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120,
            cwd=str(_CLI_R.parent.parent),
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        log.warning("Insight garmin failed: %s", result.stderr.strip()[-200:])
        return ""
    except subprocess.TimeoutExpired:
        log.warning("Insight garmin timed out")
        return ""


def _compose_garmin_message(import_summary: str, insight: str) -> str:
    """Combine the import summary and insight into one notification line.

    For a single-pass import the summary duplicates the insight, so the
    insight alone is used. For multi-pass batches the import line is kept
    as a prefix to give the bulk context. Returns "" when there is nothing
    informative to say (caller should skip the notification).
    """
    summary_low = import_summary.lower()
    nothing_imported = (
        not import_summary
        or import_summary == "klart"
        or "inget att" in summary_low
    )
    if not insight:
        return "" if nothing_imported else import_summary
    if nothing_imported or summary_low.startswith("import: 1 pass"):
        return insight
    return f"{import_summary} {insight}"

_import_lock = threading.Lock()


def _import_and_notify(files: list, kind: str = "health"):
    """Import files via R and notify only if there is something to report.

    No notification when the delta insight is empty — silent success
    avoids spamming "X filer importerade" when nothing meaningful changed.
    Errors and timeouts always notify (and log).
    """
    if not files:
        return

    with _import_lock:
        paths_str = ", ".join(f'"{f}"' for f in files)
        r_expr = (
            'devtools::load_all(".", quiet=TRUE); '
            'before <- load_health_data(); '
            f'after <- import_health_export(path = c({paths_str}), verbose = FALSE); '
            'cat(health_insight_delta(before, after))'
        )
        cmd = ["Rscript", "-e", r_expr]
        t0 = time.time()
        title = "tRäning"
        message: str | None = None

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=120,
                cwd=str(_CLI_R.parent.parent),
            )
            elapsed = int(time.time() - t0)

            if result.returncode != 0:
                log.warning("Import+insight failed (%ds): %s",
                            elapsed, result.stderr.strip()[-300:])
                message = f"Hälsoimport: MISSLYCKADES ({elapsed}s)"
            elif result.stdout.strip():
                message = result.stdout.strip()
            else:
                log.info("Import+insight: no meaningful delta from %d files",
                         len(files))

        except subprocess.TimeoutExpired:
            elapsed = int(time.time() - t0)
            log.warning("Import+insight timed out after %ds", elapsed)
            message = f"Hälsoimport: timeout efter {elapsed // 60} min"
        except Exception:
            log.exception("Import+insight unexpected error")
            message = "Hälsoimport: oväntat fel"

        if message is None:
            return

        sent = notify(title, message)
        log_notification(
            trigger="health_push",
            title=title,
            message=message,
            sent=sent,
        )


# --- Debounced health import ------------------------------------------------
#
# HAE drops metrics in several batches across the day. Running the R import
# (and notifying) on every push is noisy. We accumulate changed files in a
# pending set and (re)start a debounce timer; the import runs once after the
# pushes go quiet for a while.

_DEBOUNCE_SECS = int(os.environ.get("TRANING_HEALTH_DEBOUNCE", "600"))
_pending_files: set[str] = set()
_pending_timer: threading.Timer | None = None
_pending_lock = threading.Lock()


def _flush_pending_health() -> None:
    """Run the accumulated import. Called by the debounce timer."""
    global _pending_timer
    with _pending_lock:
        files = list(_pending_files)
        _pending_files.clear()
        _pending_timer = None
    if files:
        _import_and_notify(files, "health")


def _schedule_health_import(files: list[str]) -> None:
    """Add files to the pending set and (re)start the debounce timer."""
    global _pending_timer
    if not files:
        return
    with _pending_lock:
        _pending_files.update(files)
        if _pending_timer is not None:
            _pending_timer.cancel()
        _pending_timer = threading.Timer(_DEBOUNCE_SECS, _flush_pending_health)
        _pending_timer.daemon = True
        _pending_timer.start()


# Track state for /v1/status endpoint
_start_time = time.time()
_last_received: datetime | None = None
_total_received: int = 0


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    application = FastAPI(
        title="tRäning Health Receiver",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
    )

    @application.get("/health")
    async def healthcheck():
        return {"status": "ok"}


    @application.get("/v1/status", dependencies=[Depends(require_api_key)])
    async def status():
        return {
            "uptime_seconds": int(time.time() - _start_time),
            "last_received": _last_received.isoformat() if _last_received else None,
            "total_pushes": _total_received,
        }

    @application.post("/v1/health", dependencies=[Depends(require_api_key)])
    async def receive_health(request: Request):
        global _last_received, _total_received

        try:
            payload = await request.json()
        except Exception:
            raise HTTPException(status_code=422, detail="Invalid JSON")

        # Validate HAE format
        data = payload.get("data")
        if not isinstance(data, dict) or "metrics" not in data:
            raise HTTPException(
                status_code=422,
                detail="Expected HAE format: {\"data\": {\"metrics\": [...]}}"
            )

        metrics = data["metrics"]
        if not isinstance(metrics, list) or len(metrics) == 0:
            raise HTTPException(status_code=422, detail="No metrics in payload")

        n, changed_files = save_health_push(payload)
        if n > 0:
            commit_health_data(n_metrics=n)
            _schedule_health_import(changed_files)

        _last_received = datetime.now()
        _total_received += 1

        total_samples = sum(len(m.get("data", [])) for m in metrics)
        log.info("Received %d metrics, %d samples", n, total_samples)

        return {
            "status": "ok",
            "metrics_saved": n,
            "total_samples": total_samples,
        }

    @application.post("/v1/workouts", dependencies=[Depends(require_api_key)])
    async def receive_workouts(request: Request):
        global _last_received, _total_received

        try:
            payload = await request.json()
        except Exception:
            raise HTTPException(status_code=422, detail="Invalid JSON")

        data = payload.get("data")
        if not isinstance(data, dict) or "workouts" not in data:
            raise HTTPException(
                status_code=422,
                detail="Expected HAE format: {\"data\": {\"workouts\": [...]}}"
            )

        workouts = data["workouts"]
        if not isinstance(workouts, list) or len(workouts) == 0:
            raise HTTPException(status_code=422, detail="No workouts in payload")

        n = save_workout_push(payload)
        if n > 0:
            commit_health_data(n_workouts=n)

        _last_received = datetime.now()
        _total_received += 1

        log.info("Received %d workouts", n)

        return {
            "status": "ok",
            "workouts_saved": n,
        }

    @application.post("/v1/trigger/garmin", dependencies=[Depends(require_api_key)])
    async def trigger_garmin(background_tasks: BackgroundTasks):
        """Trigger a Garmin fetch in the background."""
        def _run_fetch():
            traning_bin = Path(__file__).resolve().parent.parent.parent.parent / "python" / ".venv" / "bin" / "traning"
            result = subprocess.run(
                [str(traning_bin), "fetch", "garmin"],
                capture_output=True, text=True, timeout=120,
            )
            log.info("Garmin fetch: %s", result.stdout.strip())
            if result.returncode != 0:
                log.warning("Garmin fetch stderr: %s", result.stderr.strip())

            # No new activities → no notification, no re-import needed.
            if "fetched 0" in result.stdout:
                return

            import_summary, import_error = _run_import_garmin()
            if import_error:
                msg = f"Garmin import: {import_error}"
                sent = notify("tRäning", msg)
                log_notification("garmin", "tRäning", msg, sent)
                return

            insight = _run_insight_garmin()
            msg = _compose_garmin_message(import_summary, insight)
            if msg:
                sent = notify("tRäning", msg)
                log_notification("garmin", "tRäning", msg, sent)

        background_tasks.add_task(_run_fetch)
        return {"status": "ok", "message": "Garmin fetch triggered"}

    return application
