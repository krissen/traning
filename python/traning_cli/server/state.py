"""Persistent notification state.

Tracks today's notification status so that follow-up flushes can decide
whether to send an update (re-render after partial morning, tier-1 metric
not yet reported) or stay silent.

State file: ``$TRANING_DATA/.notify_state.json``. Atomic write via tmp+rename.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import date
from pathlib import Path
from typing import Any

from ..settings import get_settings

log = logging.getLogger(__name__)

_STATE_FILENAME = ".notify_state.json"


def _state_path() -> Path | None:
    data_dir = get_settings().traning_data
    if not data_dir:
        return None
    return Path(data_dir) / _STATE_FILENAME


def _today_str() -> str:
    return date.today().isoformat()


def empty_state(today: str | None = None) -> dict[str, Any]:
    """Return a fresh state dict for the given day (default: today)."""
    return {
        "date": today or _today_str(),
        "morning_sent": False,
        "morning_kvalitet": None,
        "morning_components": {},
        "morning_status": None,
        "morning_score": None,
        "afternoon_updates_sent": [],
        "day_summary_sent": False,
    }


def load_notify_state() -> dict[str, Any]:
    """Read state from disk, rolling over if the date is stale.

    Returns an empty state for today if the file is missing, malformed, or
    its ``date`` field is older than today. Never raises.
    """
    today = _today_str()
    path = _state_path()
    if path is None or not path.exists():
        return empty_state(today)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        log.warning("notify_state: failed to parse %s, resetting", path)
        return empty_state(today)
    if not isinstance(raw, dict) or raw.get("date") != today:
        return empty_state(today)
    # Backfill any missing keys to keep callers simple
    base = empty_state(today)
    base.update({k: v for k, v in raw.items() if k in base})
    return base


def save_notify_state(state: dict[str, Any]) -> bool:
    """Atomically write state to disk. Returns True on success."""
    path = _state_path()
    if path is None:
        return False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2),
                        encoding="utf-8")
        os.replace(tmp, path)
        return True
    except Exception:
        log.exception("notify_state: failed to write %s", path)
        return False


def mark_morning_sent(state: dict[str, Any], readiness: dict[str, Any]) -> None:
    """Update state after a morning notification was sent.

    ``readiness`` is the dict returned by R health_insight_readiness().
    """
    state["morning_sent"] = True
    state["morning_kvalitet"] = readiness.get("kvalitet")
    state["morning_components"] = dict(readiness.get("components_present") or {})
    state["morning_status"] = readiness.get("status")
    score = readiness.get("score")
    state["morning_score"] = score if score is not None else None


def mark_day_summary_sent(state: dict[str, Any]) -> None:
    """Mark today's end-of-day summary as posted."""
    state["day_summary_sent"] = True


_PENDING_STATE_FILENAME = ".pending_state.json"


def _pending_state_path() -> Path | None:
    data_dir = get_settings().traning_data
    if not data_dir:
        return None
    return Path(data_dir) / _PENDING_STATE_FILENAME


def empty_pending_state() -> dict[str, Any]:
    """Return a fresh, empty debounce-pending state dict."""
    return {"pending_files": [], "pending_workouts_count": 0}


def load_pending_state() -> dict[str, Any]:
    """Read the debounce-pending state from disk (survives receiver restarts).

    Returns an empty state if the file is missing or malformed. Never raises.
    """
    path = _pending_state_path()
    if path is None or not path.exists():
        return empty_pending_state()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        log.warning("pending_state: failed to parse %s, resetting", path)
        return empty_pending_state()
    if not isinstance(raw, dict):
        return empty_pending_state()
    base = empty_pending_state()
    base["pending_files"] = [str(f) for f in (raw.get("pending_files") or [])]
    try:
        base["pending_workouts_count"] = int(raw.get("pending_workouts_count") or 0)
    except (TypeError, ValueError):
        base["pending_workouts_count"] = 0
    return base


def save_pending_state(state: dict[str, Any]) -> bool:
    """Atomically write debounce-pending state to disk. Returns True on success."""
    path = _pending_state_path()
    if path is None:
        return False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2),
                        encoding="utf-8")
        os.replace(tmp, path)
        return True
    except Exception:
        log.exception("pending_state: failed to write %s", path)
        return False


def mark_update_sent(state: dict[str, Any], update: dict[str, Any]) -> None:
    """Update state after a follow-up update notification was sent."""
    trigger = update.get("trigger")
    if trigger == "rerender":
        # Re-rendering raises kvalitet and refreshes components
        state["morning_kvalitet"] = update.get("kvalitet")
        state["morning_components"] = dict(update.get("components_present") or {})
        state["morning_status"] = update.get("status")
        score = update.get("score")
        state["morning_score"] = score if score is not None else None
    elif trigger == "tier1":
        m = update.get("tier1_metric")
        if m:
            sent = list(state.get("afternoon_updates_sent") or [])
            if m not in sent:
                sent.append(m)
            state["afternoon_updates_sent"] = sent
