"""FastAPI application for receiving HAE health data."""

import logging
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


def _run_import_garmin():
    """Run R import to rebuild Garmin summaries.RData cache."""
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
            msg = "Import garmin: MISSLYCKADES"
            sent = notify("tRäning", msg)
            log_notification("import", "tRäning", msg, sent)
        else:
            log.info("Import garmin OK (%ds)", elapsed)
            lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
            summary = "klart"
            for line in reversed(lines):
                low = line.lower()
                if any(w in low for w in ["import", "inget att"]):
                    summary = line.strip()
                    break
            msg = f"Import garmin: {summary}"
            sent = notify("tRäning", msg)
            log_notification("import", "tRäning", msg, sent)
    except subprocess.TimeoutExpired:
        elapsed = int(time.time() - t0)
        log.warning("Import garmin timed out after %ds", elapsed)
        msg = f"Import garmin: timeout efter {elapsed // 60} min"
        sent = notify("tRäning", msg)
        log_notification("import", "tRäning", msg, sent)


def _run_insight_garmin():
    """Generate and send a short insight notification after Garmin import."""
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
            msg = result.stdout.strip()
            sent = notify("tRäning", msg)
            log_notification("insight_garmin", "tRäning", msg, sent)
        else:
            log.warning("Insight garmin failed: %s", result.stderr.strip()[-200:])
            log_notification(
                "insight_garmin", "tRäning", "(insight failed)",
                False, error=result.stderr.strip()[-200:],
            )
    except subprocess.TimeoutExpired:
        log.warning("Insight garmin timed out")
        log_notification(
            "insight_garmin", "tRäning", "(insight timeout)", False,
            error="timeout",
        )

_import_lock = threading.Lock()


def _import_and_notify(files: list, kind: str = "health"):
    """Import files via R, generate delta insight, always send notification."""
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
                message = f"{len(files)} filer importerade \u2705"

        except subprocess.TimeoutExpired:
            elapsed = int(time.time() - t0)
            log.warning("Import+insight timed out after %ds", elapsed)
            message = f"Hälsoimport: timeout efter {elapsed // 60} min"
        except Exception as e:
            log.exception("Import+insight unexpected error")
            message = "Hälsoimport: oväntat fel"

        sent = notify(title, message)
        log_notification(
            trigger="health_push",
            title=title,
            message=message,
            sent=sent,
        )


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
    async def receive_health(request: Request, background_tasks: BackgroundTasks):
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
            background_tasks.add_task(_import_and_notify, changed_files, "health")

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
    async def receive_workouts(request: Request, background_tasks: BackgroundTasks):
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
            msg = f"Workouts: {n} mottagna"
            sent = notify("tRäning", msg)
            log_notification("workout", "tRäning", msg, sent)

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
            if "fetched 0" not in result.stdout:
                msg = f"Garmin fetch: {result.stdout.strip().splitlines()[-1]}"
                sent = notify("tRäning", msg)
                log_notification("garmin_trigger", "tRäning", msg, sent)
            log.info("Garmin fetch: %s", result.stdout.strip())
            if result.returncode != 0:
                log.warning("Garmin fetch stderr: %s", result.stderr.strip())
            _run_import_garmin()
            _run_insight_garmin()

        background_tasks.add_task(_run_fetch)
        return {"status": "ok", "message": "Garmin fetch triggered"}

    return application
