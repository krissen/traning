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
    timeouts = {"--import": 300, "--import-health": None}
    flags = {
        "garmin": ["--import"],
        "health": ["--import-health"],
        "all":    ["--import", "--import-health"],
    }
    for flag in flags.get(kind, flags["all"]):
        label = labels.get(flag, flag)
        cmd = ["Rscript", str(_CLI_R), flag]
        t0 = time.time()
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True,
                timeout=timeouts.get(flag, 600),
            )
            elapsed = int(time.time() - t0)
            if result.returncode != 0:
                log.warning("Import %s failed (%ds): %s",
                            flag, elapsed, result.stderr.strip()[-300:])
                notify("tRäning", f"Import {label}: MISSLYCKADES")
            else:
                log.info("Import %s OK (%ds)", flag, elapsed)
                # Extract last meaningful line from R output
                lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
                summary = "klart"
                for line in reversed(lines):
                    low = line.lower()
                    if any(w in low for w in ["import", "inget att"]):
                        summary = line.strip()
                        break
                notify("tRäning", f"Import {label}: {summary}")
        except subprocess.TimeoutExpired:
            elapsed = int(time.time() - t0)
            log.warning("Import %s timed out after %ds", flag, elapsed)
            notify("tRäning", f"Import {label}: timeout efter {elapsed // 60} min")


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
            'latest_date <- max(h$date); '
            'today <- h[h$date == latest_date,]; '
            'get_val <- function(m) { v <- today$value[today$metric == m]; '
            'if (length(v) == 0 || is.na(v[1])) NA else round(v[1], 1) }; '
            'parts <- c(); '
            'rhr <- get_val("resting_heart_rate"); '
            'if (!is.na(rhr)) parts <- c(parts, paste0("vila ", rhr, " bpm")); '
            'hrv <- get_val("heart_rate_variability"); '
            'if (!is.na(hrv)) parts <- c(parts, paste0("HRV ", hrv, " ms")); '
            'slp <- get_val("sleep_totalSleep"); '
            'if (!is.na(slp)) parts <- c(parts, paste0("s\\u00f6mn ", slp, " h")); '
            'if (length(parts) > 0) { '
            'cat(paste0("H\\u00e4lsa ", format(latest_date), ": ", '
            'paste(parts, collapse = ", "))) '
            '} else cat("H\\u00e4lsodata importerad, inga nyckelm\\u00e4tvärden f\\u00f6r ", '
            'format(latest_date), ".")'
            '} else cat("H\\u00e4lsodata importerad.")'
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

def _import_files(files: list, kind: str = "health"):
    """Import specific changed files into the R cache, then run insight."""
    if not files:
        return
    # Pass file paths to R for targeted import
    paths_str = ", ".join(f'"{f}"' for f in files)
    r_expr = (
        'devtools::load_all(".", quiet=TRUE); '
        f'import_health_export(path = c({paths_str}))'
    )
    cmd = ["Rscript", "-e", r_expr]
    t0 = time.time()
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120,
            cwd=str(_CLI_R.parent.parent),
        )
        elapsed = int(time.time() - t0)
        if result.returncode != 0:
            log.warning("Import %d files failed (%ds): %s",
                        len(files), elapsed, result.stderr.strip()[-300:])
            notify("tRäning", "Import hälsa: MISSLYCKADES")
        else:
            log.info("Import %d files OK (%ds)", len(files), elapsed)
    except subprocess.TimeoutExpired:
        elapsed = int(time.time() - t0)
        log.warning("Import timed out after %ds", elapsed)
    _run_insight(kind)


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

        n, changed_files = save_health_push(payload)
        if n > 0:
            commit_health_data(n_metrics=n)
            background_tasks.add_task(_import_files, changed_files, "health")
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
