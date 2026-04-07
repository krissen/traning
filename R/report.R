# Report functions — each returns a tibble (or prints to console)

#' Print summary of most recently imported workouts
#' @param summaries Data frame of recently imported summaries
#' @param n_imported Number of workouts imported
#' @export
report_mostrecent <- function(summaries, n_imported) {
  tot_distance <- round(sum(summaries$distance, na.rm = TRUE) / 1000, digits = 2)
  avg_distance <- round(mean(summaries$distance, na.rm = TRUE) / 1000, digits = 2)
  avg_duration <- round(
    mean(as.numeric(summaries$durationMoving), na.rm = TRUE), digits = 0)
  cat(n_imported, " workouts imported.\n", sep = "")
  cat("Distance: ", tot_distance,
      "km total; ", avg_distance, "km on average.\n", sep = "")
  cat("Average duration: ", avg_duration, " minutes.\n", sep = "")
}

#' Generate a short insight text for the most recent session
#'
#' Compares the latest run against the current month's average.
#' Output is a single line suitable for push notifications.
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return Character string (one line).
#' @export
report_insight <- function(summaries) {
  runs <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, "running")) %>%
    dplyr::arrange(sessionStart)

  if (nrow(runs) == 0) return("Ingen löpdata.")

  latest <- utils::tail(runs, 1)
  km <- round(as.numeric(latest$distance) / 1000, 1)
  pace <- dec_to_mmss(as.numeric(latest$avgPaceMoving))
  hr <- round(as.numeric(latest$avgHeartRateMoving), 0)

  # Compare to current month average
  this_month <- runs %>%
    dplyr::filter(
      format(sessionStart, "%Y-%m") == format(latest$sessionStart, "%Y-%m"),
      sessionStart < latest$sessionStart
    )

  if (nrow(this_month) >= 2) {
    avg_pace <- mean(as.numeric(this_month$avgPaceMoving), na.rm = TRUE)
    diff_sec <- (as.numeric(latest$avgPaceMoving) - avg_pace) * 60
    if (abs(diff_sec) < 5) {
      cmp <- paste0("i linje med m\u00e5nadens snitt (", dec_to_mmss(avg_pace), ")")
    } else if (diff_sec > 0) {
      cmp <- paste0("lugnare \u00e4n m\u00e5nadens snitt (",
                     dec_to_mmss(avg_pace), ")")
    } else {
      cmp <- paste0("snabbare \u00e4n m\u00e5nadens snitt (",
                     dec_to_mmss(avg_pace), ")")
    }
    paste0("L\u00f6pning ", km, " km, ", pace, "/km, puls ", hr, ". ",
           toupper(substr(cmp, 1, 1)), substr(cmp, 2, nchar(cmp)), ".")
  } else {
    paste0("L\u00f6pning ", km, " km, ", pace, "/km, puls ", hr, ".")
  }
}

#' Summarise runs within a date range
#' @param summaries Data frame of all workout summaries
#' @param do_datesum_from Start date (Date object)
#' @param do_datesum_to End date (Date object)
#' @return Tibble with summary statistics
#' @export
report_datesum <- function(summaries, do_datesum_from, do_datesum_to) {
  summaries <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running'))
  filtered_summaries <- summaries %>%
    dplyr::filter(sessionStart >= do_datesum_from & sessionStart < do_datesum_to)

  filtered_summaries %>%
    dplyr::summarise(
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Km, med' = round(mean(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      'Puls, medel' = round(mean(as.numeric(avgHeartRateMoving), na.rm = TRUE), 0),
      Turer = dplyr::n(),
      .groups = "keep") -> datesum
  datesum
}

