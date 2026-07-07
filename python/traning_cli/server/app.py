"""FastAPI application for receiving HAE health data."""

import json
import logging
import os
import subprocess
import tempfile
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from .auth import require_api_key
from .notify import log_notification, notify
from .state import (
    load_notify_state,
    load_pending_state,
    mark_morning_sent,
    mark_update_sent,
    save_notify_state,
    save_pending_state,
)
from .storage import commit_health_data, save_health_push, save_workout_push

log = logging.getLogger(__name__)

# Path to Rscript CLI + notify helper
_CLI_R = Path(__file__).resolve().parent.parent.parent.parent / "inst" / "cli.R"
_NOTIFY_HELPER_R = (
    Path(__file__).resolve().parent.parent.parent.parent / "inst" / "notify_helper.R"
)


def _run_import_garmin() -> tuple[str, str | None]:
    """Run R import to rebuild Garmin summaries.RData cache.

    Returns (summary, error). On success, summary is the human-readable
    import line ("Import: 1 pass (22 apr), 6.5 km totalt.") or "klart".
    On failure, error contains a short reason and summary is "".

    Acquires the global ``_import_lock`` so a Garmin-trigger import and
    the debounced HAE auto-import (``_flush_pending_workouts``) cannot
    rebuild the cache concurrently. Both paths shell out to the same
    ``cli.R --import`` script, which is not safe to run twice in
    parallel — the second writer can clobber the first's partial state.
    """
    cmd = ["Rscript", str(_CLI_R), "--import"]
    t0 = time.time()
    with _import_lock:
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
            lines = [raw_line for raw_line in result.stdout.strip().splitlines()
                     if raw_line.strip()]
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
    """Import files via R and emit a state-aware notification.

    First flush of the day → readiness/state notification.
    Subsequent flushes → silent unless an update trigger fires (re-render
    after partial morning, or a tier-1 metric not yet reported).
    Errors always notify.
    """
    if not files:
        return

    with _import_lock:
        state = load_notify_state()

        prev_path: str | None = None
        if state.get("morning_sent"):
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".json", delete=False, encoding="utf-8"
            ) as tf:
                json.dump(state, tf, ensure_ascii=False)
                prev_path = tf.name

        cmd = [
            "Rscript", str(_NOTIFY_HELPER_R),
            f"--files={','.join(files)}",
        ]
        if prev_path:
            cmd.append(f"--prev-state={prev_path}")

        t0 = time.time()
        title = "tRäning"
        message: str | None = None
        result_dict: dict | None = None
        trigger_label = (
            "health_morning" if not state.get("morning_sent") else "health_update"
        )

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=180,
                cwd=str(_CLI_R.parent.parent),
            )
            elapsed = int(time.time() - t0)

            if result.returncode != 0:
                log.warning("notify_helper failed (%ds): %s",
                            elapsed, result.stderr.strip()[-300:])
                message = f"Hälsoimport: MISSLYCKADES ({elapsed}s)"
            else:
                stdout = result.stdout.strip()
                if not stdout:
                    log.info("notify_helper: empty output (%ds)", elapsed)
                else:
                    try:
                        result_dict = json.loads(stdout)
                    except Exception:
                        log.warning("notify_helper: failed to parse JSON: %.300s",
                                    stdout)
                    if result_dict:
                        kind_field = result_dict.get("kind")
                        if kind_field == "error":
                            err = result_dict.get("error", "okänt fel")
                            log.warning("notify_helper R error: %s", err)
                            message = f"Hälsoimport: {err[:120]}"
                        else:
                            prosa = (result_dict.get("prosa") or "").strip()
                            if prosa:
                                message = prosa
                            elif kind_field == "update":
                                log.info(
                                    "notify_helper: silent flush (no update trigger)"
                                )
                            else:
                                log.info(
                                    "notify_helper: empty readiness prose (no data)"
                                )

        except subprocess.TimeoutExpired:
            elapsed = int(time.time() - t0)
            log.warning("notify_helper timed out after %ds", elapsed)
            message = f"Hälsoimport: timeout efter {elapsed // 60} min"
        except Exception:
            log.exception("notify_helper unexpected error")
            message = "Hälsoimport: oväntat fel"
        finally:
            if prev_path:
                try:
                    os.unlink(prev_path)
                except OSError:
                    pass

        if message is None:
            # Successful silent flush — nothing to send, log empty notification
            log_notification(
                trigger=trigger_label,
                title=title,
                message="",
                sent=False,
            )
            return

        sent = notify(title, message)
        log_notification(
            trigger=trigger_label,
            title=title,
            message=message,
            sent=sent,
        )

        # Update state if R returned a structured result
        if result_dict and result_dict.get("kind") in ("readiness", "update"):
            try:
                if result_dict.get("kind") == "readiness":
                    mark_morning_sent(state, result_dict)
                else:
                    mark_update_sent(state, result_dict)
                save_notify_state(state)
            except Exception:
                log.exception("notify_helper: failed to update notify state")


