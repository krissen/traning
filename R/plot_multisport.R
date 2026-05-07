# Multi-sport visualisations.
#
# Helpers and plot wrappers that present per-sport breakdowns rather
# than a single sport. Built on top of the post-refactor sport-aware
# data path (.filter_sport / .sport_label_sv).

# --- Sport-mix data (used by sport-mix bar + calendar) ---------------------

# Aggregate distance per (period, sport).  `period_fmt` is a strftime
# format string controlling the bucket — "%Y-%m" for months,
# "%G-W%V" for ISO weeks (note: ISO week-year %G, not calendar %Y),
# "%Y" for years, "%Y-%m-%d" for daily.  Returns a tibble with columns:
# period (chr), sport (chr), km (dbl).
# `min_km = 0` keeps zero-distance buckets (gym/strength) — useful for
# the calendar where we want every training day coloured.
.sport_mix_data <- function(summaries, period_fmt = "%Y-%m",
                             from = NULL, to = NULL,
                             sport = NULL,
                             min_km = 0.1) {
  if (is.null(summaries) || nrow(summaries) == 0) {
    return(tibble::tibble(period = character(0),
                          sport = character(0),
                          km = numeric(0)))
  }
  # Apply optional sport filter (NULL/all = no filter)
  filtered <- if (is.null(sport)) summaries else .filter_sport(summaries, sport)
  if (nrow(filtered) == 0) {
    return(tibble::tibble(period = character(0),
                          sport = character(0),
                          km = numeric(0)))
  }
  # Apply optional date range
  filtered <- filter_by_daterange(filtered,
                                   list(from = from, to = to))

  filtered %>%
    dplyr::filter(!is.na(sport),
                  !is.na(distance),
                  !is.na(sessionStart)) %>%
    dplyr::mutate(period = format(sessionStart, period_fmt),
                  km     = as.numeric(distance) / 1000) %>%
    dplyr::group_by(period, sport) %>%
    dplyr::summarise(km = sum(km, na.rm = TRUE), .groups = "drop") %>%
    dplyr::filter(km >= min_km) %>%
    dplyr::arrange(period, dplyr::desc(km))
}

# Apply the canonical Swedish display label so legends and tick texts
# match the daily readiness prose. NA-safe — rest-day rows in the
# calendar (sport=NA after left_join) pass through as NA so the legend
# treats them as a missing-sport category instead of crashing inside
# .sport_label_sv().
.relabel_sport <- function(x) {
  vapply(x, function(s) {
    if (is.null(s) || (length(s) == 1 && is.na(s))) return(NA_character_)
    .sport_label_sv(s)
  }, character(1))
}

#' Sport-mix bar chart — distance per period broken down by sport
#'
#' Stacked bar chart (one bar per period, segments coloured by sport).
#' Useful for spotting sport-rotation patterns, training-camp blocks,
#' and seasonal shifts (e.g. summer cycling weeks vs winter running).
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param period One of \code{"month"} (default), \code{"week"}, or
#'   \code{"year"}. Controls the bar resolution.
#' @param from Date or NULL. Inclusive lower bound on session start.
#' @param to Date or NULL. Exclusive upper bound.
#' @param sport NULL (default) for all sports, or a sport bucket string
#'   to restrict the population (rarely useful — the whole point is to
#'   see the mix).
#' @param min_km Numeric. Drop (period, sport) cells totalling less than
#'   this many km (default 0.1).
#' @return ggplot2 object.
#' @export
plot_sport_mix <- function(summaries, period = "month",
                           from = NULL, to = NULL,
                           sport = NULL, min_km = 0.1) {
  # ISO week number (%V) must be paired with ISO week-year (%G), not the
  # calendar year (%Y), or weeks straddling Jan 1 get bucketed under the
  # wrong year (e.g. 2026-01-01 falls in ISO year 2025).
  period_fmt <- switch(period,
                       month = "%Y-%m",
                       week  = "%G-W%V",
                       year  = "%Y",
                       stop("period must be one of: month, week, year"))
  data <- .sport_mix_data(summaries, period_fmt = period_fmt,
                          from = from, to = to, sport = sport,
                          min_km = min_km)

  if (nrow(data) == 0) {
    return(ggplot2::ggplot() +
           ggplot2::ggtitle("Sport-mix: ingen data i fönstret"))
  }

  data <- dplyr::mutate(data, sport_sv = .relabel_sport(sport))

  ggplot2::ggplot(data,
                  ggplot2::aes(x = period, y = km, fill = sport_sv)) +
    ggplot2::geom_col() +
    ggplot2::labs(
      x = switch(period, month = "År-mån", week = "ISO-vecka", year = "År"),
      y = "Kilometer",
      fill = "Sport",
      title = paste0("Sport-mix per ",
                     switch(period, month = "månad", week = "vecka",
                            year = "år"))
    ) +
    ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 45,
                                                        hjust = 1))
}

# --- Cross-sport CTL overlay -------------------------------------------------

