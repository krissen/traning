"""Tests for the shared metric taxonomy loader (inst/metric_taxonomy.json)."""

import json

from traning_cli.metric_taxonomy import (
    _taxonomy_path,
    load_sum_metrics,
    load_taxonomy,
)
from traning_cli.server.storage import _SUM_METRICS

EXPECTED_SUM_METRICS = frozenset({
    "step_count", "active_energy", "basal_energy_burned",
    "flights_climbed", "apple_exercise_time", "apple_stand_time",
    "apple_stand_hour", "walking_running_distance",
    "cycling_distance", "mindful_minutes", "time_in_daylight",
    "alcohol_consumption",
})


def test_sum_metrics_matches_expected():
    assert load_sum_metrics() == EXPECTED_SUM_METRICS


def test_sum_metrics_matches_taxonomy_json():
    """Guard replacing the old "must stay in sync" code comment.

    Both this test and the R-side test-health-export.R (`.sum_metrics
    matches inst/metric_taxonomy.json`) assert against the SAME JSON
    file, so a taxonomy change is reflected in both suites.
    """
    path = _taxonomy_path()
    assert path.is_file()
    with open(path, encoding="utf-8") as f:
        taxonomy = json.load(f)
    assert frozenset(taxonomy["sum_metrics"]) == EXPECTED_SUM_METRICS


def test_storage_sum_metrics_is_frozenset_from_taxonomy():
    assert isinstance(_SUM_METRICS, frozenset)
    assert _SUM_METRICS == EXPECTED_SUM_METRICS
    assert _SUM_METRICS == load_sum_metrics()


def test_load_taxonomy_is_memoized():
    assert load_taxonomy() is load_taxonomy()
    assert load_sum_metrics() is load_sum_metrics()
