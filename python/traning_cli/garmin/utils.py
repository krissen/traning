"""Naming conventions, path helpers, and logging for Garmin fetch."""

import logging
import re
from pathlib import Path

from ..settings import _read_renviron, get_project_root, get_settings

# Re-exported for backwards compatibility — other modules import
# _read_renviron/get_project_root from here rather than traning_cli.settings.
__all__ = [
    "_read_renviron",
    "get_project_root",
    "get_data_dir",
    "gconnect_dir",
    "tcx_dir",
    "token_dir",
    "activity_filename_prefix",
    "prefix_to_symlink_name",
    "extract_activity_id",
    "setup_logging",
]


def get_data_dir() -> Path:
    """Return the TRANING_DATA directory.

    Checks the environment first, then falls back to .Renviron in the
    project root (so the same config works for both R and Python).

    Thin wrapper around Settings.get_data_dir() — see traning_cli.settings.
    """
    return get_settings().get_data_dir()


def gconnect_dir(data_dir: Path) -> Path:
    return data_dir / "kristian" / "filer" / "gconnect"


def tcx_dir(data_dir: Path) -> Path:
    return data_dir / "kristian" / "filer" / "tcx"


def token_dir(data_dir: Path) -> Path:
    return data_dir / ".garmin_tokens"


def activity_filename_prefix(start_time_gmt: str, activity_id: int) -> str:
    """Build the filename prefix: '{ISO8601}_{activityId}'.

    Example: '2023-11-18T19:48:49+00:00_12784482085'
    """
    return f"{start_time_gmt}_{activity_id}"


def prefix_to_symlink_name(prefix: str) -> str:
    """Convert prefix to symlink name used in tcx/.

    '2023-11-18T19:48:49+00:00_12784482085' -> '20231118-194849'
    """
    # Extract the ISO timestamp part (before the underscore + activity ID)
    match = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", prefix)
    if not match:
        raise ValueError(f"Cannot parse timestamp from prefix: {prefix}")
    y, mo, d, h, mi, s = match.groups()
    return f"{y}{mo}{d}-{h}{mi}{s}"


def extract_activity_id(filename: str) -> int | None:
    """Extract activity ID from a gconnect filename.

    '2023-11-18T19:48:49+00:00_12784482085_summary.json' -> 12784482085
    """
    match = re.search(r"_(\d+)_summary\.json$", filename)
    return int(match.group(1)) if match else None


def setup_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