#' CTL overlay across multiple sport buckets
#'
#' Draws each sport's CTL (chronic training load) on the same axes so
#' overall fitness can be compared across sports — e.g. running CTL
#' tanks during a cycling-heavy training block while overall load
#' (sport=all) stays steady.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param sports Character vector of sport buckets to overlay.
#'   Default = \code{c("running", "cycling", "walking", "all")}.
#' @param from Date or NULL.
#' @param to Date or NULL.
#' @return ggplot2 object.
#' @export
plot_sport_ctl_overlay <- function(summaries,
                                    sports = c("running", "cycling",
                                               "walking", "all"),
                                    from = NULL, to = NULL) {
  if (length(sports) == 0)
    stop("sports must contain at least one bucket")

  series_list <- lapply(sports, function(s) {
    pmc <- compute_pmc(summaries, sport = s)
    if (nrow(pmc) == 0) return(NULL)
    pmc <- dplyr::select(pmc, date, ctl)
    pmc$sport <- s
    pmc
  })
  series <- dplyr::bind_rows(series_list)

  if (nrow(series) == 0) {
    return(ggplot2::ggplot() +
           ggplot2::ggtitle("CTL-overlay: ingen TRIMP-data tillgänglig"))
  }

  if (!is.null(from)) series <- dplyr::filter(series, date >= as.Date(from))
  if (!is.null(to))   series <- dplyr::filter(series, date <  as.Date(to))

  # Plot-specific labelling: .sport_label_sv() turns "all" into the
  # generic "Aktivitet", which is ambiguous next to running/cycling
  # series in a CTL overlay. Force "Totalt" for the all-sport line so
  # the legend is unambiguous.
  series$sport_sv <- vapply(series$sport, function(s) {
    if (identical(s, "all") || identical(s, "any")) "Totalt"
    else .sport_label_sv(s)
  }, character(1))

  ggplot2::ggplot(series,
                  ggplot2::aes(x = date, y = ctl, colour = sport_sv)) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::labs(
      x = NULL,
      y = "CTL (TRIMP/dag, 42d EWMA)",
      colour = "Sport",
      title = "Kronisk belastning per sport"
    )
}

# --- Sport activity calendar -------------------------------------------------

#' Activity calendar — one cell per day, coloured by dominant sport
#'
#' GitHub-style heatmap where each cell is a day and the colour encodes
#' the sport that contributed the most distance that day. Useful for a
#' quick visual of training frequency, sport-rotation, and rest patterns.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param from Date or NULL. Default = 1 year before \code{to}.
#' @param to Date or NULL. Default = today.
#' @param sport NULL (default) for all sports, or a bucket string to
#'   restrict the calendar (e.g. \code{sport = "endurance"} hides
#'   strength/gym days).
#' @return ggplot2 object.
#' @export
plot_sport_calendar <- function(summaries, from = NULL, to = NULL,
                                 sport = NULL) {
  # `to` follows the same exclusive-upper-bound convention used by the
  # rest of the bridged R functions (see report_datesum, the MCP
  # `_build_args` already adds +1 day for absolute ISO dates so it
  # arrives here exclusive). When `to` is NULL we default to tomorrow
  # so today's sessions are included.
  to_excl    <- if (is.null(to)) (Sys.Date() + 1L) else as.Date(to)
  from_d     <- if (is.null(from)) (to_excl - 366L) else as.Date(from)
  display_to <- to_excl - 1L

  # min_km = 0 so gym/strength sessions (0 km but still training) get
  # coloured on the calendar. Distance-based sports still win the
  # "dominant" tie-break by km below.
  data <- .sport_mix_data(summaries, period_fmt = "%Y-%m-%d",
                          from = from_d, to = to_excl,
                          sport = sport, min_km = 0)
  if (nrow(data) == 0) {
    return(ggplot2::ggplot() +
           ggplot2::ggtitle("Aktivitetskalender: ingen data i fönstret"))
  }

  # Pick the dominant sport per day. Tie-break: distance first, then
  # alphabetical sport name so the chosen colour is deterministic on
  # mixed/zero-distance days (slice_max alone keeps input order, which
  # is implementation-defined).
  dominant <- data %>%
    dplyr::arrange(period, dplyr::desc(km), sport) %>%
    dplyr::group_by(period) %>%
    dplyr::slice_head(n = 1) %>%
    dplyr::ungroup() %>%
    dplyr::mutate(date = as.Date(period))

  # Build a complete day spine so rest days appear as gaps. seq.Date is
  # inclusive at both ends, so use `display_to` (= to_excl - 1).
  spine <- tibble::tibble(
    date = seq.Date(from_d, display_to, by = "day")
  )
  # Weekday axis: %u gives ISO weekday (1=Mon..7=Sun), independent of
  # LC_TIME. Map to fixed Swedish abbreviations so the plot reads the
  # same on any system.
  swedish_wdays <- c("mån", "tis", "ons", "tor", "fre", "lör", "sön")
  joined <- dplyr::left_join(spine, dominant, by = "date") %>%
    dplyr::mutate(
      sport_sv = ifelse(is.na(sport), NA_character_,
                        .relabel_sport(sport)),
      iso_week = as.integer(format(date, "%V")),
      iso_year = as.integer(format(date, "%G")),
      wday     = factor(swedish_wdays[as.integer(format(date, "%u"))],
                        levels = swedish_wdays)
    )

  # ggplot2 doesn't have a stable "year+isoweek" axis, so build a
  # synthetic week index that increases monotonically across years.
  joined <- joined %>%
    dplyr::arrange(date) %>%
    dplyr::mutate(
      year_week = paste0(iso_year, "-W",
                         formatC(iso_week, width = 2, flag = "0"))
    )

  ggplot2::ggplot(joined,
                  ggplot2::aes(x = year_week, y = wday, fill = sport_sv)) +
    ggplot2::geom_tile(colour = "white", linewidth = 0.2) +
    ggplot2::scale_y_discrete(limits = rev) +
    ggplot2::labs(
      x = NULL,
      y = NULL,
      fill = "Sport",
      title = paste0("Aktivitetskalender ", format(from_d, "%Y-%m-%d"),
                     " – ", format(display_to, "%Y-%m-%d"))
    ) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 90, hjust = 1, size = 7)
    )
}
