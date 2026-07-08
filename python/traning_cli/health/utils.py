"""Path helpers and config for Health Auto Export data."""

from pathlib import Path

from ..garmin.utils import get_data_dir
from ..settings import get_settings

DEFAULT_HAE_PORT = 9000
DEFAULT_TIMEOUT = 10


def hae_host() -> str:
    host = get_settings().hae_host
    if not host:
        raise RuntimeError("HAE_HOST is not set. Set it to the HAE TCP server hostname.")
    return host


def hae_port() -> int:
    return get_settings().hae_port


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
