"""Path helpers and config for Health Auto Export data."""

import os
from pathlib import Path

from ..garmin.utils import get_data_dir

DEFAULT_HAE_HOST = "192.168.0.146"
DEFAULT_HAE_PORT = 9000
DEFAULT_TIMEOUT = 10


def hae_host() -> str:
    return os.environ.get("HAE_HOST", DEFAULT_HAE_HOST)


def hae_port() -> int:
    return int(os.environ.get("HAE_PORT", str(DEFAULT_HAE_PORT)))


def health_metrics_dir(data_dir: Path | None = None) -> Path:
    """Return the health_export/metrics/ directory."""
    if data_dir is None:
        data_dir = get_data_dir()
    return data_dir / "kristian" / "health_export" / "metrics"


def health_workouts_dir(data_dir: Path | None = None) -> Path:
    """Return the health_export/workouts/ directory."""
    if data_dir is None:
        data_dir = get_data_dir()
    return data_dir / "kristian" / "health_export" / "workouts"


def health_canonical_dir(data_dir: Path | None = None) -> Path:
    """Return the health_export/canonical/ directory."""
    if data_dir is None:
        data_dir = get_data_dir()
    return data_dir / "kristian" / "health_export" / "canonical"


def health_incoming_dir(data_dir: Path | None = None) -> Path:
    """Return the health_export/incoming/ directory."""
    if data_dir is None:
        data_dir = get_data_dir()
    return data_dir / "kristian" / "health_export" / "incoming"


def health_inbox_dir(data_dir: Path | None = None) -> Path:
    """Return the health_export/inbox/ directory."""
    if data_dir is None:
        data_dir = get_data_dir()
    return data_dir / "kristian" / "health_export" / "inbox"
