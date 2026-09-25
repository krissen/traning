#' @keywords internal
"_PACKAGE"

## Declares NSE column names used in dplyr/ggplot2 pipelines as known to
## R CMD check and lintr's object_usage_linter. Without this, every
## unquoted data-frame column name referenced inside mutate()/filter()/
## aes() etc. is reported as an undefined global variable — object_usage_linter
## only stops treating these as globals once the package is loaded and this
## declaration is in scope (see .lintr / the local lintr pre-commit hook,
## which runs pkgload::load_all() first). Purely a lint annotation: it does
## not change behaviour at runtime.
##
## Generated once from the pre-.lintr baseline (2026-09-09); add new names
## here as they show up as findings rather than suppressing the linter.
utils::globalVariables(c(
  ".data", ".env", ".label", ".src_rank", ".value", ".x",
  "acute_load", "acwr", "ACWR", "acwr_uncoupled",
  "apple_sleeping_wrist_temperature", "atl", "ATL", "avg_hr", "avg_pace",
  "avgCadenceRunning", "avgCadenceRunningMoving", "avgHeartRate",
  "avgHeartRateMoving", "avgPaceMoving", "avgSpeed", "avgSpeedMoving",
  "avvikelse", "background_trimp", "Belastning", "bpm", "capped",
  "chronic_load", "count", "ctl", "CTL", "cumkm", "d_avg_dy", "Dag",
  "daily_dc", "daily_km", "daily_load", "daily_rhr", "daily_trimp",
  "data_quality", "datetime_str", "Datum", "day", "dayyear",
  "decoupling_pct", "decoupling_rolling28", "Dekopp %", "Dekopp 28d",
  "delta_hr", "dist_avg", "dist_sum", "distance", "distance_km", "dur_min",
  "duration", "duration_min", "durationMoving", "ef", "EF", "EF 28d",
  "ef_rolling28", "end_ts", "era", "era_base", "field", "func_registry",
  "Garmin", "garmin_hrTimeInZone_1", "garmin_hrTimeInZone_2",
  "garmin_hrTimeInZone_3", "garmin_hrTimeInZone_4", "garmin_hrTimeInZone_5",
  "garmin_maxHR", "garmin_recoveryHeartRate", "garmin_vO2MaxValue",
  "has_staging", "has_zero_zone", "health_daily", "heart_rate_variability",
  "hr", "HR", "hre", "HRE", "HRE 28d", "hre_rolling28", "hrv_flag",
  "hrv_score", "hrv_z", "intensity", "is_current", "iso_week", "iso_year",
  "k1", "k2", "k3", "k4", "k5", "kalla", "kalla_zon", "km", "Km", "km_bin",
  "km_hi", "km_lo", "Km, tot", "Km/dag", "Km/vecka", "label", "ln_rmssd",
  "ln_rmssd_7d_mean", "ln_rmssd_7d_sd", "lower", "max_hr_v", "mean_pace",
  "mean_rhr", "median_pace", "metric", "metric_suffix", "metrik",
  "mid_date", "Monotoni", "monotony", "month", "Mån", "n", "n_activities",
  "name", "p2", "p25", "p3", "p75", "pace", "Pace", "pace_avg", "pace_bin",
  "pace_hi", "pace_lo", "panel", "parsed", "pct", "period", "Persec", "PI",
  "pi_raw", "ratio_first", "ratio_second", "readiness_score",
  "readiness_status", "Recovery HR", "recovery_hr", "recovery_hr_rolling28",
  "resting_heart_rate", "resting_hr", "RHR 28d", "rhr_30d_mean",
  "rhr_deviation", "rhr_score", "roll_mean", "roll_sd", "seg1", "seg2",
  "seg3", "seg4", "seg5", "segment", "sessionStart", "sleep_deep",
  "sleep_flag", "sleep_rem", "sleep_score", "sleep_total",
  "sleep_totalSleep", "source_raw", "speed_m_per_min", "sport", "sport_sv",
  "src_rank", "stage", "start_ts", "strain", "tags", "Temp", "temperature",
  "Tempo", "Tid", "Tot min", "total", "total_km", "total_min", "total_sec",
  "trimp", "TRIMP", "trimp_ratio", "trimp_score", "trimp_type",
  "trimp_yesterday", "TRIMP/dag", "TRIMP/vecka", "tsb", "TSB", "Turer",
  "upper", "value", "value_clamp", "wday", "week", "weekly_km",
  "weekly_load", "weekly_pct_change", "workout_trimp", "woy", "wrist_temp",
  "wrist_temp_14d", "wrist_temp_deviation", "wrist_temp_score", "x", "y",
  "y_anchor", "year", "year_month", "year_week", "yr_total_km", "Z1 %",
  "z1_pct", "z1_sec", "z1_sec_sum", "Z2 %", "z2_pct", "z2_sec", "z2_sec_sum",
  "Z3 %", "z3_pct", "z3_sec", "z3_sec_sum", "zon", "År", "År-mån"
))
