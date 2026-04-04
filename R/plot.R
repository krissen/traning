# Plot functions — each returns a ggplot2 object

#' Bar + line plot of monthly distance and pace
#' @param month_summaries_til_day Tibble from report_monthstatus()
#' @return ggplot2 object
#' @export
fetch.plot.monthly.dist <- function(month_summaries_til_day) {
  my_month <- format(Sys.time(), "%B")
  my_title <- stringr::str_glue(
    "Distans och tempo för löpande månad ({my_month})")

  month_summaries_til_day %>%
    ggplot2::ggplot(ggplot2::aes(x = as.integer(year))) +
    ggplot2::geom_col(
      ggplot2::aes(y = dist_avg, fill = "Dist., medel")) +
    ggplot2::geom_col(
      ggplot2::aes(y = d_avg_dy, fill = "Dist. per dag, medel.")) +
    ggplot2::geom_line(
      ggplot2::aes(y = pace_avg, colour = 'Tempo, medel')) +
    ggplot2::scale_colour_manual("",
      values = c("Tempo, medel" = "red")) +
    ggplot2::scale_fill_manual(" ",
      values = c("Dist., medel" = "darkblue",
                 "Dist. per dag, medel." = "lightblue")) +
    ggplot2::theme(legend.key = ggplot2::element_blank(),
                   legend.title = ggplot2::element_blank()) +
    ggplot2::ggtitle(my_title) +
    ggplot2::labs(x = "År", y = "Kilometer") -> p1
  return(p1)
}

#' Compute yearly mean pace statistics
#' @param summaries Data frame of all workout summaries
#' @return Tibble with year, totDuration, meanPace, minPace
#' @export
fetch.my.mean.pace <- function(summaries) {
  mean.pace <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(year = format(sessionStart, "%Y")) %>%
    dplyr::group_by(year) %>%
    dplyr::summarise(
      totDuration = sum(durationMoving),
      meanPace = mean(avgPaceMoving, na.rm = TRUE),
      minPace = min(avgPaceMoving, na.rm = TRUE),
      .groups = "keep")
  return(mean.pace)
}

#' Scatter + smooth plot of yearly total distance
#' @param summaries Data frame of all workout summaries
#' @return ggplot2 object
#' @export
fetch.plot.sum.dist <- function(summaries) {
  summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(year = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::group_by(year) %>%
    dplyr::summarise(
      dist_max = max(distance),
      dist_sum = sum(distance) / 1000,
      dist_avg = mean(distance, na.rm = TRUE) / 1000,
      .groups = "keep") %>%
    ggplot2::ggplot(ggplot2::aes(x = as.integer(year), y = dist_sum)) +
    ggplot2::geom_point() +
    ggplot2::geom_smooth(method = 'loess', formula = 'y ~ x') +
    ggplot2::ggtitle("Distans över år") +
    ggplot2::labs(x = "År", y = "Kilometer") -> plot.sum.dist
  return(plot.sum.dist)
}

#' Scatter + smooth plot of yearly mean pace
#' @param mean.pace Tibble from fetch.my.mean.pace()
#' @return ggplot2 object
#' @export
fetch.plot.mean.pace <- function(mean.pace) {
  mean.pace %>%
    ggplot2::ggplot(ggplot2::aes(x = as.integer(year), y = meanPace)) +
    ggplot2::geom_point() +
    ggplot2::geom_smooth(method = 'loess', formula = 'y ~ x') +
    ggplot2::ggtitle("Tempo över år") +
    ggplot2::labs(x = "År", y = "Medeltempo (min/km)") -> p1
  return(p1)
}

#' Scatter plot of Efficiency Factor (EF) over time with rolling 28-day trend
#'
#' Calls \code{compute_efficiency_factor()} internally.  Each run is shown as
#' a point; a loess smoother (blue) captures the local trend; the 28-day
#' rolling mean (red) reveals the longer fitness arc.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
fetch.plot.ef <- function(summaries) {
  ef_data <- compute_efficiency_factor(summaries)

  ef_data %>%
    ggplot2::ggplot(ggplot2::aes(x = sessionStart)) +
    ggplot2::geom_point(
      ggplot2::aes(y = ef),
      alpha = 0.4, size = 1.5, colour = "grey40"
    ) +
    ggplot2::geom_smooth(
      ggplot2::aes(y = ef),
      method = "loess", formula = "y ~ x",
      colour = "steelblue", se = FALSE, linewidth = 0.8
    ) +
    ggplot2::geom_line(
      ggplot2::aes(y = ef_rolling28),
      colour = "firebrick", linewidth = 0.9, na.rm = TRUE
    ) +
    ggplot2::ggtitle("Effektivitetsfaktor (EF) över tid") +
    ggplot2::labs(
      x = NULL,
      y = "Effektivitetsfaktor (m/min per bpm)"
    ) -> p
  return(p)
}

#' Line plot of Acute:Chronic Workload Ratio (ACWR) over time
#'
#' Calls \code{compute_acwr()} internally.  The ACWR line is coloured by
#' zone (green = sweet spot 0.8-1.3, yellow = caution 1.3-1.5, red = danger
#' > 1.5 or undertraining < 0.5).  Horizontal reference lines mark the zone
#' boundaries.  A bar panel below shows weekly km.  Defaults to the last 365
#' days to keep the chart readable over a long training history.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param days Integer.  Number of trailing days to show.  Default 365.
#' @return ggplot2 object
#' @export
fetch.plot.acwr <- function(summaries, days = 365) {
  acwr_data <- compute_acwr(summaries)

  cutoff <- max(acwr_data$date, na.rm = TRUE) - days

  acwr_window <- acwr_data %>%
    dplyr::filter(date > cutoff, !is.na(acwr))

  # Assign each observation to an ACWR zone for colouring
  acwr_window <- acwr_window %>%
    dplyr::mutate(
      zon = dplyr::case_when(
        acwr < 0.5             ~ "Underbelastning",
        acwr <= 1.3            ~ "Optimalt",
        acwr <= 1.5            ~ "Varning",
        TRUE                   ~ "Överbelastning"
      ),
      zon = factor(zon,
        levels = c("Underbelastning", "Optimalt", "Varning", "Överbelastning"))
    )

  # Build a long-format data frame suitable for facet_grid
  # Panel 1: acwr value
  # Panel 2: weekly_km as bars
  acwr_panel <- acwr_window %>%
    dplyr::select(date, acwr, zon) %>%
    dplyr::rename(value = acwr) %>%
    dplyr::mutate(panel = "ACWR")

  km_panel <- acwr_window %>%
    dplyr::select(date, weekly_km) %>%
    dplyr::rename(value = weekly_km) %>%
    dplyr::mutate(zon = NA_character_, panel = "Veckokilometer")

  # We need two separate layers, so we build the plot programmatically
  # rather than through facet_grid (zone colouring only applies to the
  # ACWR panel).  Use a shared x axis via a two-panel facet approach:
  # convert to a single data frame with a 'panel' grouping variable and
  # draw geoms conditionally.

  combined <- dplyr::bind_rows(
    acwr_panel %>% dplyr::mutate(zon = as.character(zon)),
    km_panel
  ) %>%
    dplyr::mutate(panel = factor(panel, levels = c("ACWR", "Veckokilometer")))

  zon_farger <- c(
    "Underbelastning" = "#e67e22",
    "Optimalt"        = "#27ae60",
    "Varning"         = "#f1c40f",
    "Överbelastning"  = "#e74c3c"
  )

  # Reference band and lines — drawn only inside the ACWR panel using
  # data arguments that subset to the right panel.
  ref_df <- data.frame(
    panel = factor("ACWR", levels = c("ACWR", "Veckokilometer"))
  )

  combined %>%
    ggplot2::ggplot(ggplot2::aes(x = date)) +
    # Sweet-spot band (ACWR 0.8-1.3)
    ggplot2::geom_rect(
      data = ref_df,
      ggplot2::aes(xmin = -Inf, xmax = Inf, ymin = 0.8, ymax = 1.3),
      fill = "#27ae60", alpha = 0.08, inherit.aes = FALSE
    ) +
    # Danger threshold line
    ggplot2::geom_hline(
      data = ref_df,
      ggplot2::aes(yintercept = 1.5),
      colour = "#e74c3c", linetype = "dashed", linewidth = 0.5
    ) +
    # ACWR line — coloured by zone (only ACWR panel has non-NA zon)
    ggplot2::geom_line(
      data = dplyr::filter(combined, panel == "ACWR"),
      ggplot2::aes(y = value, colour = zon, group = 1),
      linewidth = 0.7, na.rm = TRUE
    ) +
    # Weekly km bars (only Veckokilometer panel)
    ggplot2::geom_col(
      data = dplyr::filter(combined, panel == "Veckokilometer"),
      ggplot2::aes(y = value),
      fill = "steelblue", alpha = 0.7, width = 1
    ) +
    ggplot2::scale_colour_manual(
      name   = "Zon",
      values = zon_farger,
      na.value = "steelblue"
    ) +
    ggplot2::facet_grid(
      rows   = ggplot2::vars(panel),
      scales = "free_y",
      space  = "fixed"
    ) +
    ggplot2::ggtitle("Akut:kronisk belastningskvot") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text   = ggplot2::element_text(face = "bold"),
      legend.position = "bottom"
    ) -> p
  return(p)
}

