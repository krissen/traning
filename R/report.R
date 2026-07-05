# Report functions — each returns a tibble (or prints to console)

# Internal: apply a reducer with na.rm = TRUE, but return NA_real_ when
# the input is all NA. Without this guard, max/min on an all-NA vector
# returns -Inf/Inf (with warning), and mean returns NaN. sum returns 0,
# which would be misleadingly shown as zero distance for a period with
# only broken imports — prefer NA so plots/tables omit the bar.
.na_safe <- function(x, fun) {
  if (all(is.na(x))) NA_real_ else fun(x, na.rm = TRUE)
}

#' Print summary of most recently imported workouts
#' @param summaries Data frame of recently imported summaries
#' @param n_imported Number of workouts imported
#' @export
report_mostrecent <- function(summaries, n_imported) {
  tot_km <- round(sum(summaries$distance, na.rm = TRUE) / 1000, 1)
  dates <- range(as.Date(summaries$sessionStart))
  date_str <- if (dates[1] == dates[2]) {
    format(dates[1], "%d %b")
  } else {
    paste(format(dates[1], "%d %b"), format(dates[2], "%d %b"), sep = "\u2013")
  }
  cat("Import: ", n_imported, " pass (", date_str, "), ",
      tot_km, " km totalt.\n", sep = "")
}

#' Generate a short insight text for the most recent session
#'
#' Compares the latest session against the current month's average.
#' Output is a single line suitable for push notifications.
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Character string (one line).
#' @export
report_insight <- function(summaries, sport = "running") {
  # Per-pass post-workout notification body. For running, delegates to
  # session_prose() (qualitative, research-grounded). For other sports
  # it falls back to the legacy quantitative line via the same helper.
  # See R/session_prose.R for sources and prose rules.
  #
  # trigger_source = "garmin" opts in to the TCX-priority latest-pass
  # selection. report_insight() is the Garmin-trigger entry point in
  # this codebase (Python's _run_insight_garmin shells out to this).
  # Other callers using session_prose() directly keep the default
  # "any" semantics so an arbitrary "latest pass" lookup still picks
  # the most recent row regardless of source.
  session_prose(summaries, sport = sport, trigger_source = "garmin")
}

