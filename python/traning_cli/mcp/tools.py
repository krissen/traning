"""Vayu MCP tools — curated training analysis functions."""

import os
from datetime import date, timedelta
from pathlib import Path
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
) -> dict | list:
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
    "active_energy":          ("Activity", "Active calories burned (kcal)"),
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
