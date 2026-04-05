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

#' Top 10 months by total distance
#' @param summaries Data frame of all workout summaries
#' @return Tibble with top 10 months
#' @export
report_monthtop <- function(summaries, n = 10) {
  summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
    dplyr::mutate(
      day = as.numeric(format(sessionStart, "%d")),
      `År-mån` = format(sessionStart, "%Y-%m")
    ) %>%
    dplyr::select(`År-mån`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År-mån`) %>%
    dplyr::summarise(
      'Km, tot' = round(sum(distance) / 1000, 1),
      'Km, max' = round(max(distance) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(`Km, tot`, .by_group = FALSE) %>%
    utils::tail(n = n) -> month_top

  return(month_top)
}

#' List individual runs for a given year and month
#' @param summaries Data frame of all workout summaries
#' @param do_year Year as string (default: current year)
#' @param do_month Month as string (default: current month)
#' @return Tibble with individual runs
#' @export
report_runs_year_month <- function(summaries,
                                   do_year = format(Sys.time(), "%Y"),
                                   do_month = format(Sys.time(), "%m")) {

  summaries %>%
    dplyr::mutate(
      month = as.numeric(format(sessionStart, "%m")),
      year = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::filter(
      month == as.numeric(do_month),
      year == as.numeric(do_year),
      stringr::str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
    dplyr::mutate(
      'År' = as.numeric(format(sessionStart, "%Y")),
      'Mån' = as.numeric(format(sessionStart, "%m")),
      'Dag' = as.numeric(format(sessionStart, "%d")),
      'Km' = round(distance / 1000, digits = 1),
      'Pace' = round(avgPaceMoving, digits = 2),
      'HR' = round(avgHeartRateMoving, digits = 0)
    ) %>%
    dplyr::select(`År`, `Mån`, `Dag`, Km, Pace, HR) %>%
    dplyr::arrange(`Dag`) -> runs_year_month

  return(runs_year_month)
}

#' Compare last month across all years
#' @param summaries Data frame of all workout summaries
#' @return Tibble with per-year statistics for last month
#' @export
report_monthlast <- function(summaries) {
  my_year <- as.numeric(format(Sys.time(), "%Y"))
  my_month <- as.numeric(format(Sys.time(), "%m"))
  if (my_month == 1) {
    do_year <- my_year - 1
    do_month <- 12
  } else {
    do_year <- my_year
    do_month <- my_month - 1
  }

  print(paste("Visar data för ", month.name[do_month], sep = ""))

  my_day <- as.numeric(format(Sys.time(), "%d"))

  summaries %>%
    dplyr::mutate(month = as.numeric(format(sessionStart, "%m"))) %>%
    dplyr::filter(month == do_month,
                  stringr::str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
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
    dplyr::arrange(`Km/dag`, .by_group = FALSE) -> month_summaries_last

  return(month_summaries_last)
}

#' Year statistics — all time (full years, not truncated at current date)
#' @param summaries Data frame of all workout summaries
#' @return Tibble with per-year statistics
#' @export
report_yearstop <- function(summaries) {
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))

  summaries %>%
    dplyr::mutate(
      day = as.numeric(format(sessionStart, "%d")),
      dayyear = as.numeric(format(sessionStart, "%j")),
      'År' = as.numeric(format(sessionStart, "%Y"))
    ) %>%
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
    dplyr::arrange(`Km/dag`, .by_group = FALSE) -> year_summaries_til_day

  return(year_summaries_til_day)
}

#' Year statistics — truncated at current day-of-year for fair comparison
#' @param summaries Data frame of all workout summaries
#' @return Tibble with per-year statistics up to current day-of-year
#' @export
report_yearstatus <- function(summaries) {
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))

  summaries %>%
    dplyr::mutate(
      day = as.numeric(format(sessionStart, "%d")),
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
    dplyr::arrange(`Km/dag`, .by_group = FALSE) -> year_summaries_til_day

  return(year_summaries_til_day)
}

#' Current month compared across years (truncated at current day-of-month)
#' @param summaries Data frame of all workout summaries
#' @return Tibble with per-year statistics for current month
#' @export
report_monthstatus <- function(summaries) {
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))

  summaries %>%
    dplyr::mutate(month = as.numeric(format(sessionStart, "%m"))) %>%
    dplyr::filter(month == my_month,
                  stringr::str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
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
    dplyr::arrange(`Km/dag`, .by_group = FALSE) -> month_summaries_til_day

  return(month_summaries_til_day)
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
