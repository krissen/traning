"""FastAPI application for receiving HAE health data."""

import logging
import subprocess
import time
from datetime import datetime
from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from .auth import require_api_key
from .notify import notify
from .storage import commit_health_data, save_health_push, save_workout_push

log = logging.getLogger(__name__)

# Path to Rscript CLI
_CLI_R = Path(__file__).resolve().parent.parent.parent.parent / "inst" / "cli.R"


def _run_import(kind: str = "all"):
    """Run R import to rebuild RData cache.

    Args:
        kind: "garmin", "health", or "all".
    """
    labels = {"--import": "garmin", "--import-health": "hälsa"}
    flags = {
        "garmin": ["--import"],
        "health": ["--import-health"],
        "all":    ["--import", "--import-health"],
    }
    for flag in flags.get(kind, flags["all"]):
        label = labels.get(flag, flag)
        cmd = ["Rscript", str(_CLI_R), flag]
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=300,
            )
            if result.returncode != 0:
                log.warning("Import %s failed: %s", flag, result.stderr.strip()[-300:])
                notify("tRäning", f"Import {label}: MISSLYCKADES")
            else:
                log.info("Import %s OK", flag)
                # Extract summary from R output (last non-empty line)
                lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
                summary = lines[-1] if lines else "klart"
                notify("tRäning", f"Import {label}: {summary}")
        except subprocess.TimeoutExpired:
            log.warning("Import %s timed out", flag)
            notify("tRäning", f"Import {label}: timeout efter 5 min")


def _run_insight(kind: str):
    """Generate and send a short insight notification after import."""
    if kind == "garmin":
        cmd = ["Rscript", "-e", (
            'devtools::load_all(".", quiet=TRUE); '
            'td <- Sys.getenv("TRANING_DATA"); '
            'tl <- my_dbs_load(file.path(td,"cache","summaries.RData"), '
            'file.path(td,"cache","myruns.RData")); '
            'cat(report_insight(tl[["summaries"]]))'
        )]
    elif kind == "health":
        cmd = ["Rscript", "-e", (
            'devtools::load_all(".", quiet=TRUE); '
            'h <- load_health_data(); '
            'if (!is.null(h) && nrow(h) > 0) { '
            'latest <- h[which.max(h$date),]; '
            'cat(sprintf("Hälsa: %s — vila %s bpm, HRV %s ms, sömn %s h", '
            'format(latest$date), '
            'ifelse(is.na(latest$resting_hr), "?", round(latest$resting_hr)), '
            'ifelse(is.na(latest$hrv), "?", round(latest$hrv)), '
            'ifelse(is.na(latest$sleep_hours), "?", round(latest$sleep_hours, 1)))) '
            '} else cat("Hälsodata importerad.")'
        )]
    else:
        return

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120,
            cwd=str(_CLI_R.parent.parent),
        )
        if result.returncode == 0 and result.stdout.strip():
            notify("tRäning", result.stdout.strip())
        else:
            log.warning("Insight %s failed: %s", kind, result.stderr.strip()[-200:])
    except subprocess.TimeoutExpired:
        log.warning("Insight %s timed out", kind)

def _import_and_insight(kind: str):
    """Run import followed by insight notification."""
    _run_import(kind)
    _run_insight(kind)


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

        n = save_health_push(payload)
        if n > 0:
            commit_health_data(n_metrics=n)
            background_tasks.add_task(_import_and_insight, "health")
            notify("tRäning", f"Hälsodata: {n} metrics mottagna")

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
            background_tasks.add_task(_import_and_insight, "health")
            notify("tRäning", f"Workouts: {n} mottagna")

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
                notify("tRäning", f"Garmin fetch: {result.stdout.strip().splitlines()[-1]}")
            log.info("Garmin fetch: %s", result.stdout.strip())
            if result.returncode != 0:
                log.warning("Garmin fetch stderr: %s", result.stderr.strip())
            _run_import("garmin")
            _run_insight("garmin")

        background_tasks.add_task(_run_fetch)
        return {"status": "ok", "message": "Garmin fetch triggered"}

    return application
