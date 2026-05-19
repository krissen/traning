"""Vayu MCP tools — curated training analysis functions."""

import os
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

import requests

from fastmcp.utilities.types import Image

from .r_bridge import _run_r, r_report, r_plot


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _data_or_plot(
    report_func: str,
    plot_func: str,
    args: dict,
    plot: bool = False,
) -> Image | dict | list:
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
        # R functions use exclusive upper bound (< to), so add 1 day
        # to make the user-facing "before" parameter inclusive.
        try:
            d = date.fromisoformat(before)
            args["to"] = (d + timedelta(days=1)).isoformat()
        except ValueError:
            # Relative dates like "-2w" are passed through as-is;
            # the R layer handles them and already adds +1 internally.
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
) -> Image | dict | list:
    """Daily readiness score with component breakdown (HRV, sleep, resting HR, training load, wrist temp).

    Returns a composite score (0-100) fusing Apple Watch health data
    (including sleeping wrist temperature as illness early-warning) with
    Garmin training load. Status: Gron (>=70), Gul (40-69), Rod (<40).

    Args:
        n: Number of recent days to show (default 14).
        after: Start date filter (e.g. '2025-01-01', '-2w').
        before: End date filter.
        plot: If True, return readiness dashboard (PNG).
    """
    args = _build_args(after, before, n)
    return _data_or_plot("report_readiness", "fetch.plot.readiness_score", args, plot)


def get_sleep(
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> Image | dict | list:
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
) -> Image | dict | list:
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
    sport: Optional[str] = None,
) -> Image | dict | list:
    """Training load metrics: PMC (fitness/fatigue/form), ACWR, or monotony.

    Default sport varies by metric:
    - PMC and monotony default to sport='all' (whole-system load,
      including vardagsrörelse), matching get_form / readiness.
    - ACWR defaults to sport='running' (the classic km-based
      Hulin/Gabbett injury-risk metric — km doesn't compose across
      sports). Pass sport='all' explicitly for the multisport
      TRIMP-mode ACWR used by the daily push commentary.

    Args:
        metric: One of 'pmc' (Performance Management Chart with CTL/ATL/TSB),
                'acwr' (Acute:Chronic Workload Ratio), or
                'monotony' (Foster's training monotony and strain).
        n: Number of recent entries to show (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return the corresponding chart (PNG).
        sport: Sport bucket. Default depends on metric (see above).
            Examples: 'running', 'cycling', 'walking', 'strength',
            'all', 'endurance' (running+cycling+walking+swimming).
            See vayu://sports.
    """
    metric = metric.lower()
    report_map = {
        "pmc": ("report_pmc", "fetch.plot.pmc"),
        "acwr": ("report_acwr", "fetch.plot.acwr"),
        "monotony": ("report_monotony", "fetch.plot.monotony"),
    }
    if metric not in report_map:
        return {"type": "error", "message": f"Unknown metric: {metric}. Use pmc, acwr, or monotony."}

    # Per-metric default: ACWR stays running because its plot/report
    # still render km panels; PMC and monotony are whole-system.
    if sport is None:
        sport = "running" if metric == "acwr" else "all"

    report_func, plot_func = report_map[metric]
    args = _build_args(after, before, n, sport=sport)
    return _data_or_plot(report_func, plot_func, args, plot)


def get_efficiency(
    metric: str = "ef",
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
    sport: str = "running",
) -> Image | dict | list:
    """Efficiency trend: EF (Efficiency Factor) or HRE (Heart Rate Efficiency).

    EF = speed:HR ratio. HRE = avgHR x avgPace (beats/km).
    Both generalise to cycling/walking when speed and HR are present.

    Args:
        metric: 'ef' (Efficiency Factor) or 'hre' (Heart Rate Efficiency).
        n: Number of recent entries to show (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return the corresponding chart (PNG).
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    metric = metric.lower()
    report_map = {
        "ef": ("report_ef", "fetch.plot.ef"),
        "hre": ("report_hre", "fetch.plot.hre"),
    }
    if metric not in report_map:
        return {"type": "error", "message": f"Unknown metric: {metric}. Use ef or hre."}

    report_func, plot_func = report_map[metric]
    args = _build_args(after, before, n, sport=sport)
    return _data_or_plot(report_func, plot_func, args, plot)


def get_zones(
    n: int = 12,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
    sport: str = "running",
) -> Image | dict | list:
    """HR zone distribution (Seiler 3-zone model) and Polarization Index.

    Z1 (low, <VT1), Z2 (threshold), Z3 (high, >=VT2).
    PI > 2.0 = polarized training (Treff 2019).

    HR zones stay sport='running' by default because Garmin's
    per-session hrTimeInZone columns are anchored to whatever zone
    config was active for that sport — mixing cycling zones (different
    HRmax/VT thresholds) and running zones in one stacked bar can be
    misleading. Pass sport='all' explicitly to opt into the merged view.

    Args:
        n: Number of recent months to show (default 12).
        after: Start date filter.
        before: End date filter.
        plot: If True, return stacked bar chart of zone distribution (PNG).
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    args = _build_args(after, before, n, sport=sport)
    return _data_or_plot("report_hr_zones", "fetch.plot.hr_zones", args, plot)


