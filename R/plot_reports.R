# Plot variants for table-based reports

# Internal: thin a discrete x-axis (factor/character) to ~target labels.
# Works with `scale_x_discrete(breaks = .thin_discrete_breaks(N))`. ggplot
# passes the full set of levels in plot order; we keep an evenly-spaced
# sample plus the last level so the most recent period stays labelled.
.thin_discrete_breaks <- function(target = 12) {
  function(x) {
    if (length(x) <= target) return(x)
    idx <- unique(round(seq(1, length(x), length.out = target)))
    if (utils::tail(idx, 1) != length(x)) idx <- c(idx, length(x))
    x[idx]
  }
}

# Internal: pick year-axis breaks that won't crowd.
# Falls back to every year when the span is small; thins to every Nth year
# once the span exceeds `target` so labels stay readable on narrow plots.
.year_breaks <- function(target = 10) {
  function(x) {
    lo <- floor(min(x, na.rm = TRUE))
    hi <- ceiling(max(x, na.rm = TRUE))
    span <- hi - lo + 1L
    step <- max(1L, as.integer(ceiling(span / target)))
    breaks <- seq(lo, hi, by = step)
    # Ensure the most recent year is always labelled even when the span
    # is not divisible by step (otherwise the rightmost bar is unlabelled).
    if (utils::tail(breaks, 1) != hi) breaks <- c(breaks, hi)
    breaks
  }
}

# Internal helper: shared year-bar chart
# x = År (integer), y = Km, tot (numeric)
.plot_year_bars <- function(data, title, x_col = "År", y_col = "Km, tot",
                            fill = traning_palette$accent) {
  data %>%
    ggplot2::ggplot(
      ggplot2::aes(x = as.integer(.data[[x_col]]), y = .data[[y_col]])
    ) +
    ggplot2::geom_col(fill = fill) +
    ggplot2::scale_x_continuous(breaks = .year_breaks()) +
    ggplot2::ggtitle(title) +
    ggplot2::labs(x = "År", y = "Kilometer") +
    .theme_rotated_x()
}

#' Top 10 months by total distance — horizontal bar chart
#'
#' Calls \code{report_monthtop()} internally. Each month is shown as a
#' horizontal bar; bars are ordered by total distance and coloured by year.
#'
#' @param data A \code{traning_data} bundle or, via the legacy shim, a
#'   bare summaries data.frame.
#' @return ggplot2 object
#' @export
plot_monthtop <- function(data, from = NULL, to = NULL,
                          sport = "running") {
  td <- .as_traning_data(data)
  plot_data <- report_monthtop(td, from = from, to = to, sport = sport)

  plot_data <- plot_data %>%
    dplyr::mutate(
      `År-mån` = factor(`År-mån`, levels = `År-mån`),
      year      = substr(`År-mån`, 1, 4)
    )

  # Interpolate the brown sequence palette to span the actual number
  # of distinct years in the top-10 (typically 3–7, but flexible).
  # Named vector — pairs colour to year explicitly so the mapping is
  # robust even if the `year` column ever becomes a factor with
  # extra unused levels.
  year_levels <- sort(unique(plot_data$year))
  year_colours <- grDevices::colorRampPalette(traning_palette$sequence)(length(year_levels))
  names(year_colours) <- year_levels

  plot_data %>%
    ggplot2::ggplot(
      ggplot2::aes(
        x    = `År-mån`,
        y    = `Km, tot`,
        fill = year
      )
    ) +
    ggplot2::geom_col() +
    ggplot2::scale_fill_manual(values = year_colours) +
    ggplot2::coord_flip() +
    ggplot2::ggtitle("Topp 10 månader per distans") +
    ggplot2::labs(x = "", y = "Kilometer", fill = "År")
}

#' Individual runs for a given month — lollipop chart
#'
#' Calls \code{report_runs_year_month()} internally. Each run is shown as a
#' lollipop; point colour encodes pace (green = fast, red = slow).
#'
#' @param data A \code{traning_data} bundle or, via the legacy shim, a
#'   bare summaries data.frame.
#' @param from Start date passed to \code{report_runs_year_month()}. Used to
#'   derive the month/year for the chart title. Default: \code{NULL} (current
#'   month).
#' @param to End date passed to \code{report_runs_year_month()}. Default:
#'   \code{NULL}.
#' @return ggplot2 object
#' @export
plot_runs_month <- function(data, from = NULL, to = NULL,
                            sport = "running") {
  td <- .as_traning_data(data)
  plot_data <- report_runs_year_month(td, from = from, to = to,
                                 sport = sport)

  ref_date  <- if (!is.null(from)) as.Date(from) else Sys.Date()
  do_year   <- format(ref_date, "%Y")
  do_month  <- as.integer(format(ref_date, "%m"))
  title <- stringr::str_glue(
    "Löpturer {.swedish_months[do_month]} {do_year}"
  )

  plot_data %>%
    ggplot2::ggplot() +
    ggplot2::geom_segment(
      ggplot2::aes(x = Dag, xend = Dag, y = 0, yend = Km),
      colour = "grey60"
    ) +
    ggplot2::geom_point(
      ggplot2::aes(x = Dag, y = Km, colour = Pace),
      size = 3
    ) +
    ggplot2::scale_colour_gradient(
      low  = "darkgreen",
      high = "red",
      name = "Tempo (min/km)"
    ) +
    ggplot2::ggtitle(title) +
    ggplot2::labs(x = "Dag", y = "Kilometer") +
    .theme_rotated_x()
}

