# Multi-sport visualisations.
#
# Helpers and plot wrappers that present per-sport breakdowns rather
# than a single sport. Built on top of the post-refactor sport-aware
# data path (.filter_sport / .sport_label_sv).

# --- Sport-mix data (used by sport-mix bar + calendar) ---------------------

# Aggregate distance per (period, sport).  `period_fmt` is a strftime
# format string controlling the bucket — "%Y-%m" for months, "%Y-W%V"
# for ISO weeks, "%Y" for years, "%Y-%m-%d" for daily.  Returns a tibble
# with columns: period (chr), sport (chr), km (dbl).
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
# match the daily readiness prose.
.relabel_sport <- function(x) {
  vapply(x, .sport_label_sv, character(1))
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
  period_fmt <- switch(period,
                       month = "%Y-%m",
                       week  = "%Y-W%V",
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

  series$sport_sv <- .relabel_sport(series$sport)

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
  to_d   <- if (is.null(to)) Sys.Date() else as.Date(to)
  from_d <- if (is.null(from)) (to_d - 365L) else as.Date(from)

  data <- .sport_mix_data(summaries, period_fmt = "%Y-%m-%d",
                          from = from_d, to = to_d,
                          sport = sport, min_km = 0.1)
  if (nrow(data) == 0) {
    return(ggplot2::ggplot() +
           ggplot2::ggtitle("Aktivitetskalender: ingen data i fönstret"))
  }

  # Pick the dominant sport per day
  dominant <- data %>%
    dplyr::group_by(period) %>%
    dplyr::slice_max(km, n = 1, with_ties = FALSE) %>%
    dplyr::ungroup() %>%
    dplyr::mutate(date = as.Date(period))

  # Build a complete day spine so rest days appear as gaps
  spine <- tibble::tibble(
    date = seq.Date(from_d, to_d, by = "day")
  )
  joined <- dplyr::left_join(spine, dominant, by = "date") %>%
    dplyr::mutate(
      sport_sv = ifelse(is.na(sport), NA_character_,
                        .relabel_sport(sport)),
      iso_week = as.integer(format(date, "%V")),
      iso_year = as.integer(format(date, "%G")),
      wday     = factor(format(date, "%a"),
                        levels = c("mån", "tis", "ons", "tor", "fre",
                                   "lör", "sön"))
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
                     " – ", format(to_d, "%Y-%m-%d"))
    ) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 90, hjust = 1, size = 7)
    )
}