# ---------------------------------------------------------------------------
# Run-profile (yearly characterization)
# ---------------------------------------------------------------------------

_RUN_CHARACTER_CHARTS = {
    "pace_year": "fetch.plot.pace_year",
    "pace_ridges": "fetch.plot.pace_year_ridges",
    "tertile_share": "fetch.plot.pace_tertile_share",
    "longest_runs": "fetch.plot.longest_runs_year",
    "season_pace": "fetch.plot.season_pace",
    "heatmap_km": "fetch.plot.heatmap_km",
    "cumulative_km": "fetch.plot.cumulative_km",
    "distance_pace_era": "fetch.plot.distance_pace_era",
}


def get_run_character(
    chart: str = "pace_year",
    after: Optional[str] = None,
    before: Optional[str] = None,
    sport: str = "running",
) -> Image | dict:
    """Yearly characterization plots (Löpprofil tab in the Shiny app).

    Plot-only tool: returns a PNG visualization of one of eight views that
    summarize how running has evolved year over year, season to season,
    or epoch to epoch.

    Args:
        chart: Which chart to render. One of:
            - 'pace_year'         — Yearly median pace with 25–75 %% ribbon
                                    and six objective milestone labels.
            - 'pace_ridges'       — Density ridges of pace per year,
                                    coloured by annual km total.
            - 'tertile_share'     — Share of annual km spent at calm /
                                    medium / fast pace (tertile split).
            - 'longest_runs'      — Stacked bars of each year's five
                                    longest runs; topmost segment +
                                    label = longest single run.
            - 'season_pace'       — Mean pace per ISO week, all years
                                    pooled, with season background
                                    bands and a loess curve.
            - 'heatmap_km'        — Heatmap of weekly km (woy × year);
                                    missing weeks shown grey.
            - 'cumulative_km'     — Weekly cumulative km per year;
                                    current year highlighted vs grey
                                    historical lines.
            - 'distance_pace_era' — Hex-density of distance vs pace,
                                    faceted by era (2005–2010 /
                                    2011–2016 / 2017–2021 / 2022–2026),
                                    with the dataset median as a fixed
                                    reference.
        after: Start date filter (cuts off earlier years from the
            visualization). Most useful for `cumulative_km` /
            `heatmap_km`. Other charts inherently span the full
            history; an `after` value just trims the year axis.
        before: End date filter (exclusive upper bound, but the user-
            facing value is treated as inclusive — see _build_args).
        sport: Sport bucket (default 'running'). See vayu://sports.

    Returns:
        Image (PNG) on success; {"type": "error", ...} dict if `chart`
        is unknown.
    """
    chart_norm = (chart or "").strip().lower()
    plot_func = _RUN_CHARACTER_CHARTS.get(chart_norm)
    if plot_func is None:
        return {
            "type": "error",
            "message": (
                f"Unknown chart: {chart!r}. Valid charts: "
                f"{sorted(_RUN_CHARACTER_CHARTS)}"
            ),
        }
    args = _build_args(after, before, sport=sport)
    return r_plot(plot_func, args)


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

def get_sessions(
    n: int = 20,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
    sport: str = "running",
) -> Image | dict | list:
    """List individual training sessions with distance, pace, HR.

    Args:
        n: Number of recent sessions to show (default 20).
        after: Start date filter.
        before: End date filter.
        plot: If True, return lollipop chart of sessions (PNG).
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    args = _build_args(after, before, n, sport=sport)
    return _data_or_plot("report_runs_year_month", "plot_runs_month", args, plot)


def get_monthly_summary(
    n: int = 12,
    after: Optional[str] = None,
    before: Optional[str] = None,
    top: bool = False,
    plot: bool = False,
    sport: str = "running",
) -> Image | dict | list:
    """Monthly volume summary per sport (distance, pace, sessions).

    Args:
        n: Number of entries to show (default 12).
        after: Start date filter.
        before: End date filter.
        top: If True, show top months by distance instead of current month comparison.
        plot: If True, return bar chart (PNG).
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    args = _build_args(after, before, n, sport=sport)
    if top:
        return _data_or_plot("report_monthtop", "plot_monthtop", args, plot)
    return _data_or_plot("report_monthstatus", "plot_monthstatus", args, plot)