#' Current month compared across years — bar chart
#'
#' Calls \code{report_monthstatus()} internally. Each bar represents one
#' calendar year; height shows total km up to the current day-of-month.
#'
#' @param data A \code{traning_data} bundle or, via the legacy shim, a
#'   bare summaries data.frame.
#' @return ggplot2 object
#' @export
plot_monthstatus <- function(data, from = NULL, to = NULL,
                             sport = "running") {
  td <- .as_traning_data(data)
  plot_data <- report_monthstatus(td, from = from, to = to, sport = sport)
  .plot_year_bars(plot_data, title = "Löpande månad jämfört med tidigare år")
}

#' Last month compared across years — bar chart
#'
#' Calls \code{report_monthlast()} internally. Each bar represents one
#' calendar year; height shows total km for last month.
#'
#' @param data A \code{traning_data} bundle or, via the legacy shim, a
#'   bare summaries data.frame.
#' @return ggplot2 object
#' @export
plot_monthlast <- function(data, from = NULL, to = NULL,
                           sport = "running") {
  td <- .as_traning_data(data)
  plot_data <- report_monthlast(td, from = from, to = to, sport = sport)

  my_month <- as.numeric(format(Sys.time(), "%m"))
  do_month <- if (my_month == 1) 12L else my_month - 1L
  month_name <- .swedish_months[do_month]

  title <- stringr::str_glue("Jämförelse {month_name} över åren")
  .plot_year_bars(plot_data, title = title)
}

#' Full-year totals compared across years — bar chart
#'
#' Calls \code{report_yearstop()} internally. Each bar represents one
#' calendar year; height shows total km for the full year.
#'
#' @param data A \code{traning_data} bundle or, via the legacy shim, a
#'   bare summaries data.frame.
#' @return ggplot2 object
#' @export
plot_yearstop <- function(data, from = NULL, to = NULL,
                          sport = "running") {
  td <- .as_traning_data(data)
  plot_data <- report_yearstop(td, from = from, to = to, sport = sport)
  .plot_year_bars(plot_data, title = "Årssammanställning (hela år)")
}

#' Distance per period for a date range — bar chart
#'
#' Aggregates distance for the selected \code{sport} bucket over the given
#' date range. The time resolution is chosen automatically:
#' \itemize{
#'   \item < 60 days  → daily bars
#'   \item < 18 months → weekly bars (\code{"\%Y-W\%V"})
#'   \item otherwise  → monthly bars (\code{"\%Y-\%m"})
#' }
#'
#' @param data A \code{traning_data} bundle or, via the legacy shim, a
#'   bare summaries data.frame.
#' @param do_datesum_from Start date (Date or character \code{"YYYY-MM-DD"}).
#' @param do_datesum_to End date (Date or character \code{"YYYY-MM-DD"}).
#' @param sport Sport bucket (default \code{"running"}).
#' @return ggplot2 object
#' @export
plot_datesum <- function(data, do_datesum_from, do_datesum_to,
                         sport = "running") {
  td <- .as_traning_data(data)
  summaries <- td@summaries
  from <- as.Date(do_datesum_from)
  to   <- as.Date(do_datesum_to)

  span_days   <- as.numeric(to - from)
  span_months <- span_days / 30.44

  period_fmt <- if (span_days < 60) {
    "%Y-%m-%d"
  } else if (span_months < 18) {
    "%Y-W%V"
  } else {
    "%Y-%m"
  }

  x_label <- if (span_days < 60) {
    "Datum"
  } else if (span_months < 18) {
    "Vecka"
  } else {
    "Månad"
  }

  plot_data <- .filter_sport(summaries, sport) %>%
    dplyr::filter(
      sessionStart >= from,
      sessionStart <  to
    ) %>%
    dplyr::mutate(period = format(sessionStart, period_fmt)) %>%
    dplyr::group_by(period) %>%
    dplyr::summarise(
      km = sum(distance, na.rm = TRUE) / 1000,
      .groups = "drop"
    )

  title <- stringr::str_glue("Distans {do_datesum_from} \u2014 {do_datesum_to}")

  plot_data %>%
    ggplot2::ggplot(ggplot2::aes(x = period, y = km)) +
    ggplot2::geom_col(fill = traning_palette$accent) +
    ggplot2::scale_x_discrete(breaks = .thin_discrete_breaks(15)) +
    ggplot2::ggtitle(title) +
    ggplot2::labs(x = x_label, y = "Kilometer") +
    .theme_rotated_x()
}
