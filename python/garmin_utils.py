"""Naming conventions, path helpers, and logging for Garmin fetch."""

import logging
import os
import re
from pathlib import Path


def get_data_dir() -> Path:
    """Return the TRANING_DATA directory, or raise if unset."""
    raw = os.environ.get("TRANING_DATA")
    if not raw:
        raise EnvironmentError(
            "TRANING_DATA is not set. "
            "Export it or add it to .Renviron / your shell profile."
        )
    p = Path(raw)
    if not p.is_dir():
        raise FileNotFoundError(f"TRANING_DATA directory not found: {p}")
    return p


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