def get_yearly_summary(
    n: int = None,
    after: Optional[str] = None,
    before: Optional[str] = None,
    top: bool = False,
    plot: bool = False,
    sport: str = "running",
) -> Image | dict | list:
    """Yearly volume summary per sport (total distance, sessions, pace).

    Args:
        n: Number of entries to show.
        after: Start date filter.
        before: End date filter.
        top: If True, summary covers full calendar years. If False,
            year-to-date (each year truncated at today's day-of-year).
        plot: If True, return a chart. With top=True the chart is a
            year-totals bar; with top=False it is a weekly cumulative
            km line plot with the current year highlighted against
            grey historical years.
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    args = _build_args(after, before, n, sport=sport)
    if top:
        return _data_or_plot("report_yearstop", "plot_yearstop", args, plot)
    return _data_or_plot("report_yearstatus", "fetch.plot.cumulative_km",
                         args, plot)


# ---------------------------------------------------------------------------
# Multi-sport visualisations
# ---------------------------------------------------------------------------

_SPORT_MIX_PERIODS = ("month", "week", "year")
_SPORT_MIX_METRICS = ("distance", "duration", "trimp")


def get_taper_plan(
    race_date: str,
    distance_km: Optional[float] = None,
    taper_weeks: int = 2,
) -> dict:
    """Weekly km schedule from this Monday through race week.

    Returns the per-week target volumes for the build / taper / race
    phases, anchored on the median of the last four complete ISO
    weeks of running. See docs/dev/race-taper-design.md for the
    algorithm.

    Args:
        race_date: ISO date of the race (YYYY-MM-DD). Must be on or
            after today.
        distance_km: Race distance in km. Surfaced in the response's
            `_meta` block; does not change the volume curve.
        taper_weeks: Number of reduced-volume weeks before the race
            (race week itself excluded). 1–4, default 2.
    """
    try:
        rd = date.fromisoformat(race_date)
    except ValueError as e:
        return {"type": "error",
                "message": f"race_date must be YYYY-MM-DD: {e}"}
    if rd < date.today():
        return {"type": "error",
                "message": f"race_date must be today or later: {race_date}"}
    if not (1 <= taper_weeks <= 4):
        return {"type": "error",
                "message": "taper_weeks must be between 1 and 4"}

    args: dict = {"race_date": rd.isoformat(),
                  "taper_weeks": int(taper_weeks)}
    if distance_km is not None:
        args["distance_km"] = float(distance_km)
    out = r_report("compute_taper_plan", args)
    # The R tibble carries race_date / distance_km / the insufficient-
    # baseline marker only as attributes, which jsonlite drops.
    # Re-surface them in _meta so the MCP client can label the plan
    # and explain a zero-row payload without re-deriving anything
    # from the request.
    if isinstance(out, dict):
        meta = dict(out.get("_meta", {}))
        meta["race_date"] = rd.isoformat()
        if distance_km is not None:
            meta["distance_km"] = float(distance_km)
        meta["taper_weeks"] = int(taper_weeks)
        summary = out.get("summary") or {}
        if summary.get("record_count") == 0:
            meta["insufficient_baseline"] = True
            meta["explanation"] = (
                "Ingen löpning de senaste 4 veckorna — taper-planen "
                "behöver en baseline. Logga några pass och försök igen."
            )
        out["_meta"] = meta
    return out


def get_race_readiness(
    target_date: str,
    taper_weeks: int = 2,
) -> dict:
    """Composite race-day readiness score with Swedish prose.

    Fuses CTL trend (fitness), projected TSB (form), HRV stability
    and resting-HR stability into a 0–100 score and a status label
    ("Klar" / "Tveksam" / "Inte klar"). Missing health data lowers
    the number of contributing components rather than the score
    itself.

    Args:
        target_date: ISO date of the race (YYYY-MM-DD).
        taper_weeks: How many reduced-volume weeks the TSB
            projection should assume. 1–4, default 2.
    """
    try:
        td = date.fromisoformat(target_date)
    except ValueError as e:
        return {"type": "error",
                "message": f"target_date must be YYYY-MM-DD: {e}"}
    if not (1 <= taper_weeks <= 4):
        return {"type": "error",
                "message": "taper_weeks must be between 1 and 4"}

    args: dict = {"target_date": td.isoformat(),
                  "taper_weeks": int(taper_weeks)}
    raw = _run_r("compute_race_readiness", args)
    # r_report() assumes tabular data; compute_race_readiness returns
    # a structured list (score / status / prose / components) so we
    # hand-roll a consistent envelope that surfaces the key fields in
    # `summary` instead of burying them in a dict-shaped `details`.
    if raw.get("type") == "error":
        return {
            "schema_version": "1.0",
            "summary": {"status": "error",
                         "message": raw.get("message", "")},
            "details": {},
            "_meta": {
                "func": "compute_race_readiness",
                "query_date": datetime.now().isoformat(),
                "target_date": td.isoformat(),
                "taper_weeks": int(taper_weeks),
            },
        }
    data = raw.get("data", {}) or {}
    return {
        "schema_version": "1.0",
        "summary": {
            "status": "ok",
            "readiness_score": data.get("score"),
            "readiness_status": data.get("status"),
            "days_until": data.get("days_until"),
            "target_date": data.get("target_date"),
            "prose": data.get("prose"),
        },
        "details": data.get("components", {}),
        "_meta": {
            "func": "compute_race_readiness",
            "query_date": datetime.now().isoformat(),
            "target_date": td.isoformat(),
            "taper_weeks": int(taper_weeks),
        },
    }


def get_sport_mix(
    period: str = "month",
    metric: str = "distance",
    after: Optional[str] = None,
    before: Optional[str] = None,
    min_value: float = 0.1,
) -> Image | dict:
    """Stacked bar chart: chosen metric per period broken down by sport.

    Useful for spotting sport-rotation patterns, training-camp blocks,
    and seasonal shifts (summer cycling vs winter running).

    Args:
        period: Bar resolution. One of 'month' (default), 'week', 'year'.
        metric: Aggregation axis. 'distance' (km, default), 'duration'
            (active minutes — visible for gym/strength too), or 'trimp'
            (Banister TRIMP, the effort axis that lets strength and
            endurance share the chart; requires HR + duration > 10 min).
        after: Start date filter.
        before: End date filter.
        min_value: Drop (period, sport) cells whose summed value falls
            below this threshold. Units follow `metric`.
    """
    period_norm = (period or "").strip().lower()
    if period_norm not in _SPORT_MIX_PERIODS:
        return {
            "type": "error",
            "message": (
                f"period must be one of {_SPORT_MIX_PERIODS}, "
                f"got {period!r}"
            ),
        }
    metric_norm = (metric or "").strip().lower()
    if metric_norm not in _SPORT_MIX_METRICS:
        return {
            "type": "error",
            "message": (
                f"metric must be one of {_SPORT_MIX_METRICS}, "
                f"got {metric!r}"
            ),
        }
    args = _build_args(after, before,
                       period=period_norm, metric=metric_norm,
                       min_value=min_value)
    return r_plot("plot_sport_mix", args)


def get_sport_ctl_overlay(
    sports: Optional[list[str]] = None,
    after: Optional[str] = None,
    before: Optional[str] = None,
) -> Image | dict:
    """CTL (chronic training load) overlay across multiple sport buckets.

    Reveals fitness shifts when a training block is dominated by one
    sport — e.g. running CTL falling during a cycling-heavy week while
    overall load (sport='all') stays steady.

    Args:
        sports: List of sport buckets to overlay. Defaults to
            ['running', 'cycling', 'walking', 'all'].
        after: Start date filter.
        before: End date filter.
    """
    if sports is None:
        sports = ["running", "cycling", "walking", "all"]
    args = _build_args(after, before, sports=sports)
    return r_plot("plot_sport_ctl_overlay", args)


def get_sport_calendar(
    after: Optional[str] = None,
    before: Optional[str] = None,
    sport: Optional[str] = None,
) -> Image | dict:
    """Activity calendar — one cell per day, coloured by dominant sport.

    GitHub-style heatmap. Quick visual of training frequency, sport-mix,
    and rest patterns.

    Args:
        after: Start date filter (default = 1 year before `before`).
        before: End date filter (default = today).
        sport: Restrict to a single bucket / curated bucket (e.g.
            'endurance' to hide gym/strength). Default = all sports.
    """
    args = _build_args(after, before)
    if sport is not None:
        args["sport"] = sport
    return r_plot("plot_sport_calendar", args)


# ---------------------------------------------------------------------------
# Trends
# ---------------------------------------------------------------------------

def get_decoupling(
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
    sport: str = "running",
) -> Image | dict | list:
    """Aerobic decoupling: pace/speed:HR drift between halves of a session.

    <3% well-coupled, 3-5% acceptable, 5-8% moderate drift, >8% significant.

    Args:
        n: Number of recent qualifying sessions (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return decoupling trend chart (PNG).
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    args = _build_args(after, before, n, sport=sport)
    return _data_or_plot("report_decoupling", "fetch.plot.decoupling", args, plot)


def get_recovery_hr(
    n: int = 28,
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
    sport: str = "all",
) -> Image | dict | list:
    """Post-workout recovery heart rate trend.

    Lower recovery HR indicates better cardiovascular fitness. Recovery
    HR is a sport-agnostic cardiovascular signal; default sport='all'
    reflects that. In practice Garmin only emits recovery HR for running
    today, so non-running buckets typically still return an empty result.

    Args:
        n: Number of recent sessions (default 28).
        after: Start date filter.
        before: End date filter.
        plot: If True, return recovery HR trend chart (PNG).
        sport: Sport bucket (default 'all'). See vayu://sports.
    """
    args = _build_args(after, before, n, sport=sport)
    return _data_or_plot("report_recovery_hr", "fetch.plot.recovery_hr", args, plot)


def get_resting_hr(
    after: Optional[str] = None,
    before: Optional[str] = None,
    plot: bool = False,
) -> Image | dict | list:
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
) -> Image | dict | list:
    """VO2max estimate trend (Apple Watch daily + Garmin per-activity).

    When plotting, overlays both sources for comparison.

    Args:
        after: Start date filter.
        before: End date filter.
        plot: If True, return dual-source VO2max trend chart (PNG).
    """
    args = _build_args(after, before)
    if plot:
        return r_plot("fetch.plot.vo2max", args)
    args.setdefault("n", 30)
    return r_report("report_readiness", args)