#' Summarise sessions within a date range
#' @param summaries Data frame of all workout summaries
#' @param do_datesum_from Start date (Date object)
#' @param do_datesum_to End date (Date object)
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Tibble with summary statistics
#' @export
report_datesum <- function(summaries, do_datesum_from, do_datesum_to,
                           sport = "running") {
  summaries <- .filter_sport(summaries, sport)
  filtered_summaries <- summaries %>%
    dplyr::filter(sessionStart >= do_datesum_from & sessionStart < do_datesum_to)

  filtered_summaries %>%
    dplyr::summarise(
      'Km, tot' = round(.na_safe(distance, sum) / 1000, 1),
      'Km, max' = round(.na_safe(distance, max) / 1000, 1),
      'Km, med' = round(.na_safe(distance, mean) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(.na_safe(avgPaceMoving, mean)),
      'Tempo, max' = dec_to_mmss(.na_safe(avgPaceMoving, min)),
      'Puls, medel' = round(.na_safe(as.numeric(avgHeartRateMoving), mean), 0),
      Turer = dplyr::n(),
      .groups = "keep") -> datesum
  datesum
}

#' Top months by total distance
#' @param summaries Data frame of all workout summaries
#' @param n Number of top months to return (default 10).
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Tibble with top months
#' @export
report_monthtop <- function(summaries, n = 10, from = NULL, to = NULL,
                            sport = "running") {
  summaries <- .filter_input(summaries, from, to)

  .filter_sport(summaries, sport) %>%
    dplyr::mutate(`År-mån` = format(sessionStart, "%Y-%m")) %>%
    dplyr::select(`År-mån`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År-mån`) %>%
    dplyr::summarise(
      'Km, tot' = round(.na_safe(distance, sum) / 1000, 1),
      'Km, max' = round(.na_safe(distance, max) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(.na_safe(avgPaceMoving, mean)),
      Turer = dplyr::n(),
      .groups = "keep") %>%
    dplyr::arrange(dplyr::desc(`Km, tot`)) %>%
    utils::head(n = n)
}

#' List individual sessions within a date range
#'
#' In the default (month-scoped) mode, defaults to the current calendar
#' month when neither \code{from} nor \code{to} is given, and returns a
#' numeric \code{Pace} column (decimal min/km) for the plot colour scale
#' and CLI aggregation. With \code{recent = TRUE} it skips that default
#' (returning the latest sessions across months) and reports pace as an
#' mm:ss \code{Tempo} string instead, so MCP clients cannot misread the
#' decimal 4.26 as the clock time 4:26.
#'
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @param recent If TRUE, skip the current-month default and report pace
#'   as an mm:ss \code{Tempo} column instead of the numeric \code{Pace}.
#' @return Tibble with individual sessions
#' @export
report_runs_year_month <- function(summaries, n = NULL,
                                   from = NULL, to = NULL,
                                   sport = "running",
                                   recent = FALSE) {
  # Month-scoped callers (e.g. CLI --month-this) with no explicit range
  # default to the current month. recent = TRUE (the get_sessions
  # "latest N sessions" path) opts out, so an empty current month does
  # not hide older sessions.
  if (!recent && is.null(from) && is.null(to)) {
    from <- as.Date(format(Sys.Date(), "%Y-%m-01"))
    to <- from + lubridate::period(1, "month")
  }

  summaries <- .filter_input(summaries, from, to)

  result <- .filter_sport(summaries, sport) %>%
    dplyr::mutate(
      'År' = as.numeric(format(sessionStart, "%Y")),
      'Mån' = as.numeric(format(sessionStart, "%m")),
      'Dag' = as.numeric(format(sessionStart, "%d")),
      'Km' = round(distance / 1000, digits = 1),
      'Pace' = round(avgPaceMoving, digits = 2),
      'HR' = round(avgHeartRateMoving, digits = 0)
    ) %>%
    # Sort on the full timestamp, not the day-of-month: desc(Dag) alone
    # interleaves months when the range spans a boundary, so head(n)
    # could drop the newest session (e.g. Jul 4 sorting below Jun 28-30).
    dplyr::arrange(dplyr::desc(sessionStart)) %>%
    dplyr::select(`År`, `Mån`, `Dag`, Km, Pace, HR)

  if (!is.null(n)) result <- utils::head(result, n)

  if (recent) {
    # Present pace as mm:ss so MCP clients don't misread the decimal
    # (4.26 min/km) as a clock time. Applied after head(n) so only the
    # returned rows are formatted, via dec_to_mmss() — the single source
    # of pace formatting shared with the other reports.
    result <- result %>%
      dplyr::mutate('Tempo' = vapply(Pace, dec_to_mmss, character(1))) %>%
      dplyr::select(`År`, `Mån`, `Dag`, Km, Tempo, HR)
  }
  result
}

#' Compare last month across all years
#' @param summaries Data frame of all workout summaries
#' @param n Max rows to return, or NULL for all.
#' @param from Date or NULL. Include only activities from this date (inclusive).
#' @param to Date or NULL. Include only activities before this date (exclusive).
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Tibble with per-year statistics for last month
#' @export
report_monthlast <- function(summaries, n = NULL, from = NULL, to = NULL,
                             sport = "running") {
  summaries <- .filter_input(summaries, from, to)
  summaries <- .filter_sport(summaries, sport)

  my_month <- as.numeric(format(Sys.time(), "%m"))
  do_month <- if (my_month == 1) 12L else my_month - 1L
  my_day <- as.numeric(format(Sys.time(), "%d"))

  result <- summaries %>%
    dplyr::mutate(month = as.numeric(format(sessionStart, "%m"))) %>%
    dplyr::filter(month == do_month) %>%
    dplyr::mutate('År' = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((.na_safe(distance, sum) / 1000) / my_day, 2),
      'Km, tot' = round(.na_safe(distance, sum) / 1000, 1),
      'Km, max' = round(.na_safe(distance, max) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(.na_safe(avgPaceMoving, mean)),
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
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Tibble with per-year statistics
#' @export
report_yearstop <- function(summaries, n = NULL, from = NULL, to = NULL,
                            sport = "running") {
  summaries <- .filter_input(summaries, from, to)
  summaries <- .filter_sport(summaries, sport)
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))

  result <- summaries %>%
    dplyr::mutate('År' = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((.na_safe(distance, sum) / 1000) / my_dayyear, 2),
      'Km, tot' = round(.na_safe(distance, sum) / 1000, 1),
      'Km, max' = round(.na_safe(distance, max) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(.na_safe(avgPaceMoving, mean)),
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
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Tibble with per-year statistics up to current day-of-year
#' @export
report_yearstatus <- function(summaries, n = NULL, from = NULL, to = NULL,
                              sport = "running") {
  summaries <- .filter_input(summaries, from, to)
  summaries <- .filter_sport(summaries, sport)
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))

  result <- summaries %>%
    dplyr::mutate(
      dayyear = as.numeric(format(sessionStart, "%j")),
      'År' = as.numeric(format(sessionStart, "%Y"))
    ) %>%
    dplyr::filter(dayyear <= my_dayyear) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((.na_safe(distance, sum) / 1000) / my_dayyear, 2),
      'Km, tot' = round(.na_safe(distance, sum) / 1000, 1),
      'Km, max' = round(.na_safe(distance, max) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(.na_safe(avgPaceMoving, mean)),
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
#' @param sport Sport bucket. See \code{\link{.filter_sport}}.
#' @return Tibble with per-year statistics for current month
#' @export
report_monthstatus <- function(summaries, n = NULL, from = NULL, to = NULL,
                               sport = "running") {
  summaries <- .filter_input(summaries, from, to)
  summaries <- .filter_sport(summaries, sport)
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))

  result <- summaries %>%
    dplyr::mutate(month = as.numeric(format(sessionStart, "%m"))) %>%
    dplyr::filter(month == my_month) %>%
    dplyr::mutate(
      day = as.numeric(format(sessionStart, "%d")),
      'År' = as.numeric(format(sessionStart, "%Y"))
    ) %>%
    dplyr::filter(day <= my_day) %>%
    dplyr::select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    dplyr::group_by(`År`) %>%
    dplyr::summarise(
      'Km/dag' = round((.na_safe(distance, sum) / 1000) / my_day, 2),
      'Km, tot' = round(.na_safe(distance, sum) / 1000, 1),
      'Km, max' = round(.na_safe(distance, max) / 1000, 1),
      'Tempo, medel' = dec_to_mmss(.na_safe(avgPaceMoving, mean)),
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
#
# closed_upper = TRUE  → use <= to (inclusive). Use for Date columns
#   (daily/monthly aggregates: ACWR, MS, PMC, readiness, HR-zones,
#   PI-zones, run-mix). Matches the KPI/graf-konventionen i
#   docs/dev/filter-consistency.md.
# closed_upper = FALSE → use <  to (half-open, default). Use for
#   POSIXct/sessionStart columns (session-level: EF, HRE, RHR-session,
#   decoupling).
.tail_or_daterange <- function(data, n, from, to, date_col,
                                closed_upper = FALSE) {
  if (!is.null(from) || !is.null(to)) {
    if (!is.null(from)) data <- dplyr::filter(data, .data[[date_col]] >= from)
    if (!is.null(to)) {
      if (closed_upper) {
        data <- dplyr::filter(data, .data[[date_col]] <= to)
      } else {
        data <- dplyr::filter(data, .data[[date_col]] < to)
      }
    }
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
#' @param sport Sport bucket (default \code{"running"}). Forwarded to the
#'   underlying \code{compute_*} call. See \code{\link{.filter_sport}}.
#' @return Tibble
#' @export
report_ef <- function(summaries, n = 28, from = NULL, to = NULL,
                      sport = "running") {
  compute_efficiency_factor(summaries, sport = sport) %>%
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
report_hre <- function(summaries, n = 28, from = NULL, to = NULL,
                       sport = "running") {
  compute_hre(summaries, sport = sport) %>%
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
#' @param mode Load mode; forwarded to \code{compute_acwr()}. NULL auto-
#'   resolves: km when sport-specific, TRIMP when whole-system.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}; threaded into \code{compute_acwr()}.
#' @return Tibble with one row per date. In km mode columns are
#'   \code{Datum}, \code{Km/dag}, \code{Km/vecka}, \code{ACWR}; in
#'   TRIMP mode the daily/weekly columns are renamed \code{TRIMP/dag} /
#'   \code{TRIMP/vecka} so callers (LLM via MCP, humans reading the
#'   table) see the right unit.
#' @export
report_acwr <- function(summaries, n = 28, from = NULL, to = NULL,
                        sport = "running", mode = NULL,
                        health_daily = NULL) {
  acwr <- compute_acwr(summaries, sport = sport, mode = mode,
                       health_daily = health_daily)
  resolved_mode <- attr(acwr, "mode") %||% "km"
  if (resolved_mode == "trimp") {
    acwr %>%
      dplyr::mutate(
        Datum         = date,
        `TRIMP/dag`   = round(daily_load, 1),
        `TRIMP/vecka` = round(weekly_load, 1),
        ACWR          = round(acwr, 2)
      ) %>%
      dplyr::select(Datum, `TRIMP/dag`, `TRIMP/vecka`, ACWR) %>%
      .tail_or_daterange(n, from, to, "Datum", closed_upper = TRUE)
  } else {
    acwr %>%
      dplyr::mutate(
        Datum      = date,
        `Km/dag`   = round(daily_km, 1),
        `Km/vecka` = round(weekly_km, 1),
        ACWR       = round(acwr, 2)
      ) %>%
      dplyr::select(Datum, `Km/dag`, `Km/vecka`, ACWR) %>%
      .tail_or_daterange(n, from, to, "Datum", closed_upper = TRUE)
  }
}

#' Training Monotony and Strain report — recent daily values
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_monotony <- function(summaries, n = 28, from = NULL, to = NULL,
                            sport = "running") {
  compute_monotony_strain(summaries, sport = sport) %>%
    dplyr::mutate(
      Datum = date,
      `Km/dag` = round(daily_km, 1),
      `Km/vecka` = round(weekly_km, 1),
      Monotoni = round(monotony, 2),
      Belastning = round(strain, 1)
    ) %>%
    dplyr::select(Datum, `Km/dag`, `Km/vecka`, Monotoni, Belastning) %>%
    .tail_or_daterange(n, from, to, "Datum", closed_upper = TRUE)
}

#' Performance Management Chart report — recent daily values
#' @inheritParams report_ef
#' @param hr_max Numeric or NULL. HRmax override.
#' @param hr_rest Numeric or NULL. HRrest override.
#' @param sport Sport bucket (default \code{"all"} — PMC is a
#'   whole-system load metric). Pass \code{"running"} for a
#'   running-only PMC.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}; folds background-activity TRIMP into
#'   the PMC when \code{sport} is a whole-system bucket.
#' @return Tibble
#' @export
report_pmc <- function(summaries, n = 28, from = NULL, to = NULL,
                       hr_max = NULL, hr_rest = NULL,
                       sport = "all", health_daily = NULL) {
  compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest,
              sport = sport, health_daily = health_daily) %>%
    dplyr::mutate(
      Datum = date,
      TRIMP = round(daily_trimp, 1),
      CTL = round(ctl, 1),
      ATL = round(atl, 1),
      TSB = round(tsb, 1)
    ) %>%
    dplyr::select(Datum, TRIMP, CTL, ATL, TSB) %>%
    .tail_or_daterange(n, from, to, "Datum", closed_upper = TRUE)
}

#' Recovery Heart Rate report — recent runs with recovery HR
#' @inheritParams report_ef
#' @return Tibble
#' @export
report_recovery_hr <- function(summaries, n = 28, from = NULL, to = NULL,
                               sport = "running") {
  data <- compute_recovery_hr(summaries, sport = sport)
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
                            zone_data = NULL, sport = "running") {
  if (is.null(zone_data))
    zone_data <- compute_zone_distribution(summaries, sport = sport)

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
    .tail_or_daterange(n, from, to, "Datum", closed_upper = TRUE)
}

#' Aerobic Decoupling report — recent qualifying sessions
#'
#' Shows per-session decoupling percentage (pace/speed:HR drift between
#' first and second half) with 28-day rolling mean. Requires per-second
#' data from myruns. Generalises to cycling/walking via \code{sport=}.
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
                              decoupling_data = NULL,
                              sport = "running") {
  if (is.null(decoupling_data)) {
    decoupling_data <- compute_decoupling(summaries, myruns, sport = sport)
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
  has_wt <- "wrist_temp" %in% names(r)
  out <- r |>
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
    )
  cols <- c("Datum", "Beredskap", "Status", "Ln RMSSD", "HRV z",
            "Vilopuls", "VP avvik", "Sömn", "TRIMP", "TSB")
  if (has_wt) {
    out <- out |>
      dplyr::mutate(
        `Temp avvik` = round(wrist_temp_deviation, 2)
      )
    cols <- c(cols, "Temp avvik")
  }
  cols <- c(cols, "Kvalitet")
  out |>
    dplyr::select(dplyr::all_of(cols)) |>
    .tail_or_daterange(n, from, to, "Datum", closed_upper = TRUE)
}

#' Generic health metric time series
#'
#' Returns a simple date/value series for any metric in health_daily.
#'
#' @param health_daily Long-format tibble from \code{load_health_data()}.
#' @param metric Character metric name (e.g. "resting_heart_rate").
#' @param n Number of rows (default 30). Ignored when from/to given.
#' @param from Date or NULL. Start of display window (inclusive).
#' @param to Date or NULL. End of display window (exclusive).
#' @return Tibble with Datum, Värde columns, newest first.
#' @export
report_metric <- function(health_daily, metric, n = 30,
                           from = NULL, to = NULL) {
  df <- health_daily |>
    dplyr::filter(.data$metric == .env$metric) |>
    dplyr::transmute(
      Datum  = date,
      "V\u00e4rde" = round(value, 2)
    )

  if (nrow(df) == 0) {
    return(tibble::tibble(Datum = as.Date(character(0)),
                          "V\u00e4rde" = numeric(0)))
  }

  .tail_or_daterange(df, n, from, to, "Datum", closed_upper = TRUE)
}
