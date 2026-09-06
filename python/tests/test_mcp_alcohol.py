"""Tests for the alcohol MCP tool and its metric metadata.

The R bridge is mocked throughout: these tests cover the Python layer's
contract with it (which function is called, with which arguments), not
the numbers R produces. The one exception is the registration guard at
the bottom, which reads inst/mcp_bridge_shared.R as text — a function
has to be listed in three places to be callable, and two of them are on
opposite sides of the process boundary.
"""

import re
from pathlib import Path

import pytest
from traning_cli.mcp import tools
from traning_cli.mcp.r_bridge import _KNOWN_FUNCTIONS

REPO_ROOT = Path(__file__).resolve().parents[2]

ENVELOPE = {
    "schema_version": "1.0",
    "summary": {"status": "ok", "record_count": 0},
    "details": [],
}


@pytest.fixture
def calls(monkeypatch):
    """Record every r_report call get_alcohol makes."""
    recorded: list[tuple[str, dict]] = []

    def fake_r_report(func, args=None, **kwargs):
        recorded.append((func, args))
        return ENVELOPE

    monkeypatch.setattr(tools, "r_report", fake_r_report)
    return recorded


# --- Dispatch -------------------------------------------------------------

def test_daily_view_calls_report_alcohol(calls):
    tools.get_alcohol()
    assert calls == [("report_alcohol", {})]


def test_weekly_view_calls_report_alcohol_weekly(calls):
    tools.get_alcohol(weekly=True)
    assert calls == [("report_alcohol_weekly", {})]


def test_returns_the_bridge_envelope_unchanged(calls):
    assert tools.get_alcohol() is ENVELOPE


# --- Date handling --------------------------------------------------------

def test_dates_are_passed_as_from_and_to(calls):
    tools.get_alcohol(after="2026-01-01", before="2026-01-31")
    assert calls[0][1] == {"from": "2026-01-01", "to": "2026-01-31"}


def test_absolute_before_is_not_shifted_forward(calls):
    """Regression guard for the inclusive upper bound.

    _build_args() adds a day to `before` because most R report functions
    use an exclusive upper bound. report_alcohol closes it instead
    (filter_by_daterange(..., closed_upper = TRUE)), so a shift here
    would silently pull in the following night.
    """
    tools.get_alcohol(before="2026-01-31")
    assert calls[0][1]["to"] == "2026-01-31"


def test_relative_dates_pass_through_verbatim(calls):
    tools.get_alcohol(after="-6m", before="-1w")
    assert calls[0][1] == {"from": "-6m", "to": "-1w"}


def test_unset_filters_are_omitted_entirely(calls):
    tools.get_alcohol(after="2026-01-01")
    assert calls[0][1] == {"from": "2026-01-01"}


# --- Metric metadata ------------------------------------------------------

@pytest.mark.parametrize(
    "alias", ["alcohol", "alkohol", "drinks", "drinkar", "glas"]
)
def test_aliases_resolve_to_the_canonical_metric(alias, traning_data_dir):
    assert tools._resolve_metric(alias) == "alcohol_consumption"


def test_canonical_name_resolves_to_itself(traning_data_dir):
    assert tools._resolve_metric("alcohol_consumption") == "alcohol_consumption"


def test_alcohol_and_basal_energy_are_described(traning_data_dir):
    for metric in ("alcohol_consumption", "basal_energy_burned"):
        assert metric in tools._HEALTH_METRIC_INFO


def test_metric_resource_lists_alcohol_under_its_category(traning_data_dir):
    """The category order in resource_metrics() is a fixed list.

    A category that is not named there is dropped without warning, so
    the metric is only actually visible if both halves are in place.
    """
    text = tools.resource_metrics()
    assert "## Lifestyle" in text
    lifestyle = text.split("## Lifestyle", 1)[1]
    assert "alcohol_consumption" in lifestyle.split("\n##", 1)[0]


# --- Registration across the bridge ---------------------------------------

@pytest.mark.parametrize(
    "func", ["report_alcohol", "report_alcohol_weekly"]
)
def test_bridge_accepts_the_alcohol_functions(func):
    assert func in _KNOWN_FUNCTIONS


@pytest.mark.parametrize(
    "func", ["report_alcohol", "report_alcohol_weekly"]
)
def test_r_registry_lists_the_alcohol_functions(func):
    source = (REPO_ROOT / "inst" / "mcp_bridge_shared.R").read_text(
        encoding="utf-8"
    )
    registry = source.split("func_registry <- list(", 1)[1].split("\n)", 1)[0]
    assert re.search(rf"^\s*{re.escape(func)}\s*=", registry, re.MULTILINE)


def test_r_bridge_binds_after_and_before_for_the_alcohol_functions():
    """The generic handler binds from/to, which these functions lack.

    Without the by-name rebinding in build_call_args, every dated call
    would fail in R with an unused-argument error.
    """
    source = (REPO_ROOT / "inst" / "mcp_bridge_shared.R").read_text(
        encoding="utf-8"
    )
    assert 'c("report_alcohol", "report_alcohol_weekly")' in source
    assert "a$after" in source
    assert "a$before" in source