#' Top months by total distance
#' @param summaries Data frame of all workout summaries
#' @param n Number of top months to return (default 10).
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @return Tibble with top months
#' @export
report_monthtop <- function(summaries, n = 10, from = NULL, to = NULL) {
  summaries <- .filter_input(summaries, from, to)

  summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(`År-mån` = format(sessionStart, "%Y-%m")) %>%
    dplyr::select(`År-mån`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År-mån`) %>%
    dplyr::summarise(
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(dplyr::desc(`Km, tot`)) %>%
    utils::head(n = n)
}

#' List individual runs within a date range
#'
#' Defaults to the current calendar month when neither \code{from} nor
#' \code{to} is given.
#'
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @return Tibble with individual runs
#' @export
report_runs_year_month <- function(summaries, n = NULL,
                                   from = NULL, to = NULL) {
  # Default to current month if no range specified
  if (is.null(from) && is.null(to)) {
    from <- as.Date(format(Sys.Date(), "%Y-%m-01"))
    to <- from + lubridate::period(1, "month")
  }

  summaries <- .filter_input(summaries, from, to)

  result <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(
      'År' = as.numeric(format(sessionStart, "%Y")),
      'Mån' = as.numeric(format(sessionStart, "%m")),
      'Dag' = as.numeric(format(sessionStart, "%d")),
      'Km' = round(distance / 1000, digits = 1),
      'Pace' = round(avgPaceMoving, digits = 2),
      'HR' = round(avgHeartRateMoving, digits = 0)
    ) %>%
    dplyr::select(`År`, `Mån`, `Dag`, Km, Pace, HR) %>%
    dplyr::arrange(dplyr::desc(`Dag`))

  if (!is.null(n)) result <- utils::head(result, n)
  result
}

#' Compare last month across all years
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @return Tibble with per-year statistics for last month
#' @export
report_monthlast <- function(summaries, n = NULL, from = NULL, to = NULL) {
  summaries <- .filter_input(summaries, from, to)

  my_month <- as.numeric(format(Sys.time(), "%m"))
  do_month <- if (my_month == 1) 12L else my_month - 1L
  my_day <- as.numeric(format(Sys.time(), "%d"))

  result <- summaries %>%
    dplyr::mutate(month = as.numeric(format(sessionStart, "%m"))) %>%
    dplyr::filter(month == do_month,
                  stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate('År' = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((sum(distance) / 1000) / my_day, 2),
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(dplyr::desc(`År`))

  if (!is.null(n)) result <- utils::head(result, n)
  result
}

#' Year statistics — all time (full years, not truncated at current date)
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @return Tibble with per-year statistics
#' @export
report_yearstop <- function(summaries, n = NULL, from = NULL, to = NULL) {
  summaries <- .filter_input(summaries, from, to)
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))

  result <- summaries %>%
    dplyr::mutate('År' = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((sum(distance) / 1000) / my_dayyear, 2),
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(dplyr::desc(`År`))

  if (!is.null(n)) result <- utils::head(result, n)
  result
}

#' Year statistics — truncated at current day-of-year for fair comparison
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @return Tibble with per-year statistics up to current day-of-year
#' @export
report_yearstatus <- function(summaries, n = NULL, from = NULL, to = NULL) {
  summaries <- .filter_input(summaries, from, to)
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))

  result <- summaries %>%
    dplyr::mutate(
      dayyear = as.numeric(format(sessionStart, "%j")),
      'År' = as.numeric(format(sessionStart, "%Y"))
    ) %>%
    dplyr::filter(
      dayyear <= my_dayyear,
      stringr::str_detect(sport, 'running')) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((sum(distance) / 1000) / my_dayyear, 2),
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(dplyr::desc(`År`))

  if (!is.null(n)) result <- utils::head(result, n)
  result
}

#' Current month compared across years (truncated at current day-of-month)
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @return Tibble with per-year statistics for current month
#' @export
report_monthstatus <- function(summaries, n = NULL, from = NULL, to = NULL) {
  summaries <- .filter_input(summaries, from, to)
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))

  result <- summaries %>%
    dplyr::mutate(month = as.numeric(format(sessionStart, "%m"))) %>%
    dplyr::filter(month == my_month,
                  stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(
      day = as.numeric(format(sessionStart, "%d")),
      'År' = as.numeric(format(sessionStart, "%Y"))
    ) %>%
    dplyr::filter(day <= my_day) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((sum(distance) / 1000) / my_day, 2),
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(dplyr::desc(`År`))

  if (!is.null(n)) result <- utils::head(result, n)
  result
}

# --- Shared helpers ----------------------------------------------------------

# Filter input summaries by date range on sessionStart.
# Used by basic report functions that aggregate (month/year comparisons).
.filter_input <- function(summaries, from = NULL, to = NULL) {
  filter_by_daterange(summaries, list(from = from, to = to))
}

# --- Advanced metric reports ------------------------------------------------
# Each calls its compute_*() function and returns a formatted tibble.
# When from/to are given, the output is filtered by date range.
# Otherwise the last n rows are returned.

.tail_or_daterange <- function(data, n, from, to, date_col) {
  if (!is.null(from) || !is.null(to)) {
    if (!is.null(from)) data <- dplyr::filter(data, .data[[date_col]] >= from)
    if (!is.null(to))   data <- dplyr::filter(data, .data[[date_col]] < to)
  } else {
    data <- utils::tail(data, n = n)
  }
  # Newest first — the user reads top-to-bottom
  data <- dplyr::arrange(data, dplyr::desc(.data[[date_col]]))
  data
}

#' Efficiency Factor report — recent runs with EF values
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param n Number of rows to show (default 28). Ignored when from/to given.
#' @param from Date or NULL. Start of display window (inclusive).
#' @param to Date or NULL. End of display window (exclusive).
#' @return Tibble
#' @export
report_ef <- function(summaries, n = 28, from = NULL, to = NULL) {
  compute_efficiency_factor(summaries) %>%
    dplyr::mutate(
      Datum = sessionStart,
      Km = round(distance_km, 1),
      EF = round(ef, 2),
      `EF 28d` = round(ef_rolling28, 2)
    ) %>%
    dplyr::select(Datum, Km, EF, `EF 28d`) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' Heart Rate Efficiency report — recent runs with HRE values
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_hre <- function(summaries, n = 28, from = NULL, to = NULL) {
  compute_hre(summaries) %>%
    dplyr::mutate(
      Datum = sessionStart,
      Km = round(distance_km, 1),
      HRE = round(hre, 0),
      `HRE 28d` = round(hre_rolling28, 0)
    ) %>%
    dplyr::select(Datum, Km, HRE, `HRE 28d`) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' ACWR report — recent daily values
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_acwr <- function(summaries, n = 28, from = NULL, to = NULL) {
  compute_acwr(summaries) %>%
    dplyr::mutate(
      Datum = date,
      `Km/dag` = round(daily_km, 1),
      `Km/vecka` = round(weekly_km, 1),
      ACWR = round(acwr, 2)
    ) %>%
    dplyr::select(Datum, `Km/dag`, `Km/vecka`, ACWR) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' Training Monotony and Strain report — recent daily values
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_monotony <- function(summaries, n = 28, from = NULL, to = NULL) {
  compute_monotony_strain(summaries) %>%
    dplyr::mutate(
      Datum = date,
      `Km/dag` = round(daily_km, 1),
      `Km/vecka` = round(weekly_km, 1),
      Monotoni = round(monotony, 2),
      Belastning = round(strain, 1)
    ) %>%
    dplyr::select(Datum, `Km/dag`, `Km/vecka`, Monotoni, Belastning) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' Performance Management Chart report — recent daily values
#' @inheritParams report_ef
#' @param hr_max Numeric or NULL. HRmax override.
#' @param hr_rest Numeric or NULL. HRrest override.
#' @return Tibble
#' @export
report_pmc <- function(summaries, n = 28, from = NULL, to = NULL,
                       hr_max = NULL, hr_rest = NULL) {
  compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest) %>%
    dplyr::mutate(
      Datum = date,
      TRIMP = round(daily_trimp, 1),
      CTL = round(ctl, 1),
      ATL = round(atl, 1),
      TSB = round(tsb, 1)
    ) %>%
    dplyr::select(Datum, TRIMP, CTL, ATL, TSB) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' Recovery Heart Rate report — recent runs with recovery HR
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_recovery_hr <- function(summaries, n = 28, from = NULL, to = NULL) {
  data <- compute_recovery_hr(summaries)
  if (nrow(data) == 0) {
    return(tibble::tibble(
      Datum = as.Date(character(0)), Km = numeric(0),
      `Recovery HR` = numeric(0), `RHR 28d` = numeric(0)))
  }
  data %>%
    dplyr::mutate(
      Datum = sessionStart,
      Km = round(distance_km, 1),
      `Recovery HR` = round(recovery_hr, 0),
      `RHR 28d` = round(recovery_hr_rolling28, 0)
    ) %>%
    dplyr::select(Datum, Km, `Recovery HR`, `RHR 28d`) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' HR zone distribution report — monthly Seiler 3-zone percentages
#'
#' Returns monthly zone distribution with Polarization Index.  Uses Garmin
#' Connect hrTimeInZone data mapped to Seiler 3-zone model (Z1 = low,
#' Z2 = threshold, Z3 = high).
#'
#' @inheritParams report_ef
#' @return Tibble with monthly zone distribution and PI
#' @export
report_hr_zones <- function(summaries, n = 12, from = NULL, to = NULL,
                            zone_data = NULL) {
  if (is.null(zone_data)) zone_data <- compute_zone_distribution(summaries)

  if (nrow(zone_data$monthly) == 0) {
    return(tibble::tibble(
      Datum = as.Date(character(0)),
      `Z1 %` = numeric(0), `Z2 %` = numeric(0), `Z3 %` = numeric(0),
      PI = numeric(0), Turer = integer(0), `Tot min` = numeric(0)))
  }

  pi_data <- compute_polarization_index(zone_data)

  pi_data %>%
    dplyr::mutate(
      Datum     = as.Date(paste0(year_month, "-01")),
      `Z1 %`    = round(z1_pct, 1),
      `Z2 %`    = round(z2_pct, 1),
      `Z3 %`    = round(z3_pct, 1),
      PI        = round(pi, 2),
      Turer     = n_activities
    ) %>%
    dplyr::left_join(
      zone_data$monthly %>%
        dplyr::select(year_month, total_min),
      by = "year_month"
    ) %>%
    dplyr::mutate(`Tot min` = round(total_min, 0)) %>%
    dplyr::select(Datum, `Z1 %`, `Z2 %`, `Z3 %`, PI, Turer, `Tot min`) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' Aerobic Decoupling report — recent qualifying runs
#'
#' Shows per-run decoupling percentage (pace:HR drift between first and second
#' half) with 28-day rolling mean.  Requires per-second data from myruns.
#'
#' @param decoupling_data Tibble from \code{compute_decoupling()} or
#'   \code{load_decoupling()}.  If NULL, computed on the fly from
#'   \code{summaries} and \code{myruns}.
#' @param summaries Summaries tibble (only used if \code{decoupling_data} is NULL).
#' @param myruns Myruns list (only used if \code{decoupling_data} is NULL).
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_decoupling <- function(summaries = NULL, myruns = NULL,
                              n = 28, from = NULL, to = NULL,
                              decoupling_data = NULL) {
  if (is.null(decoupling_data)) {
    decoupling_data <- compute_decoupling(summaries, myruns)
  }

  if (nrow(decoupling_data) == 0) {
    return(tibble::tibble(
      Datum = as.Date(character(0)), Km = numeric(0),
      Tempo = character(0), HR = numeric(0),
      `Dekopp %` = numeric(0), `Dekopp 28d` = numeric(0),
      Temp = numeric(0)))
  }

  decoupling_data %>%
    dplyr::mutate(
      Datum       = sessionStart,
      Km          = round(distance_km, 1),
      Tempo       = vapply(avg_pace, dec_to_mmss, character(1)),
      HR          = round(avg_hr, 0),
      `Dekopp %`  = round(decoupling_pct, 1),
      `Dekopp 28d` = round(decoupling_rolling28, 1),
      Temp        = round(temperature, 0)
    ) %>%
    dplyr::select(Datum, Km, Tempo, HR, `Dekopp %`, `Dekopp 28d`, Temp) %>%
    .tail_or_daterange(n, from, to, "Datum")
}

#' Readiness report — daily composite score with components
#'
#' @param health_daily Long-format tibble from \code{load_health_data()}.
#' @param summaries Garmin summaries tibble.
#' @param n Number of most recent days to show (default 14).
#' @param from Start date (inclusive). Overrides n.
#' @param to End date (exclusive). Overrides n.
#' @param hr_max Optional HRmax override.
#' @param hr_rest Optional HRrest override.
#' @return Tibble with Swedish column names.
#' @export
report_readiness <- function(health_daily, summaries, n = 14,
                              from = NULL, to = NULL,
                              hr_max = NULL, hr_rest = NULL) {
  r <- compute_readiness(health_daily, summaries,
                          hr_max = hr_max, hr_rest = hr_rest)
  if (nrow(r) == 0) {
    return(tibble::tibble(Datum = as.Date(character(0))))
  }
  r |>
    dplyr::mutate(
      Datum       = date,
      Beredskap   = round(readiness_score, 0),
      Status      = readiness_status,
      `Ln RMSSD`  = round(ln_rmssd, 2),
      `HRV z`     = round(hrv_z, 1),
      Vilopuls    = round(resting_hr, 0),
      `VP avvik`  = round(rhr_deviation, 1),
      `Sömn` = round(sleep_total, 1),
      TRIMP       = round(daily_trimp, 0),
      TSB         = round(tsb, 1),
      Kvalitet    = data_quality
    ) |>
    dplyr::select(Datum, Beredskap, Status, `Ln RMSSD`, `HRV z`,
                  Vilopuls, `VP avvik`, `Sömn`, TRIMP, TSB,
                  Kvalitet) |>
    .tail_or_daterange(n, from, to, "Datum")
}
