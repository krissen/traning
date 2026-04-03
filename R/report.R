# Report functions — each returns a tibble (or prints to console)

#' Print summary of most recently imported workouts
#' @param summaries Data frame of recently imported summaries
#' @param n_imported Number of workouts imported
#' @export
report_mostrecent <- function(summaries, n_imported) {
  tot_distance <- round(sum(summaries$distance) / 1000, digits = 2)
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
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      'Km, med' = mean(distance) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      'Puls, medel' = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      Turer = dplyr::n(),
      .groups = "keep") -> datesum
  datesum
}

#' Top 10 months by total distance
#' @param summaries Data frame of all workout summaries
#' @return Tibble with top 10 months
#' @export
report_monthtop <- function(summaries) {
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
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(`Km, tot`, .by_group = FALSE) %>%
    utils::tail(n = 10) -> month_top

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
      'Km' = round(distance / 1000, digits = 2),
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
      'Km/dag' = (sum(distance) / 1000) / my_day,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
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
      'Km/dag' = (sum(distance) / 1000) / my_dayyear,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
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
      'Km/dag' = (sum(distance) / 1000) / my_dayyear,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
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
      'Km/dag' = (sum(distance) / 1000) / my_day,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(`Km/dag`, .by_group = FALSE) -> month_summaries_til_day

  return(month_summaries_til_day)
}