def get_health_metric(
    metric: str,
    after: Optional[str] = None,
    before: Optional[str] = None,
    n: int = 30,
) -> dict:
    """Return time series for any health metric from the database.

    Accepts common names and abbreviations — e.g. 'weight', 'vikt', 'bmi',
    'hrv', 'steps', 'spo2', 'vo2max'. Also accepts the canonical names like
    'weight_body_mass', 'heart_rate_variability', etc.
    Use vayu://metrics resource for the full list.

    Args:
        metric: Metric name or alias (e.g. 'weight', 'steps', 'hrv', 'vo2max').
        after: Start date filter.
        before: End date filter.
        n: Number of recent values (default 30). Ignored when date range given.
    """
    resolved = _resolve_metric(metric)
    args = _build_args(after, before, n, metric=resolved)
    result = r_report("report_metric", args)
    if resolved != metric:
        result.setdefault("_meta", {})["resolved_metric"] = resolved
    return result


def compare_periods(
    period_a_from: str,
    period_a_to: str,
    period_b_from: str,
    period_b_to: str,
    sport: str = "running",
) -> dict:
    """Compare two date ranges side by side (distance, pace, sessions).

    Args:
        period_a_from: Start of first period (e.g. '2025-01-01').
        period_a_to: End of first period.
        period_b_from: Start of second period.
        period_b_to: End of second period.
        sport: Sport bucket (default 'running'). See vayu://sports.
    """
    # Reuse _build_args() so the user-facing `to` parameter is inclusive
    # (other tools do this; otherwise the final day of each period would
    # be silently dropped because R uses an exclusive upper bound).
    args_a = _build_args(period_a_from, period_a_to, sport=sport)
    args_b = _build_args(period_b_from, period_b_to, sport=sport)
    a = r_report("report_datesum", args_a)
    b = r_report("report_datesum", args_b)

    return {
        "schema_version": "1.0",
        "summary": {
            "status": "ok",
            "period_a": f"{period_a_from} to {period_a_to}",
            "period_b": f"{period_b_from} to {period_b_to}",
            "sport": sport,
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
        "description": "Daily composite score (0-100) fusing HRV, sleep, resting HR, training load, and wrist temperature.",
        "components": "HRV 30%, Sleep 25%, Resting HR 20%, Training load 15%, Wrist temp 10% (falls back to 4-component model without wrist temp)",
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
        "description": "Speed (m/min) / avg HR (bpm). Higher = more efficient. Generalises to any sport with speed and HR.",
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
        "description": "Pace/speed:HR efficiency drift between first and second half of a session. Generalises to cycling/walking with steady speed + HR samples.",
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


# ---------------------------------------------------------------------------
# Health metric discovery
# ---------------------------------------------------------------------------

_HEALTH_METRIC_INFO: dict[str, tuple[str, str]] = {
    # (category, human-readable description)
    # Body
    "weight_body_mass":       ("Body", "Body weight (kg)"),
    "body_mass_index":        ("Body", "BMI"),
    "body_fat_percentage":    ("Body", "Body fat (%)"),
    "lean_body_mass":         ("Body", "Lean body mass (kg)"),
    "height":                 ("Body", "Height (cm)"),
    "body_temperature":       ("Body", "Body temperature"),
    # Heart
    "heart_rate":             ("Heart", "Heart rate (avg/min/max per day)"),
    "heart_rate_variability": ("Heart", "HRV as Ln(RMSSD)"),
    "resting_heart_rate":     ("Heart", "Resting heart rate"),
    "walking_heart_rate_average": ("Heart", "Walking heart rate average"),
    "cardio_recovery":        ("Heart", "Cardio recovery HR after exercise"),
    # Respiratory
    "respiratory_rate":       ("Respiratory", "Respiratory rate (breaths/min)"),
    "blood_oxygen_saturation": ("Respiratory", "SpO2 (%)"),
    "vo2_max":                ("Fitness", "VO2max estimate"),
    "six_minute_walking_test_distance": ("Fitness", "6-minute walk test distance"),
    # Activity
    "active_energy":          ("Activity", "Active energy burned (kJ — Apple Watch native unit; ~4.184 kJ per kcal)"),
    "basal_energy_burned":    ("Activity", "Basal metabolic energy (kcal)"),
    "step_count":             ("Activity", "Daily steps"),
    "walking_running_distance": ("Activity", "Walking + running distance (km)"),
    "flights_climbed":        ("Activity", "Flights of stairs climbed"),
    "apple_exercise_time":    ("Activity", "Exercise minutes (Apple Watch ring)"),
    "apple_stand_hour":       ("Activity", "Stand hours"),
    "apple_stand_time":       ("Activity", "Stand time (min)"),
    "cycling_distance":       ("Activity", "Cycling distance (km)"),
    "swimming_distance":      ("Activity", "Swimming distance (m)"),
    "swimming_stroke_count":  ("Activity", "Swimming stroke count"),
    "physical_effort":        ("Activity", "Physical effort (AppleExerciseIntensity)"),
    "mindful_minutes":        ("Activity", "Mindfulness minutes"),
    # Running mechanics
    "running_ground_contact_time": ("Running", "Ground contact time (ms)"),
    "running_power":          ("Running", "Running power (W)"),
    "running_speed":          ("Running", "Running speed (m/s)"),
    "running_stride_length":  ("Running", "Stride length (m)"),
    "running_vertical_oscillation": ("Running", "Vertical oscillation (cm)"),
    # Sleep
    "apple_sleeping_wrist_temperature": ("Sleep", "Wrist temperature deviation during sleep"),
    # Walking / Gait
    "walking_speed":          ("Walking", "Walking speed (km/h)"),
    "walking_step_length":    ("Walking", "Walking step length (cm)"),
    "walking_asymmetry_percentage": ("Walking", "Walking asymmetry (%)"),
    "walking_double_support_percentage": ("Walking", "Double support time (%)"),
    "stair_speed_up":         ("Walking", "Stair ascent speed (m/s)"),
    "stair_speed_down":       ("Walking", "Stair descent speed (m/s)"),
    # Environment
    "environmental_audio_exposure": ("Environment", "Environmental noise (dB)"),
    "headphone_audio_exposure": ("Environment", "Headphone audio level (dB)"),
    "time_in_daylight":       ("Environment", "Time in daylight (min)"),
    # Other
    "handwashing":            ("Other", "Handwashing events"),
    "number_of_times_fallen": ("Other", "Fall detection events"),
    "distance_downhill_snow_sports": ("Other", "Downhill snow sports distance"),
}


# Aliases: common names / abbreviations / Swedish → canonical metric name
_METRIC_ALIASES: dict[str, str] = {
    # Weight
    "weight": "weight_body_mass",
    "body_weight": "weight_body_mass",
    "body_mass": "weight_body_mass",
    "mass": "weight_body_mass",
    "vikt": "weight_body_mass",
    "kroppsvikt": "weight_body_mass",
    # BMI
    "bmi": "body_mass_index",
    # Body fat
    "body_fat": "body_fat_percentage",
    "fat": "body_fat_percentage",
    "fettprocent": "body_fat_percentage",
    "fett": "body_fat_percentage",
    # Heart rate
    "hr": "heart_rate",
    "heart": "heart_rate",
    "puls": "heart_rate",
    "hjärtfrekvens": "heart_rate",
    # HRV
    "hrv": "heart_rate_variability",
    # Resting HR
    "rhr": "resting_heart_rate",
    "resting_hr": "resting_heart_rate",
    "vilopuls": "resting_heart_rate",
    # VO2max
    "vo2": "vo2_max",
    "vo2max": "vo2_max",
    "kondition": "vo2_max",
    # Steps
    "steps": "step_count",
    "steg": "step_count",
    # SpO2
    "spo2": "blood_oxygen_saturation",
    "oxygen": "blood_oxygen_saturation",
    "syre": "blood_oxygen_saturation",
    "syremättnad": "blood_oxygen_saturation",
    # Respiratory
    "breathing": "respiratory_rate",
    "andning": "respiratory_rate",
    "andningsfrekvens": "respiratory_rate",
    # Sleep temperature
    "wrist_temp": "apple_sleeping_wrist_temperature",
    "wrist_temperature": "apple_sleeping_wrist_temperature",
    "sleep_temp": "apple_sleeping_wrist_temperature",
    "sleep_temperature": "apple_sleeping_wrist_temperature",
    "sovtemperatur": "apple_sleeping_wrist_temperature",
    # Activity
    "calories": "active_energy",
    "kalorier": "active_energy",
    "energy": "active_energy",
    "energi": "active_energy",
    "exercise": "apple_exercise_time",
    "exercise_time": "apple_exercise_time",
    "träning": "apple_exercise_time",
    "träningstid": "apple_exercise_time",
    "stand": "apple_stand_hour",
    "flights": "flights_climbed",
    "trappor": "flights_climbed",
    "distance": "walking_running_distance",
    "distans": "walking_running_distance",
    "cycling": "cycling_distance",
    "cykling": "cycling_distance",
    "swimming": "swimming_distance",
    "simning": "swimming_distance",
    # Walking
    "walking": "walking_speed",
    "gånghastighet": "walking_speed",
    "asymmetry": "walking_asymmetry_percentage",
    # Running
    "ground_contact": "running_ground_contact_time",
    "gct": "running_ground_contact_time",
    "power": "running_power",
    "stride": "running_stride_length",
    "oscillation": "running_vertical_oscillation",
    # Environment
    "noise": "environmental_audio_exposure",
    "buller": "environmental_audio_exposure",
    "daylight": "time_in_daylight",
    "dagsljus": "time_in_daylight",
    # Body temp
    "temp": "body_temperature",
    "temperatur": "body_temperature",
    # Lean mass
    "lean_mass": "lean_body_mass",
    "muskelmassa": "lean_body_mass",
    # Recovery
    "recovery": "cardio_recovery",
    "recovery_hr": "cardio_recovery",
    "återhämtning": "cardio_recovery",
}


def _resolve_metric(name: str) -> str:
    """Resolve a metric name, trying exact match, alias, then substring."""
    key = name.lower().strip()
    # Exact match
    available = _discover_health_metrics()
    if key in available:
        return key
    # Alias
    if key in _METRIC_ALIASES:
        return _METRIC_ALIASES[key]
    # Substring: if exactly one metric contains the query
    matches = [m for m in available if key in m]
    if len(matches) == 1:
        return matches[0]
    return key  # pass through, let R return empty if unknown


def _discover_health_metrics() -> list[str]:
    """Return sorted list of health metric names from the canonical directory."""
    data_dir = os.environ.get("TRANING_DATA")
    if not data_dir:
        try:
            from ..garmin.utils import get_data_dir
            data_dir = str(get_data_dir())
        except Exception:
            return sorted(_HEALTH_METRIC_INFO.keys())
    canonical = Path(data_dir) / "kristian" / "health_export" / "canonical"
    if not canonical.is_dir():
        return sorted(_HEALTH_METRIC_INFO.keys())
    return sorted(
        d.name for d in canonical.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )


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
# Form / state-based insight + raw data inspection
# ---------------------------------------------------------------------------

def get_form(date: Optional[str] = None) -> dict:
    """Today's form ("dagsform") in Swedish prose, with structured drivers.

    Returns a state-based interpretation of today's readiness: status
    (Grön/Gul/Röd), score (0-100), and what is driving it (sleep, HRV, RHR,
    training load, wrist temp) — each with absolute value, delta vs the
    natural baseline (7d for HRV/sleep, 30d for RHR, 14d for wrist temp),
    and a flag indicating whether it pulls the form down.

    Args:
        date: ISO date (default = today). Pass an older date for historical
              form, e.g. '2026-04-15'.
    """
    args: dict = {}
    if date:
        args["on_date"] = date
    raw = _run_r("health_insight_readiness", args)
    if raw.get("type") == "error":
        return raw
    payload = raw.get("data", {})
    if not isinstance(payload, dict):
        return {"type": "error", "message": "Unexpected form payload"}
    return {
        "schema_version": "1.0",
        "summary": {
            "status": "ok",
            "datum": payload.get("datum"),
            "form": payload.get("status"),
            "score": payload.get("score"),
            "kvalitet": payload.get("kvalitet"),
            "prosa": payload.get("prosa") or "",
        },
        "details": payload.get("components") or {},
        "_meta": {"func": "health_insight_readiness"},
    }


def get_recent_data(hours: int = 24) -> dict:
    """All metrics, sessions and pushes seen in the last N hours.

    Use as a "what do we know right now" dump. Note that health metric
    values are stored at date resolution, so the metrics-side window is
    rounded up to whole days; sessions and push events are timestamp-precise.

    Args:
        hours: Window size in hours (default 24).
    """
    raw = _run_r("recent_data_dump", {"hours": hours})
    if raw.get("type") == "error":
        return raw
    payload = raw.get("data", {})
    if not isinstance(payload, dict):
        return {"type": "error", "message": "Unexpected recent-data payload"}
    return {
        "schema_version": "1.0",
        "summary": {
            "status": "ok",
            "since": payload.get("since"),
            "until": payload.get("until"),
            "hours": payload.get("hours"),
            "metric_count": len(payload.get("metrics") or {}),
            "session_count": len(payload.get("sessions") or []),
            "push_count": len(payload.get("last_pushes") or []),
        },
        "details": {
            "metrics": payload.get("metrics") or {},
            "sessions": payload.get("sessions") or [],
            "last_pushes": payload.get("last_pushes") or [],
        },
        "_meta": {"func": "recent_data_dump"},
    }


def get_latest_known() -> dict:
    """Latest known value per metric — useful as a data-quality check.

    Returns one row per metric with the most recent date, value, and age in
    hours. Sorted oldest → newest so any stale metrics surface at the top.
    """
    return r_report("latest_known_metrics", {})


# ---------------------------------------------------------------------------
# Pipeline status
# ---------------------------------------------------------------------------

def _cache_mtime(filename: str) -> Optional[str]:
    """Return ISO timestamp of a cache file's mtime, or None if missing."""
    data_dir = os.environ.get("TRANING_DATA")
    if not data_dir:
        return None
    p = Path(data_dir) / "cache" / filename
    if not p.exists():
        return None
    return datetime.fromtimestamp(p.stat().st_mtime).isoformat(timespec="seconds")


def get_pipeline_status() -> dict:
    """Pipeline status — was the latest sync read in?

    Use this when the user asks whether automatic data ingestion is
    working, especially when no notification appeared (which is normal
    when the delta is empty under the new silent-on-noop behavior).

    Returns receiver state from /v1/status (last_received, last_import,
    pending debounce window) plus filesystem cross-check (cache mtimes
    for the health and Garmin caches).

    The receiver runs on the same host (kailash) and is queried via
    localhost using the API key from the environment. If the receiver
    is unreachable, the function still returns the cache mtimes plus
    an `error` field.
    """
    receiver_url = os.environ.get(
        "TRANING_RECEIVER_URL", "http://localhost:8421"
    )
    api_key = os.environ.get("TRANING_API_KEY")

    receiver: dict = {}
    error: Optional[str] = None

    if not api_key:
        error = "TRANING_API_KEY not set in environment"
    else:
        try:
            r = requests.get(
                f"{receiver_url}/v1/status",
                headers={"X-API-Key": api_key},
                timeout=3,
            )
            r.raise_for_status()
            receiver = r.json()
        except requests.RequestException as e:
            error = f"receiver unreachable: {e}"

    out: dict = {
        "receiver": receiver,
        "cache_health_daily": _cache_mtime("health_daily.RData"),
        "cache_summaries": _cache_mtime("summaries.RData"),
        "cache_myruns": _cache_mtime("myruns.RData"),
    }
    if error:
        out["error"] = error
    return out


# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

def resource_metrics() -> str:
    """List of all available metrics (training + health) with descriptions."""
    lines = ["# Training metrics (dedicated tools)\n"]
    for key, defn in _METRIC_DEFINITIONS.items():
        lines.append(f"## {defn['name']} ({key})\n{defn['description']}\n")

    # Health metrics (via get_health_metric)
    available = _discover_health_metrics()
    by_category: dict[str, list[str]] = {}
    uncategorized: list[str] = []
    for m in available:
        if m in _HEALTH_METRIC_INFO:
            cat, desc = _HEALTH_METRIC_INFO[m]
            by_category.setdefault(cat, []).append(f"- **{m}**: {desc}")
        else:
            uncategorized.append(f"- {m}")

    lines.append("\n# Health metrics (use get_health_metric)\n")
    lines.append("All metrics below are queried via `get_health_metric(metric='name')`.\n")
    for cat in [
        "Body", "Heart", "Respiratory", "Fitness", "Activity",
        "Running", "Sleep", "Walking", "Environment", "Other",
    ]:
        if cat in by_category:
            lines.append(f"## {cat}")
            lines.extend(by_category[cat])
            lines.append("")
    if uncategorized:
        lines.append("## Other metrics")
        lines.extend(uncategorized)
        lines.append("")

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


def resource_sports() -> str:
    """Available sport buckets for the `sport=` parameter on training tools.

    Curated reference — lists the canonical sport names known to
    .resolve_sport_bucket() in R, the Swedish aliases it accepts, and
    the multi-sport buckets defined there. The list is hard-coded
    (rather than read from the cache) because callers need stable
    documentation; if a brand-new sport string starts appearing in
    summaries$sport it can still be passed through verbatim, but it
    won't show up here until the resource is updated. The R helpers
    .SPORT_BUCKETS / .SPORT_ALIASES are the source of truth.
    """
    lines = [
        "# Sport buckets",
        "",
        "Pass any of these as `sport=...` to training tools",
        "(get_monthly_summary, get_yearly_summary, get_training_load,",
        "get_efficiency, get_zones, get_decoupling, get_sessions,",
        "get_recovery_hr, compare_periods).",
        "",
        "## Direct sport names (raw values in summaries$sport)",
        "",
        "Use these literals verbatim — they're matched by substring",
        "against the sport column.",
        "",
        "- **running**, **cycling**, **walking**, **swimming**, **strength**",
        "- karntraning, ovrigt, bordtennis, badminton, tennis,",
        "  paddelsporter, fotboll, hockey, fitness-spel",
        "- skridskosporter, snosporter, utforsakning, rodd, yoga,",
        "  bagskytte, sinne_&_kropp",
        "",
        "(Translation glossary: karntraning = core training,",
        "ovrigt = other, skridskosporter = ice skating sports,",
        "snosporter = snow sports, utforsakning = downhill skiing,",
        "rodd = rowing.)",
        "",
        "## Swedish aliases (resolved to direct names)",
        "",
        "- löpning / lopning → running",
        "- cykling / cykel → cycling",
        "- gång / gang / promenad → walking",
        "- simning → swimming",
        "- styrka / styrketräning → strength",
        "",
        "## Curated buckets",
        "",
        "- **endurance** = running + cycling + walking + swimming",
        "- **ballsport** = badminton + bordtennis + fotboll + tennis",
        "  + paddelsporter + hockey + fitness-spel",
        "- **wintersport** = skridskosporter + snosporter + utforsakning",
        "- **gym** = strength + karntraning + ovrigt",
        "",
        "## Special values (no filter)",
        "",
        "- **all** / **any** — match every sport in the cache",
        "",
        "## Notes",
        "",
        "- MCP tool schemas type `sport` as a string; pass `'all'` to",
        "  disable filtering, not `null`.",
        "- Vector input (e.g. running + cycling combined) is supported",
        "  by the underlying R helper but is not exposed via MCP today.",
        "  Use a curated bucket (`endurance`, `gym`, `ballsport`,",
        "  `wintersport`) or call the R API directly when you need a",
        "  bespoke combination.",
        "- Empty string and unrecognised sports return zero rows",
        "  (never silent pass-through).",
    ]
    return "\n".join(lines)