# --- Debounced health import ------------------------------------------------
#
# HAE drops metrics in several batches across the day. Running the R import
# (and notifying) on every push is noisy. We accumulate changed files in a
# pending set and (re)start a debounce timer; the import runs once after the
# pushes go quiet for a while.
#
# The pending set/counter below are in-memory only, so on their own they
# are lost if the receiver restarts while work is queued (uvicorn reload,
# deploy, crash). To survive that, every mutation is mirrored to
# ``$TRANING_DATA/.pending_state.json`` (see state.py, same atomic
# tmp+rename pattern as .notify_state.json), and ``_resume_pending_state``
# reloads it and re-arms the debounce timers on startup.

_DEBOUNCE_SECS = int(os.environ.get("TRANING_HEALTH_DEBOUNCE", "600"))
_pending_files: set[str] = set()
_pending_timer: threading.Timer | None = None
_pending_lock = threading.Lock()


def _persist_pending_state() -> None:
    """Mirror the current in-memory pending state to disk.

    Called after every mutation of ``_pending_files`` or
    ``_pending_workouts_count`` (outside the lock that guarded the
    mutation, to keep lock hold times short) so a receiver restart can
    resume queued work via ``_resume_pending_state``.
    """
    with _pending_lock:
        files = sorted(_pending_files)
    with _workouts_lock:
        count = _pending_workouts_count
    save_pending_state({"pending_files": files, "pending_workouts_count": count})


def _flush_pending_health() -> None:
    """Run the accumulated import. Called by the debounce timer."""
    global _pending_timer, _last_import_ts, _last_import_files
    with _pending_lock:
        files = list(_pending_files)
        _pending_files.clear()
        _pending_timer = None
    _persist_pending_state()
    if files:
        _import_and_notify(files, "health")
        _last_import_ts = datetime.now()
        _last_import_files = len(files)


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
    _persist_pending_state()


# --- Debounced HAE workout import -------------------------------------------
#
# HAE workouts arrive via /v1/workouts and previously sat on disk until the
# next Garmin-fetch triggered import_hae_workouts() as a side effect. On
# rest days that meant workouts accumulated for 1–3 days and arrived in a
# single bunt on the next Garmin run — visible to the user as
# "Import: 16 pass (...)" notifications. We now run a silent debounced
# import on every workout push so the cache is current within ~10 min.
#
# Silent by design: per-pass notifications remain Garmin-exclusive. The
# 21:30 day-summary picks the HAE rows up as usual; here we only ensure
# they reach summaries.RData in time.

_DEBOUNCE_WORKOUTS_SECS = int(os.environ.get(
    "TRANING_WORKOUTS_DEBOUNCE", str(_DEBOUNCE_SECS)
))
_pending_workouts_count: int = 0
_workouts_timer: threading.Timer | None = None
_workouts_lock = threading.Lock()
# Guards against two overlapping flushes (e.g. the debounce timer firing
# again a hair before a prior, slow — up to 300s — import finishes): without
# it, a second flush could snapshot the same not-yet-decremented count and
# double-process/double-decrement it.
_workouts_flushing: bool = False


