# Plot variants for table-based reports

# Internal helper: shared year-bar chart
# x = År (integer), y = Km, tot (numeric)
.plot_year_bars <- function(data, title, x_col = "År", y_col = "Km, tot") {
  data %>%
    ggplot2::ggplot(
      ggplot2::aes(x = as.integer(.data[[x_col]]), y = .data[[y_col]])
    ) +
    ggplot2::geom_col(fill = "steelblue") +
    ggplot2::scale_x_continuous(breaks = function(x) seq(floor(min(x)), ceiling(max(x)), by = 1)) +
    ggplot2::ggtitle(title) +
    ggplot2::labs(x = "År", y = "Kilometer")
}

#' Top 10 months by total distance — horizontal bar chart
#'
#' Calls \code{report_monthtop()} internally. Each month is shown as a
#' horizontal bar; bars are ordered by total distance and coloured by year.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
plot_monthtop <- function(summaries) {
  data <- report_monthtop(summaries)

  data %>%
    dplyr::mutate(
      `År-mån` = factor(`År-mån`, levels = `År-mån`),
      year      = substr(`År-mån`, 1, 4)
    ) %>%
    ggplot2::ggplot(
      ggplot2::aes(
        x    = `År-mån`,
        y    = `Km, tot`,
        fill = year
      )
    ) +
    ggplot2::geom_col() +
    ggplot2::coord_flip() +
    ggplot2::ggtitle("Topp 10 månader per distans") +
    ggplot2::labs(x = "", y = "Kilometer", fill = "År")
}

#' Individual runs for a given month — lollipop chart
#'
#' Calls \code{report_runs_year_month()} internally. Each run is shown as a
#' lollipop; point colour encodes pace (green = fast, red = slow).
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param do_year Year as string. Default: current year.
#' @param do_month Month as string (zero-padded). Default: current month.
#' @return ggplot2 object
#' @export
plot_runs_month <- function(summaries,
                            do_year  = format(Sys.time(), "%Y"),
                            do_month = format(Sys.time(), "%m")) {
  data <- report_runs_year_month(summaries, do_year, do_month)

  title <- stringr::str_glue(
    "Löpturer {month.name[as.integer(do_month)]} {do_year}"
  )

  data %>%
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
    ggplot2::labs(x = "Dag", y = "Kilometer")
}

#' Current month compared across years — bar chart
#'
#' Calls \code{report_monthstatus()} internally. Each bar represents one
#' calendar year; height shows total km up to the current day-of-month.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
plot_monthstatus <- function(summaries) {
  data <- report_monthstatus(summaries)
  .plot_year_bars(data, title = "Löpande månad jämfört med tidigare år")
}

#' Last month compared across years — bar chart
#'
#' Calls \code{report_monthlast()} internally. Each bar represents one
#' calendar year; height shows total km for last month.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
plot_monthlast <- function(summaries) {
  data <- report_monthlast(summaries)

  my_month <- as.numeric(format(Sys.time(), "%m"))
  do_month <- if (my_month == 1) 12L else my_month - 1L
  month_name <- month.name[do_month]

  title <- stringr::str_glue("Jämförelse {month_name} över åren")
  .plot_year_bars(data, title = title)
}

#' Year-to-date compared across years — bar chart
#'
#' Calls \code{report_yearstatus()} internally. Each bar represents one
#' calendar year; height shows total km up to the current day-of-year for
#' fair cross-year comparison.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
plot_yearstatus <- function(summaries) {
  data <- report_yearstatus(summaries)
  .plot_year_bars(data, title = "Årssammanställning (t.o.m. idag)")
}

#' Full-year totals compared across years — bar chart
#'
#' Calls \code{report_yearstop()} internally. Each bar represents one
#' calendar year; height shows total km for the full year.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
plot_yearstop <- function(summaries) {
  data <- report_yearstop(summaries)
  .plot_year_bars(data, title = "Årssammanställning (hela år)")
}

#' Distance per period for a date range — bar chart
#'
#' Aggregates running distance from \code{summaries} over the given date
#' range. The time resolution is chosen automatically:
#' \itemize{
#'   \item < 60 days  → daily bars
#'   \item < 18 months → weekly bars (\code{"\%Y-W\%V"})
#'   \item otherwise  → monthly bars (\code{"\%Y-\%m"})
#' }
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param do_datesum_from Start date (Date or character \code{"YYYY-MM-DD"}).
#' @param do_datesum_to End date (Date or character \code{"YYYY-MM-DD"}).
#' @return ggplot2 object
#' @export
plot_datesum <- function(summaries, do_datesum_from, do_datesum_to) {
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

  data <- summaries %>%
    dplyr::filter(
      stringr::str_detect(sport, "running"),
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

  data %>%
    ggplot2::ggplot(ggplot2::aes(x = period, y = km)) +
    ggplot2::geom_col(fill = "steelblue") +
    ggplot2::ggtitle(title) +
    ggplot2::labs(x = x_label, y = "Kilometer") +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1)
    )
}
