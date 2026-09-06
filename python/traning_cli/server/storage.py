"""Save incoming HAE health data with content-level deduplication.

Incoming pushes are canonicalized into per-metric-per-day files under
canonical/{metric}/{YYYY-MM-DD}.json.  All known samples for a given
(metric, date) are merged and deduplicated on the full sample content,
with multiplicity preserved (see ``_merge_samples``).
"""

import json
import logging
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

from ..garmin.utils import get_data_dir
from ..git_utils import git_commit_paths
from ..health.utils import (
    health_canonical_dir,
    health_metrics_dir,
    health_workouts_dir,
)
from ..metric_taxonomy import load_sum_metrics

log = logging.getLogger(__name__)


# Metrics whose intra-day samples sum to a meaningful daily total
# (steps walked, calories burned, distance covered, etc.). Reading
# these out of 1100+ raw samples per day is wasteful when callers only
# want the day's total; canonical files for these metrics carry a
# `daily_total` field so the R reader can take a fast path.
#
# Single source of truth shared with the R side
# (R/health_export.R::.sum_metrics) is inst/metric_taxonomy.json.
_SUM_METRICS = load_sum_metrics()


def _daily_total(samples: list[dict]) -> float | None:
    """Sum the `qty` values across samples. None if no numeric qty seen."""
    total = 0.0
    found = False
    for s in samples:
        qty = s.get("qty")
        if isinstance(qty, (int, float)):
            total += qty
            found = True
    return total if found else None


# --- Canonical deduplication ------------------------------------------------

def _sample_key(sample: dict) -> str:
    """Return a dedup key for a legacy (sleep_analysis) HAE sample.

    Sleep segments are keyed on (full_timestamp, stage_value, source).
    A night is a chain of non-overlapping segments, so a timestamp plus
    a stage identifies one of them; the remaining fields (durations HAE
    recomputes between exports) would only make identical segments look
    distinct.  Canonical metrics use ``_canonical_sample_key`` instead —
    they can and do carry several samples for the same second.
    """
    ts = sample.get("date", sample.get("startDate", ""))
    src = sample.get("source", "")
    stage = sample.get("value", "")  # sleep stage name, empty for others
    return f"{ts}|{stage}|{src}"


def _canonical_sample_key(sample: dict) -> str:
    """Return a dedup key for a single canonical HAE sample.

    The key is the whole sample, canonicalized: every field, keys sorted
    so that HAE's varying key order cannot make one sample look like two.

    Keying on (timestamp, source) alone — what this did until 2026-09-06
    — silently dropped samples that share a second.  DrinkControl writes
    one dietary_energy sample per drink and stamps a whole logging
    session with the same second: three drinks logged at 23:50:53
    collapsed to one, taking two thirds of the evening's alcohol with
    them.  Any per-event metric can do this; the timestamp is when the
    export ran, not when the event happened.

    Two genuinely identical samples in one push (the same beer logged
    twice in the same second, seen 2026-08-28) are indistinguishable by
    content, so multiplicity rather than the key carries them; see
    ``_merge_samples``.
    """
    return json.dumps(sample, sort_keys=True, ensure_ascii=False, default=str)


def _merge_samples(existing: list[dict],
                   incoming: list[dict]) -> tuple[list[dict], int]:
    """Merge incoming samples into existing ones, preserving multiplicity.

    Deduplication is by *count* per content key, not by presence: a key
    seen twice in one push yields two samples, while pushing that same
    payload again adds nothing.  Idempotence therefore survives without
    forcing identical-but-distinct samples to collapse into one.

    Counts never shrink.  A push covering a window is not authoritative
    about what it omits, and canonical files are append-only for the
    same reason: a short push must not delete a longer one's history.

    Returns (merged, n_added).
    """
    existing_counts = Counter(_canonical_sample_key(s) for s in existing)
    merged = list(existing)
    seen: Counter[str] = Counter()
    n_added = 0
    for s in incoming:
        key = _canonical_sample_key(s)
        seen[key] += 1
        if seen[key] > existing_counts[key]:
            merged.append(s)
            n_added += 1
    return merged, n_added


