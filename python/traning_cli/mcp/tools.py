"""Vayu MCP tools — curated training analysis functions."""

from typing import Optional

from .r_bridge import r_report, r_plot


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _data_or_plot(
    report_func: str,
    plot_func: str,
    args: dict,
    plot: bool = False,
) -> dict | list:
    """Call a report or plot function depending on the plot flag."""
    if plot:
        return r_plot(plot_func, args)
    return r_report(report_func, args)


def _build_args(
    after: Optional[str] = None,
    before: Optional[str] = None,
    n: Optional[int] = None,
    **extra,
) -> dict:
    """Build an args dict, omitting None values."""
    args = {}
    if after is not None:
        args["from"] = after
    if before is not None:
        args["to"] = before
    if n is not None:
        args["n"] = n
    args.update({k: v for k, v in extra.items() if v is not None})
    return args


# ---------------------------------------------------------------------------
# Health & Readiness
# ---------------------------------------------------------------------------

def get_readiness(
    n: int = 14,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Daily readiness score with component breakdown (HRV, sleep, resting HR, training load).

    Returns a composite score (0-100) fusing Apple Watch health data with
    Garmin training load. Status: Gron (>=70), Gul (40-69), Rod (<40).

    Args:
        n: Number of recent days to show (default 14).
        after: Start date filter (e.g. '2025-01-01', '-2w').
        before: End date filter.
        plot: If True, return a 4-panel readiness dashboard (PNG).
    """
    args = _build_args(after, before, n)
    return _data_or_plot("report_readiness", "fetch.plot.readiness_score", args, plot)


def get_sleep(
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Sleep data from Apple Watch (total hours, deep/REM/core stages).

    Args:
        after: Start date filter.
        before: End date filter.
        plot: If True, return sleep trend chart with stage breakdown (PNG).
    """
    args = _build_args(after, before)
    if plot:
        return r_plot("fetch.plot.sleep", args)
    # For data mode, use readiness report which includes sleep
    args.setdefault("n", 30)
    return r_report("report_readiness", args)


def get_hrv(
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Heart rate variability (HRV) from Apple Watch as Ln(RMSSD).

    Includes 7-day rolling baseline and standard deviation bands.

    Args:
        after: Start date filter.
        before: End date filter.
        plot: If True, return HRV trend chart (PNG).
    """
    args = _build_args(after, before)
    if plot:
        return r_plot("fetch.plot.hrv", args)
    args.setdefault("n", 30)
    return r_report("report_readiness", args)


# ---------------------------------------------------------------------------
# Training Load
# ---------------------------------------------------------------------------

def get_training_load(
    metric: str = "pmc",
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Training load metrics: PMC (fitness/fatigue/form), ACWR, or monotony.

    Args:
        metric: One of 'pmc' (Performance Management Chart with CTL/ATL/TSB),
                'acwr' (Acute:Chronic Workload Ratio), or
                'monotony' (Foster's training monotony and strain).
        n: Number of recent entries to show (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return the corresponding chart (PNG).
    """
    metric = metric.lower()
    report_map = {
        "pmc": ("report_pmc", "fetch.plot.pmc"),
        "acwr": ("report_acwr", "fetch.plot.acwr"),
        "monotony": ("report_monotony", "fetch.plot.monotony"),
    }
    if metric not in report_map:
        return {"type": "error", "message": f"Unknown metric: {metric}. Use pmc, acwr, or monotony."}

    report_func, plot_func = report_map[metric]
    args = _build_args(after, before, n)
    return _data_or_plot(report_func, plot_func, args, plot)


def get_efficiency(
    metric: str = "ef",
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Efficiency trend: EF (Efficiency Factor) or HRE (Heart Rate Efficiency).

    EF = pace:HR ratio. HRE = avgHR x avgPace (beats/km).

    Args:
        metric: 'ef' (Efficiency Factor) or 'hre' (Heart Rate Efficiency).
        n: Number of recent entries to show (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return the corresponding chart (PNG).
    """
    metric = metric.lower()
    report_map = {
        "ef": ("report_ef", "fetch.plot.ef"),
        "hre": ("report_hre", "fetch.plot.hre"),
    }
    if metric not in report_map:
        return {"type": "error", "message": f"Unknown metric: {metric}. Use ef or hre."}

    report_func, plot_func = report_map[metric]
    args = _build_args(after, before, n)
    return _data_or_plot(report_func, plot_func, args, plot)


def get_zones(
    n: int = 12,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """HR zone distribution (Seiler 3-zone model) and Polarization Index.

    Z1 (low, <VT1), Z2 (threshold), Z3 (high, >=VT2).
    PI > 2.0 = polarized training (Treff 2019).

    Args:
        n: Number of recent months to show (default 12).
        after: Start date filter.
        before: End date filter.
        plot: If True, return stacked bar chart of zone distribution (PNG).
    """
    args = _build_args(after, before, n)
    return _data_or_plot("report_hr_zones", "fetch.plot.hr_zones", args, plot)


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

def get_sessions(
    n: int = 20,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """List individual training sessions with distance, pace, HR.

    Args:
        n: Number of recent sessions to show (default 20).
        after: Start date filter.
        before: End date filter.
        plot: If True, return lollipop chart of sessions (PNG).
    """
    args = _build_args(after, before, n)
    return _data_or_plot("report_runs_year_month", "plot_runs_month", args, plot)


def get_monthly_summary(
    n: int = 12,
    after: Optional[str] = None,
    before: Optional[str] = None,
    top: bool = False,
    plot: bool = False,
) -> dict | list:
    """Monthly running summary (distance, pace, sessions).

    Args:
        n: Number of entries to show (default 12).
        after: Start date filter.
        before: End date filter.
        top: If True, show top months by distance instead of current month comparison.
        plot: If True, return bar chart (PNG).
    """
    args = _build_args(after, before, n)
    if top:
        return _data_or_plot("report_monthtop", "plot_monthtop", args, plot)
    return _data_or_plot("report_monthstatus", "plot_monthstatus", args, plot)


def get_yearly_summary(
    n: int = None,
    after: Optional[str] = None,
    before: Optional[str] = None,
    top: bool = False,
    plot: bool = False,
) -> dict | list:
    """Yearly running summary (total distance, sessions, pace).

    Args:
        n: Number of entries to show.
        after: Start date filter.
        before: End date filter.
        top: If True, show full-year totals. If False, year-to-date comparison.
        plot: If True, return bar chart (PNG).
    """
    args = _build_args(after, before, n)
    if top:
        return _data_or_plot("report_yearstop", "plot_yearstop", args, plot)
    return _data_or_plot("report_yearstatus", "plot_yearstatus", args, plot)


# ---------------------------------------------------------------------------
# Trends
# ---------------------------------------------------------------------------

def get_decoupling(
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Aerobic decoupling: pace:HR drift between first and second half of runs.

    <3% well-coupled, 3-5% acceptable, 5-8% moderate drift, >8% significant.

    Args:
        n: Number of recent qualifying runs (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return decoupling trend chart (PNG).
    """
    args = _build_args(after, before, n)
    return _data_or_plot("report_decoupling", "fetch.plot.decoupling", args, plot)


def get_recovery_hr(
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Post-workout recovery heart rate trend.

    Lower recovery HR indicates better cardiovascular fitness.

    Args:
        n: Number of recent sessions (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return recovery HR trend chart (PNG).
    """
    args = _build_args(after, before, n)
    return _data_or_plot("report_recovery_hr", "fetch.plot.recovery_hr", args, plot)


def get_resting_hr(
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """Resting heart rate trend from Apple Watch.

    Args:
        after: Start date filter.
        before: End date filter.
        plot: If True, return resting HR trend chart (PNG).
    """
    args = _build_args(after, before)
    if plot:
        return r_plot("fetch.plot.resting_hr", args)
    args.setdefault("n", 30)
    return r_report("report_readiness", args)


def get_vo2max(
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> dict | list:
    """VO2max estimate trend from Apple Watch.

    Args:
        after: Start date filter.
        before: End date filter.
        plot: If True, return VO2max trend chart (PNG).
    """
    args = _build_args(after, before)
    if plot:
        return r_plot("fetch.plot.vo2max", args)
    args.setdefault("n", 30)
    return r_report("report_readiness", args)


def compare_periods(
    period_a_from: str,
    period_a_to: str,
    period_b_from: str,
    period_b_to: str,
) -> dict:
    """Compare two date ranges side by side (distance, pace, sessions).

    Args:
        period_a_from: Start of first period (e.g. '2025-01-01').
        period_a_to: End of first period.
        period_b_from: Start of second period.
        period_b_to: End of second period.
    """
    a = r_report("report_datesum", {"from": period_a_from, "to": period_a_to})
    b = r_report("report_datesum", {"from": period_b_from, "to": period_b_to})

    return {
        "schema_version": "1.0",
        "summary": {
            "status": "ok",
            "period_a": f"{period_a_from} to {period_a_to}",
            "period_b": f"{period_b_from} to {period_b_to}",
        },
        "details": {
            "period_a": a.get("details", []),
            "period_b": b.get("details", []),
        },
        "_meta": a.get("_meta", {}),
    }


# ---------------------------------------------------------------------------
# Reference
# ---------------------------------------------------------------------------

_METRIC_DEFINITIONS = {
    "readiness": {
        "name": "Readiness Score",
        "description": "Daily composite score (0-100) fusing HRV, sleep, resting HR, and training load.",
        "components": "HRV 35%, Sleep 30%, Resting HR 20%, Training load 15%",
        "thresholds": {"green": ">=70", "yellow": "40-69", "red": "<40"},
        "references": ["Seshadri 2019", "Plews 2013", "Buchheit 2014"],
    },
    "pmc": {
        "name": "Performance Management Chart",
        "description": "CTL (fitness, 42-day EWMA of TRIMP), ATL (fatigue, 7-day EWMA), TSB = CTL - ATL (form).",
        "thresholds": {"fresh": "TSB > 0", "optimal": "TSB 5-15", "overreaching": "TSB < -20"},
        "references": ["Banister 1991", "Murray 2017"],
    },
    "acwr": {
        "name": "Acute:Chronic Workload Ratio",
        "description": "7-day load / 28-day load. Sweet spot 0.8-1.3.",
        "thresholds": {"underloading": "<0.8", "sweet_spot": "0.8-1.3", "danger": ">1.5"},
        "references": ["Hulin 2016", "Gabbett 2016"],
    },
    "ef": {
        "name": "Efficiency Factor",
        "description": "Normalized pace / normalized HR. Higher = more efficient.",
        "interpretation": "Upward trend indicates improving aerobic fitness.",
        "references": ["Friel 2009"],
    },
    "hre": {
        "name": "Heart Rate Efficiency",
        "description": "avgHR x avgPace = beats/km. Lower is more efficient.",
        "thresholds": {"well_fitted": "<700", "fitted": "700-750", "poorly_fitted": ">800"},
        "references": ["Votyakov 2025"],
    },
    "decoupling": {
        "name": "Aerobic Decoupling",
        "description": "Pace:HR efficiency drift between first and second half of a run.",
        "thresholds": {"well_coupled": "<3%", "acceptable": "3-5%", "moderate_drift": "5-8%", "significant": ">8%"},
        "references": ["Friel 2009"],
    },
    "monotony": {
        "name": "Training Monotony",
        "description": "7-day mean daily load / SD. High monotony (>2.0) increases illness/injury risk.",
        "thresholds": {"low": "<1.5", "moderate": "1.5-2.0", "high": ">2.0"},
        "references": ["Foster 1998"],
    },
    "zones": {
        "name": "HR Zone Distribution (Seiler 3-zone)",
        "description": "Z1 (<VT1, low), Z2 (VT1-VT2, threshold), Z3 (>=VT2, high). Target ~80% Z1.",
        "polarization_index": "PI = log10((Z1/Z2) x Z3 x 100). PI > 2.0 = polarized.",
        "references": ["Seiler 2006", "Treff 2019"],
    },
    "trimp": {
        "name": "Training Impulse (TRIMP)",
        "description": "Session load = duration x delta-HR x weighting. Banister bTRIMP formula.",
        "references": ["Banister 1991", "Morton 1990"],
    },
}


def explain_metric(metric_name: str) -> dict:
    """Explain a training metric: definition, formula, thresholds, and references.

    Args:
        metric_name: Metric to explain. One of: readiness, pmc, acwr, ef, hre,
                     decoupling, monotony, zones, trimp.
    """
    key = metric_name.lower().strip()
    if key not in _METRIC_DEFINITIONS:
        available = ", ".join(sorted(_METRIC_DEFINITIONS.keys()))
        return {
            "schema_version": "1.0",
            "summary": {"status": "error", "message": f"Unknown metric: {key}. Available: {available}"},
            "details": [],
            "_meta": {},
        }

    defn = _METRIC_DEFINITIONS[key]
    return {
        "schema_version": "1.0",
        "summary": {"status": "ok", "metric": key},
        "details": defn,
        "_meta": {},
    }


# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

def resource_metrics() -> str:
    """List of available training metrics with descriptions."""
    lines = []
    for key, defn in _METRIC_DEFINITIONS.items():
        lines.append(f"## {defn['name']} ({key})\n{defn['description']}\n")
    return "\n".join(lines)


def resource_thresholds() -> str:
    """Reference thresholds for all training metrics."""
    lines = []
    for key, defn in _METRIC_DEFINITIONS.items():
        if "thresholds" in defn:
            lines.append(f"## {defn['name']}")
            for level, value in defn["thresholds"].items():
                lines.append(f"  {level}: {value}")
            lines.append("")
    return "\n".join(lines)
