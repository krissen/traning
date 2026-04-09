"""Backfill canonical health metrics from external data exports.

Accepts a zip archive, auto-detects the export type, and writes
canonical per-day JSON files for dates not already present.
"""

import csv
import io
import json
import logging
import zipfile
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from .utils import health_canonical_dir

log = logging.getLogger(__name__)

SOURCE = "Withings"


# -- Archive identification ---------------------------------------------------

def identify_archive(zip_path: str | Path) -> str | None:
    """Detect export type from zip contents.

    Returns a string identifier ("withings", ...) or None if unknown.
    """
    with zipfile.ZipFile(zip_path, "r") as zf:
        names = {n.split("/")[0] if "/" in n else n for n in zf.namelist()}
        # Withings: contains weight.csv, user.csv, README.txt at top level
        if {"weight.csv", "user.csv", "README.txt"} <= names:
            return "withings"
    return None


# -- Canonical helpers --------------------------------------------------------

def _existing_dates(canonical_base: Path, metric: str) -> set[str]:
    """Return set of YYYY-MM-DD dates that already have canonical files."""
    metric_dir = canonical_base / metric
    if not metric_dir.is_dir():
        return set()
    return {f.stem for f in metric_dir.glob("*.json")}


def _write_canonical(canonical_base: Path, metric: str, date: str,
                     units: str, samples: list[dict]) -> None:
    """Write a single canonical JSON file."""
    metric_dir = canonical_base / metric
    metric_dir.mkdir(parents=True, exist_ok=True)
    path = metric_dir / f"{date}.json"
    doc = {
        "metric": metric,
        "date": date,
        "units": units,
        "samples": samples,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)


# -- Withings -----------------------------------------------------------------

def _parse_withings_weight(csv_text: str) -> dict[str, list[dict]]:
    """Parse Withings weight.csv text, grouping samples by date."""
    by_date: dict[str, list[dict]] = defaultdict(list)
    reader = csv.DictReader(io.StringIO(csv_text))
    for row in reader:
        ts_str = row["Date"].strip().strip('"')
        try:
            ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue

        weight = row.get("Weight (kg)", "").strip()
        fat = row.get("Fat mass (kg)", "").strip()
        if not weight:
            continue

        sample = {
            "timestamp": ts_str,
            "date": ts.strftime("%Y-%m-%d"),
            "weight_kg": float(weight),
            "fat_mass_kg": float(fat) if fat else None,
        }
        by_date[sample["date"]].append(sample)

    return dict(by_date)


def backfill_withings(zip_path: str | Path, data_dir: Path | None = None,
                      dry_run: bool = False) -> dict[str, int]:
    """Backfill weight/fat metrics from a Withings export zip.

    Returns dict of {metric_name: n_new_files_written}.
    """
    canonical_base = health_canonical_dir(data_dir)

    with zipfile.ZipFile(zip_path, "r") as zf:
        csv_text = zf.read("weight.csv").decode("utf-8")

    data = _parse_withings_weight(csv_text)
    n_dates = len(data)
    n_samples = sum(len(v) for v in data.values())
    log.info("Withings weight.csv: %d dates, %d samples", n_dates, n_samples)

    existing_weight = _existing_dates(canonical_base, "weight_body_mass")
    existing_fat = _existing_dates(canonical_base, "body_fat_percentage")
    existing_lean = _existing_dates(canonical_base, "lean_body_mass")

    counts = {"weight_body_mass": 0, "body_fat_percentage": 0, "lean_body_mass": 0}

    for date in sorted(data.keys()):
        samples = data[date]

        # --- weight_body_mass ---
        if date not in existing_weight:
            seen_ts: set[str] = set()
            weight_samples = []
            for s in samples:
                if s["timestamp"] not in seen_ts:
                    seen_ts.add(s["timestamp"])
                    weight_samples.append({
                        "date": f"{s['timestamp']} +0100",
                        "qty": s["weight_kg"],
                        "source": SOURCE,
                    })
            if weight_samples:
                if not dry_run:
                    _write_canonical(canonical_base, "weight_body_mass",
                                     date, "kg", weight_samples)
                counts["weight_body_mass"] += 1

        # --- body_fat_percentage + lean_body_mass ---
        fat_samples = [s for s in samples if s["fat_mass_kg"] is not None]
        if fat_samples:
            if date not in existing_fat:
                seen_ts = set()
                bf_samples = []
                for s in fat_samples:
                    if s["timestamp"] not in seen_ts:
                        seen_ts.add(s["timestamp"])
                        pct = (s["fat_mass_kg"] / s["weight_kg"]) * 100
                        bf_samples.append({
                            "date": f"{s['timestamp']} +0100",
                            "qty": round(pct, 6),
                            "source": SOURCE,
                        })
                if bf_samples:
                    if not dry_run:
                        _write_canonical(canonical_base, "body_fat_percentage",
                                         date, "%", bf_samples)
                    counts["body_fat_percentage"] += 1

            if date not in existing_lean:
                seen_ts = set()
                lean_samples = []
                for s in fat_samples:
                    if s["timestamp"] not in seen_ts:
                        seen_ts.add(s["timestamp"])
                        lean = s["weight_kg"] - s["fat_mass_kg"]
                        lean_samples.append({
                            "date": f"{s['timestamp']} +0100",
                            "qty": round(lean, 6),
                            "source": SOURCE,
                        })
                if lean_samples:
                    if not dry_run:
                        _write_canonical(canonical_base, "lean_body_mass",
                                         date, "kg", lean_samples)
                    counts["lean_body_mass"] += 1

    return counts


# -- Dispatcher ---------------------------------------------------------------

HANDLERS = {
    "withings": backfill_withings,
}


def backfill_archive(zip_path: str | Path, data_dir: Path | None = None,
                     dry_run: bool = False) -> dict[str, int]:
    """Identify archive type and run the appropriate backfill handler.

    Returns dict of {metric_name: n_new_files}.
    Raises ValueError if archive type is unknown.
    """
    archive_type = identify_archive(zip_path)
    if archive_type is None:
        raise ValueError(f"Unknown archive type: {zip_path}")

    log.info("Identified archive as: %s", archive_type)
    handler = HANDLERS[archive_type]
    return handler(zip_path, data_dir=data_dir, dry_run=dry_run)