def canonicalize_metric(
    metric_name: str,
    units: str,
    samples: list[dict],
    data_dir: Path,
) -> list[Path]:
    """Merge incoming samples into per-day canonical files.

    Returns list of canonical file paths that were created or updated.
    """
    canonical_dir = health_canonical_dir(data_dir) / metric_name
    canonical_dir.mkdir(parents=True, exist_ok=True)

    # Group incoming samples by date
    by_date: dict[str, list[dict]] = defaultdict(list)
    for s in samples:
        date_str = s.get("date", s.get("startDate", ""))[:10]
        if date_str:
            by_date[date_str].append(s)

    changed: list[Path] = []
    for date_str, new_samples in by_date.items():
        canonical_path = canonical_dir / f"{date_str}.json"

        # Load existing canonical samples
        existing_samples: list[dict] = []
        if canonical_path.exists():
            with open(canonical_path) as f:
                doc = json.load(f)
            existing_samples = doc.get("samples", [])

        merged, n_added = _merge_samples(existing_samples, new_samples)

        if n_added == 0 and existing_samples:
            continue  # no change

        doc = {
            "metric": metric_name,
            "date": date_str,
            "units": units,
            "samples": merged,
        }
        if metric_name in _SUM_METRICS:
            total = _daily_total(merged)
            if total is not None:
                doc["daily_total"] = total
        with open(canonical_path, "w") as f:
            json.dump(doc, f, ensure_ascii=False)

        changed.append(canonical_path)

    return changed


# --- Legacy metric merge (sleep_analysis) -----------------------------------

def _parse_legacy_filename(path: Path, metric_name: str) -> tuple[str, str] | None:
    """Extract (first, last) date from a legacy metric filename.

    Filenames look like ``{metric}_{first}_{last}.json``. Returns None if
    the name does not match (e.g., a TCP-backfill file with a suffix).
    """
    stem = path.stem
    prefix = f"{metric_name}_"
    if not stem.startswith(prefix):
        return None
    rest = stem[len(prefix):]
    parts = rest.rsplit("_", 1)
    if len(parts) != 2:
        return None
    first, last = parts[0], parts[1]
    if len(first) != 10 or len(last) != 10:
        return None
    return first, last


def _save_legacy_metric(
    metric_name: str,
    units: str,
    samples: list[dict],
    metrics_dir: Path,
) -> list[Path]:
    """Merge incoming samples for a legacy metric (e.g., sleep_analysis).

    HAE pushes vary in window size and date range. To prevent shrinking
    pushes from overwriting larger prior files (which corrupted today's
    sleep data), this:

    1. Computes the new push's date range.
    2. Reads samples from any existing legacy files whose filename-encoded
       range overlaps the new push range.
    3. Dedupes existing + new samples via ``_sample_key``.
    4. Writes the merged set to a single file named after the merged range.
    5. Removes the now-superseded overlapping files.

    Non-overlapping files are left untouched.
    """
    dates = [s.get("date", s.get("startDate", ""))[:10]
             for s in samples if s.get("date") or s.get("startDate")]
    if not dates:
        return []
    push_first, push_last = min(dates), max(dates)

    overlapping: list[tuple[Path, str, str]] = []
    for f in metrics_dir.glob(f"{metric_name}_*.json"):
        rng = _parse_legacy_filename(f, metric_name)
        if rng is None:
            continue  # skip files like sleep_analysis_tcp_*.json
        f_first, f_last = rng
        if f_first <= push_last and f_last >= push_first:
            overlapping.append((f, f_first, f_last))

    existing_samples: list[dict] = []
    for f, _, _ in overlapping:
        try:
            with open(f) as fp:
                doc = json.load(fp)
            for m in doc.get("data", {}).get("metrics", []):
                if m.get("name") == metric_name:
                    existing_samples.extend(m.get("data", []))
                    break
        except (json.JSONDecodeError, OSError) as e:
            log.warning("Kunde inte läsa befintlig %s: %s", f, e)

    seen = {_sample_key(s) for s in existing_samples}
    merged = list(existing_samples)
    n_added = 0
    for s in samples:
        key = _sample_key(s)
        if key not in seen:
            seen.add(key)
            merged.append(s)
            n_added += 1

    if not merged:
        return []

    merged_dates = [s.get("date", s.get("startDate", ""))[:10] for s in merged
                    if s.get("date") or s.get("startDate")]
    new_first, new_last = min(merged_dates), max(merged_dates)
    new_path = metrics_dir / f"{metric_name}_{new_first}_{new_last}.json"

    output = {"data": {"metrics": [
        {"name": metric_name, "units": units, "data": merged}
    ]}}
    tmp_path = new_path.with_suffix(".json.tmp")
    with open(tmp_path, "w") as fp:
        json.dump(output, fp, ensure_ascii=False)
    tmp_path.replace(new_path)

    # Remove superseded overlapping files (skip the one we just wrote)
    for f, _, _ in overlapping:
        if f.resolve() != new_path.resolve() and f.exists():
            f.unlink()

    log.info("  %s: %d new + %d existing → %d total (legacy, range %s..%s, "
             "consolidated %d file(s))",
             metric_name, n_added, len(existing_samples), len(merged),
             new_first, new_last, len(overlapping))
    return [new_path]


