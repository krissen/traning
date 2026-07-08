"""Loader for the shared metric taxonomy (inst/metric_taxonomy.json).

Single source of truth for metric classifications that both the Python
pipeline and the R package need to agree on — currently just
``sum_metrics`` (cumulative-over-a-day metrics, summed rather than
averaged when aggregating). See ``R/health_export.R::.load_metric_taxonomy``
for the R-side loader that reads the same file.

Resolved relative to the repo root (mirrors ``settings.get_project_root()``)
rather than depending on the R package being installed — the Python side
must work standalone (e.g. in the FastAPI receiver on kailash, which does
not install the R package).
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from .settings import get_project_root


def _taxonomy_path() -> Path:
    return get_project_root() / "inst" / "metric_taxonomy.json"


@lru_cache
def load_taxonomy() -> dict:
    """Return the parsed metric_taxonomy.json contents (memoized)."""
    path = _taxonomy_path()
    with open(path, encoding="utf-8") as f:
        return json.load(f)


@lru_cache
def load_sum_metrics() -> frozenset[str]:
    """Return the sum_metrics set (memoized), as a frozenset."""
    return frozenset(load_taxonomy()["sum_metrics"])