_last_workouts_import_ts: datetime | None = None
_last_workouts_import_count: int = 0


def _decrement_after_flush(current: int, n: int, ok: bool) -> int:
    """Compute the pending-workouts count after a flush attempt.

    Only ever subtracts ``n`` — the snapshot taken atomically at the start
    of the flush — never the live counter value. Pushes that arrive while
    the (up to 300s) import is running increment ``current`` concurrently;
    subtracting the snapshot instead of re-reading "what's pending now"
    means those new pushes survive the flush intact rather than being
    silently absorbed or lost. On failure the count is left untouched so
    the whole batch (old + any new arrivals) retries on the next flush.
    """
    if not ok:
        return current
    return max(0, current - n)


def _flush_pending_workouts() -> None:
    """Silently rebuild summaries.RData via `cli.R --import`.

    Shares the global ``_import_lock`` with the Garmin-trigger path so the
    two cannot race. Failure is logged to journal; no notification is
    sent — HAE pushes are dags-kontext, not per-pass events.

    The pending counter is only decremented after a successful import.
    On failure the counter is left intact and surfaced via /v1/status's
    ``pending_workouts`` field so the next workout push reschedules the
    timer and the import is retried then.
    """
    global _workouts_timer, _pending_workouts_count, _workouts_flushing
    global _last_workouts_import_ts, _last_workouts_import_count
    with _workouts_lock:
        if _workouts_flushing:
            log.debug("HAE auto-import: flush already in progress, skipping")
            return
        n = _pending_workouts_count
        _workouts_timer = None
        if n <= 0:
            return
        _workouts_flushing = True

    # Everything from here on must run inside try/finally: any unhandled
    # exception (including from _persist_pending_state()/disk errors, not
    # just the subprocess call) must still clear _workouts_flushing —
    # otherwise the guard sticks forever and every future flush silently
    # early-returns, so workouts stop importing until the receiver restarts.
    ok = False
    try:
        _persist_pending_state()

        t0 = time.time()
        with _import_lock:
            try:
                result = subprocess.run(
                    ["Rscript", str(_CLI_R), "--import"],
                    capture_output=True, text=True, timeout=300,
                    cwd=str(_CLI_R.parent.parent),
                )
                elapsed = int(time.time() - t0)
                if result.returncode != 0:
                    log.warning(
                        "HAE auto-import failed (%ds, %d pending): %s",
                        elapsed, n, result.stderr.strip()[-300:],
                    )
                else:
                    ok = True
                    # Surface the trailing import-summary line for journal logs.
                    lines = [line.strip() for line in result.stdout.strip().splitlines()
                             if line.strip()]
                    summary = next(
                        (line for line in reversed(lines)
                         if any(w in line.lower() for w in ["import", "inget att"])),
                        "klart",
                    )
                    log.info("HAE auto-import OK (%ds, %d pending): %s",
                             elapsed, n, summary)
            except subprocess.TimeoutExpired:
                elapsed = int(time.time() - t0)
                log.warning("HAE auto-import timed out after %ds (%d pending)",
                            elapsed, n)
            except Exception:
                log.exception("HAE auto-import: unexpected error")

        # /v1/status bookkeeping. Track workout imports in dedicated fields
        # so we don't conflate health "files imported" with workout
        # "pending count" semantics on the shared _last_import_* fields.
        # Timestamp updates on every attempt (matches _flush_pending_health
        # behaviour) so an attempted-but-failed import is still visible.
        # The pending counter is only drained on success; a failed run keeps
        # it surfaced for the next push to retry.
        _last_workouts_import_ts = datetime.now()
        _last_workouts_import_count = n
    finally:
        # Always reset the guard and persist the resulting state, even if
        # something above raised. On the normal path ok reflects whether
        # the import actually succeeded; on an early exception ok is still
        # False, so the snapshot n is left un-decremented and the batch
        # retries on the next push (same contract as an R-side failure).
        with _workouts_lock:
            _pending_workouts_count = _decrement_after_flush(
                _pending_workouts_count, n, ok
            )
            _workouts_flushing = False
        _persist_pending_state()


