"""Save incoming HAE health data to the metrics directory."""

import json
import logging
import subprocess
from pathlib import Path

from ..health.utils import health_metrics_dir
from ..garmin.utils import get_data_dir

log = logging.getLogger(__name__)


def save_health_push(payload: dict, data_dir: Path | None = None) -> int:
    """Save HAE JSON payload to metrics/ directory.

    Follows the same file format as health/tcp.py — one file per metric,
    named {metric}_{first_date}_{last_date}.json.

    Returns the number of metric files written.
    """
    if data_dir is None:
        data_dir = get_data_dir()

    metrics_dir = health_metrics_dir(data_dir)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    # Extract metrics from HAE payload
    data = payload.get("data", {})
    metrics = data.get("metrics", [])

    if not metrics:
        return 0

    n_written = 0
    for m in metrics:
        name = m.get("name")
        samples = m.get("data", [])
        if not name or not samples:
            continue

        dates = [s["date"][:10] for s in samples if "date" in s]
        if not dates:
            continue

        first, last = min(dates), max(dates)
        units = m.get("units", "")

        output = {
            "data": {
                "metrics": [{
                    "name": name,
                    "units": units,
                    "data": samples,
                }]
            }
        }

        filename = f"{name}_{first}_{last}.json"
        filepath = metrics_dir / filename
        with open(filepath, "w") as f:
            json.dump(output, f, ensure_ascii=False)

        log.info("  %s: %d samples", filename, len(samples))
        n_written += 1

    return n_written


def commit_health_data(data_dir: Path | None = None, n_metrics: int = 0) -> bool:
    """Git add + commit new health metric files.

    Returns True if commit succeeded.
    """
    if data_dir is None:
        data_dir = get_data_dir()

    try:
        subprocess.run(
            ["git", "add", "kristian/health_export/metrics/"],
            cwd=data_dir, check=True, capture_output=True,
        )
        # Check if there's anything staged
        result = subprocess.run(
            ["git", "diff", "--cached", "--quiet"],
            cwd=data_dir, capture_output=True,
        )
        if result.returncode == 0:
            log.info("No new health data to commit")
            return False

        subprocess.run(
            ["git", "commit", "-m",
             f"(health) Receive {n_metrics} metric updates via API"],
            cwd=data_dir, check=True, capture_output=True,
        )
        log.info("Committed %d health metric files", n_metrics)
        return True
    except subprocess.CalledProcessError as e:
        log.warning("Git commit failed: %s", e.stderr.decode().strip())
        return False
