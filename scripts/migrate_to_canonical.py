#!/usr/bin/env python3
"""Migrate health metric files from metrics/ to canonical/ structure.

Reads all JSON files in health_export/metrics/ (including deleted files
recovered from git history), extracts samples, deduplicates at the
content level, and writes per-metric-per-day canonical files.

Usage:
    python scripts/migrate_to_canonical.py [--data-dir PATH] [--recover-git]
"""

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# Add project root to path for imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from python.traning_cli.server.storage import canonicalize_metric


def read_metric_file(path: str | Path) -> list[tuple[str, str, list[dict]]]:
    """Read a HAE metric JSON file, return [(name, units, samples), ...]."""
    with open(path) as f:
        raw = json.load(f)

    metrics_list = raw.get("data", {}).get("metrics", [])
    if not metrics_list:
        metrics_list = raw.get("metrics", [])

    results = []
    for m in metrics_list:
        name = m.get("name", "")
        units = m.get("units", "")
        samples = m.get("data", [])
        if name and samples:
            results.append((name, units, samples))
    return results


def recover_deleted_files(data_dir: Path, delete_commit: str) -> list[Path]:
    """Recover files deleted in a specific commit from git history.

    Returns list of temporary paths with recovered content.
    """
    # Find which files were deleted in that commit
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=D",
         f"{delete_commit}~1", delete_commit],
        cwd=data_dir, capture_output=True, text=True, check=True,
    )
    deleted_paths = [
        l.strip() for l in result.stdout.splitlines()
        if l.strip().startswith("kristian/health_export/metrics/")
        and l.strip().endswith(".json")
    ]

    recovered = []
    tmp_dir = data_dir / "kristian" / "health_export" / "_recovered"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    for rel_path in deleted_paths:
        filename = Path(rel_path).name
        try:
            content = subprocess.run(
                ["git", "show", f"{delete_commit}~1:{rel_path}"],
                cwd=data_dir, capture_output=True, text=True, check=True,
            ).stdout
            tmp_file = tmp_dir / filename
            tmp_file.write_text(content)
            recovered.append(tmp_file)
        except subprocess.CalledProcessError:
            print(f"  WARN: Could not recover {rel_path}")

    return recovered


def main():
    parser = argparse.ArgumentParser(description="Migrate to canonical storage")
    parser.add_argument("--data-dir", type=Path, default=None,
                        help="Path to traning-data directory")
    parser.add_argument("--recover-git", action="store_true",
                        help="Also recover deleted files from git history")
    parser.add_argument("--delete-commit", default="1d679e7c",
                        help="Commit that deleted files (default: 1d679e7c)")
    args = parser.parse_args()

    import os
    data_dir = args.data_dir or Path(os.environ.get(
        "TRANING_DATA", Path.home() / "Documents" / "traning-data"))

    metrics_dir = data_dir / "kristian" / "health_export" / "metrics"
    if not metrics_dir.exists():
        print(f"ERROR: {metrics_dir} does not exist")
        sys.exit(1)

    # Gather all source files
    source_files = sorted(metrics_dir.glob("*.json"))
    print(f"Found {len(source_files)} files in metrics/")

    recovered_files = []
    if args.recover_git:
        print(f"Recovering deleted files from commit {args.delete_commit}...")
        recovered_files = recover_deleted_files(data_dir, args.delete_commit)
        print(f"  Recovered {len(recovered_files)} files")

    all_files = source_files + recovered_files

    # Process all files → canonical
    total_samples = 0
    total_canonical = 0
    metrics_seen = set()

    for f in all_files:
        try:
            entries = read_metric_file(f)
        except (json.JSONDecodeError, KeyError) as e:
            print(f"  WARN: Could not parse {f.name}: {e}")
            continue

        for name, units, samples in entries:
            metrics_seen.add(name)
            total_samples += len(samples)
            changed = canonicalize_metric(name, units, samples, data_dir)
            total_canonical += len(changed)

    # Clean up recovered files
    if recovered_files:
        recovered_dir = data_dir / "kristian" / "health_export" / "_recovered"
        for f in recovered_files:
            f.unlink()
        recovered_dir.rmdir()

    print(f"\nMigration complete:")
    print(f"  Source files:    {len(all_files)}")
    print(f"  Metrics:         {len(metrics_seen)}")
    print(f"  Total samples:   {total_samples:,}")
    print(f"  Canonical files: {total_canonical}")

    # Count canonical files
    canonical_dir = data_dir / "kristian" / "health_export" / "canonical"
    n_canonical = sum(1 for _ in canonical_dir.rglob("*.json"))
    print(f"  Files on disk:   {n_canonical}")


if __name__ == "__main__":
    main()