def _schedule_workouts_import(n_new: int) -> None:
    """Note new workouts and (re)start the debounce timer."""
    global _workouts_timer, _pending_workouts_count
    if n_new <= 0:
        return
    with _workouts_lock:
        _pending_workouts_count += n_new
        if _workouts_timer is not None:
            _workouts_timer.cancel()
        _workouts_timer = threading.Timer(
            _DEBOUNCE_WORKOUTS_SECS, _flush_pending_workouts
        )
        _workouts_timer.daemon = True
        _workouts_timer.start()
    _persist_pending_state()


def _resume_pending_state() -> None:
    """Reload persisted pending state and re-arm debounce timers.

    Called once at startup so work queued before a receiver restart
    (health files awaiting import, workouts awaiting the debounced
    ``cli.R --import``) is not silently dropped — it resumes with a
    fresh full debounce window rather than being lost.
    """
    global _pending_timer, _workouts_timer, _pending_workouts_count
    persisted = load_pending_state()
    files = persisted.get("pending_files") or []
    count = persisted.get("pending_workouts_count") or 0

    if files:
        with _pending_lock:
            _pending_files.update(files)
            if _pending_timer is not None:
                _pending_timer.cancel()
            _pending_timer = threading.Timer(_DEBOUNCE_SECS, _flush_pending_health)
            _pending_timer.daemon = True
            _pending_timer.start()
        log.info("Resumed %d pending health file(s) after restart", len(files))

    if count > 0:
        with _workouts_lock:
            _pending_workouts_count += count
            if _workouts_timer is not None:
                _workouts_timer.cancel()
            _workouts_timer = threading.Timer(
                _DEBOUNCE_WORKOUTS_SECS, _flush_pending_workouts
            )
            _workouts_timer.daemon = True
            _workouts_timer.start()
        log.info("Resumed %d pending workout(s) after restart", count)


# Track state for /v1/status endpoint
_start_time = time.time()
_last_received: datetime | None = None
_total_received: int = 0
_last_import_ts: datetime | None = None
_last_import_files: int = 0


@asynccontextmanager
async def _lifespan(application: FastAPI):
    _resume_pending_state()
    yield


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    application = FastAPI(
        title="tRäning Health Receiver",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        lifespan=_lifespan,
    )

    @application.get("/health")
    async def healthcheck():
        return {"status": "ok"}


    @application.get("/v1/status", dependencies=[Depends(require_api_key)])
    async def status():
        with _pending_lock:
            pending_count = len(_pending_files)
            timer_armed = _pending_timer is not None
        with _workouts_lock:
            pending_workouts = _pending_workouts_count
            workouts_timer_armed = _workouts_timer is not None
        return {
            "uptime_seconds": int(time.time() - _start_time),
            "last_received": _last_received.isoformat() if _last_received else None,
            "total_pushes": _total_received,
            "last_import": _last_import_ts.isoformat() if _last_import_ts else None,
            "last_import_files": _last_import_files,
            "pending_files": pending_count,
            "pending_timer_armed": timer_armed,
            "debounce_seconds": _DEBOUNCE_SECS,
            "pending_workouts": pending_workouts,
            "workouts_timer_armed": workouts_timer_armed,
            "workouts_debounce_seconds": _DEBOUNCE_WORKOUTS_SECS,
            "last_workouts_import": (
                _last_workouts_import_ts.isoformat()
                if _last_workouts_import_ts else None
            ),
            "last_workouts_import_count": _last_workouts_import_count,
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
            # save_health_push returns Path objects; downstream join + R CLI
            # need plain strings.
            _schedule_health_import([str(f) for f in changed_files])

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
            # Schedule a silent debounced import so HAE workouts hit
            # summaries.RData without waiting for the next Garmin fetch.
            _schedule_workouts_import(n)

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
            traning_bin = (
                Path(__file__).resolve().parent.parent.parent.parent
                / "python" / ".venv" / "bin" / "traning"
            )
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