# --- Public API -------------------------------------------------------------

def save_health_push(payload: dict, data_dir: Path | None = None) -> tuple[int, list[Path]]:
    """Save HAE JSON payload via canonical deduplication.

    1. Canonicalize each metric into per-day files under canonical/.
    2. Track changed files for downstream import.

    Returns (n_metrics, changed_files).
    """
    if data_dir is None:
        data_dir = get_data_dir()

    data = payload.get("data", {})
    metrics = data.get("metrics", [])

    if not metrics:
        return 0, []

    n_written = 0
    all_changed: list[Path] = []

    # Sleep segments span midnight — per-day canonical files would break
    # the R sleep parser which needs to see whole nights together.
    _LEGACY_METRICS = {"sleep_analysis"}

    metrics_dir = health_metrics_dir(data_dir)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    for m in metrics:
        name = m.get("name")
        samples = m.get("data", [])
        if not name or not samples:
            continue

        units = m.get("units", "")

        if name in _LEGACY_METRICS:
            changed = _save_legacy_metric(name, units, samples, metrics_dir)
            all_changed.extend(changed)
        else:
            changed = canonicalize_metric(name, units, samples, data_dir)
            all_changed.extend(changed)
            log.info("  %s: %d samples, %d canonical files updated",
                     name, len(samples), len(changed))

        n_written += 1

    return n_written, all_changed


def save_workout_push(payload: dict, data_dir: Path | None = None) -> int:
    """Save HAE workout JSON payload to workouts/ directory.

    Each workout is saved as a separate JSON file named
    {workout_name}_{start_timestamp}.json.

    Returns the number of workout files written.
    """
    if data_dir is None:
        data_dir = get_data_dir()

    workouts_dir = health_workouts_dir(data_dir)
    workouts_dir.mkdir(parents=True, exist_ok=True)

    data = payload.get("data", {})
    workouts = data.get("workouts", [])

    if not workouts:
        return 0

    n_written = 0
    for w in workouts:
        name = w.get("name", "workout")
        start = w.get("start", "")

        # Build filename from name + start timestamp
        # "2026-04-06 07:00:35 +0200" → "20260406_070035"
        ts = start[:19].replace("-", "").replace(":", "").replace(" ", "_")
        # Normalize: å→a, ö→o, ä→a, strip remaining non-ASCII
        safe_name = unicodedata.normalize("NFKD", name)
        safe_name = safe_name.encode("ascii", "ignore").decode("ascii")
        safe_name = safe_name.replace(" ", "_").replace("/", "_")
        filename = f"{safe_name}-{ts}.json"

        filepath = workouts_dir / filename
        with open(filepath, "w") as f:
            json.dump({"data": {"workouts": [w]}}, f, ensure_ascii=False)

        log.info("  %s", filename)
        n_written += 1

    return n_written


def commit_health_data(data_dir: Path | None = None, n_metrics: int = 0,
                       n_workouts: int = 0) -> bool:
    """Git add + commit new health metric files.

    Returns True if commit succeeded.
    """
    if data_dir is None:
        data_dir = get_data_dir()

    parts = []
    if n_metrics:
        parts.append(f"{n_metrics} metrics")
    if n_workouts:
        parts.append(f"{n_workouts} workouts")
    desc = " + ".join(parts) or "health data"

    committed = git_commit_paths(
        data_dir,
        [
            "kristian/health_export/canonical/",
            "kristian/health_export/metrics/",
            "kristian/health_export/workouts/",
        ],
        f"(health) Receive {desc} via API",
    )
    if committed:
        log.info("Committed health data: %s", desc)
    else:
        log.info("No new health data to commit")
    return committed