#' Dual-panel plot of Training Monotony and Strain
#'
#' Calls \code{compute_monotony_strain()} internally.  Upper panel shows
#' weekly monotony with a threshold line at 2.0 (overtraining risk).  Lower
#' panel shows training strain.  Defaults to the last 365 days.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param days Integer.  Number of trailing days to show.  Default 365.
#' @return ggplot2 object
#' @export
fetch.plot.monotony <- function(summaries, days = 365) {
  ms_data <- compute_monotony_strain(summaries)

  cutoff <- max(ms_data$date, na.rm = TRUE) - days

  ms_window <- ms_data %>%
    dplyr::filter(date > cutoff)

  # Build long format for facet_grid — one panel per metric
  long <- ms_window %>%
    dplyr::select(date, monotony, strain) %>%
    tidyr::pivot_longer(
      cols      = c(monotony, strain),
      names_to  = "metrik",
      values_to = "value"
    ) %>%
    dplyr::mutate(
      metrik = dplyr::recode(metrik,
        monotony = "Monotoni",
        strain   = "Belastning"
      ),
      metrik = factor(metrik, levels = c("Monotoni", "Belastning"))
    )

  # Threshold reference — only shown in the Monotoni panel
  ref_df <- data.frame(
    metrik = factor("Monotoni", levels = c("Monotoni", "Belastning"))
  )

  long %>%
    ggplot2::ggplot(ggplot2::aes(x = date, y = value)) +
    # Overtraining threshold line for monotony
    ggplot2::geom_hline(
      data = ref_df,
      ggplot2::aes(yintercept = 2.0),
      colour = "#e74c3c", linetype = "dashed", linewidth = 0.6
    ) +
    ggplot2::geom_line(
      colour = "steelblue", linewidth = 0.7, na.rm = TRUE
    ) +
    ggplot2::facet_grid(
      rows   = ggplot2::vars(metrik),
      scales = "free_y",
      space  = "fixed"
    ) +
    ggplot2::ggtitle("Träningsmonotoni och belastning") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text = ggplot2::element_text(face = "bold")
    ) -> p
  return(p)
}
