# Plot functions — each returns a ggplot2 object

# --- Adaptive granularity helpers --------------------------------------------

# Compute span in days from from/to, with a fallback default
.compute_span_days <- function(from, to, fallback_days = 365) {
  if (!is.null(from) && !is.null(to)) {
    as.numeric(as.Date(to) - as.Date(from))
  } else {
    fallback_days
  }
}

# Return a scale_x_date() layer with appropriate breaks/labels for the span
.adaptive_date_scale <- function(span_days) {
  if (span_days <= 14) {
    ggplot2::scale_x_date(date_labels = "%d %b", date_breaks = "1 day")
  } else if (span_days <= 60) {
    ggplot2::scale_x_date(date_labels = "%d %b", date_breaks = "1 week")
  } else if (span_days <= 365) {
    ggplot2::scale_x_date(date_labels = "%b %Y", date_breaks = "1 month")
  } else if (span_days <= 365 * 3) {
    ggplot2::scale_x_date(date_labels = "%b %Y", date_breaks = "3 months")
  } else {
    ggplot2::scale_x_date(date_labels = "%Y", date_breaks = "1 year")
  }
}

# Same as above but for POSIXct x-axis (sessionStart columns)
.adaptive_datetime_scale <- function(span_days) {
  if (span_days <= 14) {
    ggplot2::scale_x_datetime(date_labels = "%d %b", date_breaks = "1 day")
  } else if (span_days <= 60) {
    ggplot2::scale_x_datetime(date_labels = "%d %b", date_breaks = "1 week")
  } else if (span_days <= 365) {
    ggplot2::scale_x_datetime(date_labels = "%b %Y", date_breaks = "1 month")
  } else if (span_days <= 365 * 3) {
    ggplot2::scale_x_datetime(date_labels = "%b %Y", date_breaks = "3 months")
  } else {
    ggplot2::scale_x_datetime(date_labels = "%Y", date_breaks = "1 year")
  }
}

# Filter a data frame by from/to on a date-like column
.filter_date_range <- function(data, date_col, from, to) {
  if (!is.null(from)) {
    data <- data[as.Date(data[[date_col]]) >= as.Date(from), , drop = FALSE]
  }
  if (!is.null(to)) {
    data <- data[as.Date(data[[date_col]]) < as.Date(to), , drop = FALSE]
  }
  data
}

# -------------------------------------------------------------------------

#' Bar + line plot of monthly distance and pace
#' @param month_summaries_til_day Tibble from report_monthstatus()
#' @return ggplot2 object
#' @export
fetch.plot.monthly.dist <- function(month_summaries_til_day) {
  my_month <- .swedish_months[as.integer(format(Sys.time(), "%m"))]
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

#' Scatter + smooth plot of yearly total distance
#' @param summaries Data frame of all workout summaries
#' @param sport Sport bucket (default \code{"running"}).
#' @return ggplot2 object
#' @export
fetch.plot.sum.dist <- function(summaries, sport = "running") {
  .filter_sport(summaries, sport) %>%
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

#' Dual-panel plot of Efficiency Factor (EF) over time
#'
#' Upper panel: EF scatter + loess smoother + 28-day rolling mean.
#' Lower panel: weekly km bars providing volume context (Votyakov 2025).
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
fetch.plot.ef <- function(summaries, from = NULL, to = NULL,
                          sport = "running") {
  ef_data <- compute_efficiency_factor(summaries, sport = sport)

  # Filter to date range
  ef_data <- .filter_date_range(ef_data, "sessionStart", from, to)
  if (nrow(ef_data) == 0) {
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen EF-data i intervallet"))
  }

  span <- .compute_span_days(from, to)
  show_smooth <- nrow(ef_data) >= 8 && span > 60
  show_rolling <- span > 35

  # Weekly km for volume panel
  acwr_data <- compute_acwr(summaries, sport = sport) %>%
    dplyr::filter(
      date >= min(ef_data$sessionStart),
      date <= max(ef_data$sessionStart)
    )

  # EF panel data — only include rolling if we'll show it
  ef_cols <- if (show_rolling) c("ef", "ef_rolling28") else "ef"
  ef_panel <- ef_data %>%
    dplyr::select(sessionStart, dplyr::all_of(ef_cols)) %>%
    tidyr::pivot_longer(
      cols = dplyr::all_of(ef_cols),
      names_to = "metrik", values_to = "value"
    ) %>%
    dplyr::mutate(panel = factor("EF", levels = c("EF", "Veckokilometer")))

  # Volume panel data — use weekly_km
  km_panel <- acwr_data %>%
    dplyr::select(date, weekly_km) %>%
    dplyr::rename(sessionStart = date) %>%
    dplyr::mutate(
      metrik = "weekly_km",
      value = weekly_km,
      panel = factor("Veckokilometer", levels = c("EF", "Veckokilometer"))
    ) %>%
    dplyr::select(sessionStart, metrik, value, panel)

  combined <- dplyr::bind_rows(ef_panel, km_panel)

  # Adapt point size for short spans
  pt_size <- if (span <= 30) 3 else 1.5
  pt_alpha <- if (span <= 30) 0.7 else 0.4

  p <- combined %>%
    ggplot2::ggplot(ggplot2::aes(x = sessionStart)) +
    # EF points
    ggplot2::geom_point(
      data = dplyr::filter(combined, metrik == "ef"),
      ggplot2::aes(y = value),
      alpha = pt_alpha, size = pt_size, colour = "grey40"
    )

  if (show_smooth) {
    p <- p + ggplot2::geom_smooth(
      data = dplyr::filter(combined, metrik == "ef"),
      ggplot2::aes(y = value),
      method = "loess", formula = "y ~ x",
      colour = "steelblue", se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      data = dplyr::filter(combined, metrik == "ef_rolling28"),
      ggplot2::aes(y = value),
      colour = "firebrick", linewidth = 0.9, na.rm = TRUE
    )
  }

  p <- p +
    # Weekly km bars
    ggplot2::geom_col(
      data = dplyr::filter(combined, metrik == "weekly_km"),
      ggplot2::aes(y = value),
      fill = "steelblue", alpha = 0.7, width = 1
    ) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(panel),
      scales = "free_y",
      space = "fixed"
    ) +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Effektivitetsfaktor (EF) över tid") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text = ggplot2::element_text(face = "bold"),
      axis.text.x = ggplot2::element_text(
        angle = if (span <= 60) 45 else 0, hjust = if (span <= 60) 1 else 0.5)
    )
  return(p)
}

#' Scatter plot of Heart Rate Efficiency (HRE) over time
#'
#' Calls \code{compute_hre()} internally.  Each run is shown as a point;
#' the 28-day rolling mean reveals the fitness trend.  Votyakov (2025)
#' thresholds are shown as horizontal bands: <700 bpkm well-fitted,
#' 700-750 fitted, >800 poorly-fitted.  Lower HRE = better fitness.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return ggplot2 object
#' @export
fetch.plot.hre <- function(summaries, from = NULL, to = NULL,
                           sport = "running") {
  hre_data <- compute_hre(summaries, sport = sport)

  # Filter to date range
  hre_data <- .filter_date_range(hre_data, "sessionStart", from, to)
  if (nrow(hre_data) == 0) {
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen HRE-data i intervallet"))
  }

  span <- .compute_span_days(from, to)
  show_smooth <- nrow(hre_data) >= 8 && span > 60
  show_rolling <- span > 35
  pt_size <- if (span <= 30) 3 else 1.5
  pt_alpha <- if (span <= 30) 0.7 else 0.4

  p <- hre_data %>%
    ggplot2::ggplot(ggplot2::aes(x = sessionStart)) +
    # Votyakov threshold bands
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = -Inf, ymax = 700,
      fill = "#27ae60", alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 700, ymax = 750,
      fill = "#f1c40f", alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 800, ymax = Inf,
      fill = "#e74c3c", alpha = 0.06
    ) +
    ggplot2::geom_hline(yintercept = c(700, 750, 800),
      colour = "grey70", linetype = "dotted", linewidth = 0.4
    ) +
    ggplot2::geom_point(
      ggplot2::aes(y = hre),
      alpha = pt_alpha, size = pt_size, colour = "grey40"
    )

  if (show_smooth) {
    p <- p + ggplot2::geom_smooth(
      ggplot2::aes(y = hre),
      method = "loess", formula = "y ~ x",
      colour = "steelblue", se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      ggplot2::aes(y = hre_rolling28),
      colour = "firebrick", linewidth = 0.9, na.rm = TRUE
    )
  }

  p <- p +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Hjärtslagskostnad (HRE) över tid") +
    ggplot2::labs(
      x = NULL,
      y = "Hjärtslagskostnad (slag/km)"
    ) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        angle = if (span <= 60) 45 else 0, hjust = if (span <= 60) 1 else 0.5)
    )
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
fetch.plot.acwr <- function(summaries, days = 365, from = NULL, to = NULL,
                            sport = "running") {
  acwr_data <- compute_acwr(summaries, sport = sport)

  # Date range overrides the days parameter
  if (!is.null(from)) {
    cutoff <- as.Date(from)
  } else {
    cutoff <- max(acwr_data$date, na.rm = TRUE) - days
  }

  acwr_window <- acwr_data %>%
    dplyr::filter(date > cutoff, !is.na(acwr))

  if (!is.null(to)) {
    acwr_window <- acwr_window %>% dplyr::filter(date < as.Date(to))
  }

  # Assign each observation to an ACWR zone for colouring
  # Hulin (2016): sweet spot 0.8-1.3; below 0.8 = underloading
  acwr_window <- acwr_window %>%
    dplyr::mutate(
      zon = dplyr::case_when(
        acwr < 0.8             ~ "Underbelastning",
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
    # Uncoupled ACWR — dashed grey line for comparison
    # (Impellizzeri 2020: coupled ACWR systematically dampens spikes)
    ggplot2::geom_line(
      data = acwr_window %>%
        dplyr::filter(!is.na(acwr_uncoupled)) %>%
        dplyr::mutate(panel = factor("ACWR", levels = c("ACWR", "Veckokilometer"))),
      ggplot2::aes(x = date, y = acwr_uncoupled),
      colour = "grey60", linewidth = 0.5, linetype = "dashed",
      na.rm = TRUE, inherit.aes = FALSE
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
    .adaptive_date_scale(.compute_span_days(from, to)) +
    ggplot2::ggtitle("Akut:kronisk belastningskvot") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text   = ggplot2::element_text(face = "bold"),
      legend.position = "bottom",
      axis.text.x = ggplot2::element_text(
        angle = if (.compute_span_days(from, to) <= 60) 45 else 0,
        hjust = if (.compute_span_days(from, to) <= 60) 1 else 0.5)
    ) -> p

  # Show individual data points at short spans
  span <- .compute_span_days(from, to)
  if (span <= 60) {
    p <- p + ggplot2::geom_point(
      data = dplyr::filter(combined, panel == "ACWR"),
      ggplot2::aes(x = date, y = value),
      size = 2, alpha = 0.7, colour = "grey30"
    )
  }
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
fetch.plot.monotony <- function(summaries, days = 365, from = NULL, to = NULL,
                                sport = "running") {
  ms_data <- compute_monotony_strain(summaries, sport = sport)

  if (!is.null(from)) {
    cutoff <- as.Date(from)
  } else {
    cutoff <- max(ms_data$date, na.rm = TRUE) - days
  }

  ms_window <- ms_data %>%
    dplyr::filter(date > cutoff)

  if (!is.null(to)) {
    ms_window <- ms_window %>% dplyr::filter(date < as.Date(to))
  }

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

  span <- .compute_span_days(from, to)

  p <- long %>%
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
    .adaptive_date_scale(span) +
    ggplot2::ggtitle("Träningsmonotoni och belastning") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text = ggplot2::element_text(face = "bold"),
      axis.text.x = ggplot2::element_text(
        angle = if (span <= 60) 45 else 0, hjust = if (span <= 60) 1 else 0.5)
    )

  # Show individual data points at short spans
  if (span <= 60) {
    p <- p + ggplot2::geom_point(size = 2, alpha = 0.7, colour = "steelblue")
  }

  return(p)
}

#' Performance Management Chart (PMC)
#'
#' Three-panel chart showing CTL (fitness), ATL (fatigue), and TSB (form)
#' derived from daily TRIMP via exponentially weighted moving averages.
#' TSB zones use coaching heuristics — not validated for recreational running.
#'
#' @param summaries Summaries data frame.
#' @param days Integer. Number of trailing days to show. Default 365.
#' @param hr_max Numeric or NULL. HRmax override.
#' @param hr_rest Numeric or NULL. HRrest override.
#' @param from Date or NULL. Start of display window (overrides days).
#' @param to Date or NULL. End of display window.
#' @param sport Sport bucket (default \code{"running"}). Forwarded to
#'   \code{compute_pmc()}.
#' @return ggplot2 object
#' @export
fetch.plot.pmc <- function(summaries, days = 365, hr_max = NULL, hr_rest = NULL,
                           from = NULL, to = NULL, sport = "running") {
  pmc_data <- compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest,
                          sport = sport)

  if (nrow(pmc_data) == 0) {
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen TRIMP-data tillgänglig"))
  }

  if (!is.null(from)) {
    cutoff <- as.Date(from)
  } else {
    cutoff <- max(pmc_data$date, na.rm = TRUE) - days
  }
  pmc_window <- pmc_data %>% dplyr::filter(date > cutoff)
  if (!is.null(to)) {
    pmc_window <- pmc_window %>% dplyr::filter(date < as.Date(to))
  }

  # Panel 1: CTL + ATL lines
  fitness_fatigue <- pmc_window %>%
    dplyr::select(date, ctl, atl) %>%
    tidyr::pivot_longer(cols = c(ctl, atl), names_to = "metrik", values_to = "value") %>%
    dplyr::mutate(
      metrik = dplyr::recode(metrik, ctl = "Fitness (CTL)", atl = "Trötthet (ATL)"),
      panel  = factor("Fitness / Trötthet",
                       levels = c("Fitness / Trötthet", "Form (TSB)", "Daglig TRIMP"))
    )

  # Panel 2: TSB with zone colouring
  tsb_panel <- pmc_window %>%
    dplyr::select(date, tsb) %>%
    dplyr::mutate(
      zon = dplyr::case_when(
        tsb > 15    ~ "Utvilad",
        tsb > 5     ~ "Tävlingsredo",
        tsb > -10   ~ "Produktiv",
        tsb > -20   ~ "Trött",
        TRUE        ~ "Överbelastad"
      ),
      zon = factor(zon, levels = c("Utvilad", "Tävlingsredo", "Produktiv",
                                    "Trött", "Överbelastad")),
      panel = factor("Form (TSB)",
                     levels = c("Fitness / Trötthet", "Form (TSB)", "Daglig TRIMP"))
    )

  # Panel 3: daily TRIMP bars
  trimp_panel <- pmc_window %>%
    dplyr::select(date, daily_trimp) %>%
    dplyr::mutate(
      panel = factor("Daglig TRIMP",
                     levels = c("Fitness / Trötthet", "Form (TSB)", "Daglig TRIMP"))
    )

  zon_farger <- c(
    "Utvilad"       = "#3498db",
    "Tävlingsredo"  = "#27ae60",
    "Produktiv"     = "#95a5a6",
    "Trött"         = "#f1c40f",
    "Överbelastad"  = "#e74c3c"
  )

  # Reference lines for TSB panel
  tsb_ref <- data.frame(
    panel = factor("Form (TSB)",
                   levels = c("Fitness / Trötthet", "Form (TSB)", "Daglig TRIMP"))
  )

  ggplot2::ggplot() +
    # Panel 1: CTL + ATL lines
    ggplot2::geom_line(
      data = fitness_fatigue,
      ggplot2::aes(x = date, y = value, colour = metrik),
      linewidth = 0.8, na.rm = TRUE
    ) +
    ggplot2::scale_colour_manual(
      name   = NULL,
      values = c("Fitness (CTL)" = "steelblue", "Trötthet (ATL)" = "#e74c3c")
    ) +
    # Panel 2: TSB coloured by zone
    ggplot2::geom_col(
      data = tsb_panel,
      ggplot2::aes(x = date, y = tsb, fill = zon),
      width = 1, na.rm = TRUE
    ) +
    ggplot2::scale_fill_manual(name = "TSB-zon", values = zon_farger) +
    # TSB zero line
    ggplot2::geom_hline(
      data = tsb_ref,
      ggplot2::aes(yintercept = 0),
      colour = "grey30", linewidth = 0.4
    ) +
    # Panel 3: daily TRIMP bars
    ggplot2::geom_col(
      data = trimp_panel,
      ggplot2::aes(x = date, y = daily_trimp),
      fill = "steelblue", alpha = 0.7, width = 1
    ) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(panel),
      scales = "free_y",
      space = "fixed"
    ) +
    .adaptive_date_scale(.compute_span_days(from, to)) +
    ggplot2::ggtitle("Performance Management Chart (PMC)") +
    ggplot2::labs(
      x = NULL, y = NULL,
      caption = "TSB-trösklar är coaching-heuristik, ej validerade för motionslöpning"
    ) +
    ggplot2::theme(
      strip.text      = ggplot2::element_text(face = "bold"),
      legend.position = "bottom",
      axis.text.x = ggplot2::element_text(
        angle = if (.compute_span_days(from, to) <= 60) 45 else 0,
        hjust = if (.compute_span_days(from, to) <= 60) 1 else 0.5)
    )
}

#' Scatter plot of Recovery Heart Rate over time (see above)
#' @inheritParams fetch.plot.pmc
#' @export
fetch.plot.recovery_hr <- function(summaries, from = NULL, to = NULL,
                                   sport = "running") {
  rhr_data <- compute_recovery_hr(summaries, sport = sport)

  if (nrow(rhr_data) == 0) {
    message("Ingen recovery HR-data tillgänglig.")
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen recovery HR-data"))
  }

  # Filter to date range
  rhr_data <- .filter_date_range(rhr_data, "sessionStart", from, to)
  if (nrow(rhr_data) == 0) {
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen recovery HR-data i intervallet"))
  }

  span <- .compute_span_days(from, to)
  show_smooth <- nrow(rhr_data) >= 8 && span > 60
  show_rolling <- span > 35
  pt_size <- if (span <= 30) 3 else 1.5
  pt_alpha <- if (span <= 30) 0.7 else 0.4

  has_avg_hr <- "avg_hr" %in% names(rhr_data) &&
    any(!is.na(rhr_data$avg_hr))

  p <- rhr_data %>%
    ggplot2::ggplot(ggplot2::aes(x = sessionStart)) +
    ggplot2::geom_point(
      ggplot2::aes(y = recovery_hr),
      alpha = pt_alpha, size = pt_size, colour = "grey40"
    )

  if (show_smooth) {
    p <- p + ggplot2::geom_smooth(
      ggplot2::aes(y = recovery_hr),
      method = "loess", formula = "y ~ x",
      colour = "steelblue", se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      ggplot2::aes(y = recovery_hr_rolling28),
      colour = "firebrick", linewidth = 0.9, na.rm = TRUE
    )
  }

  if (has_avg_hr && show_smooth) {
    # Scale avgHR onto recovery HR range for dual-axis display
    rhr_range <- range(rhr_data$recovery_hr, na.rm = TRUE)
    ahr_range <- range(rhr_data$avg_hr, na.rm = TRUE)
    scale_factor <- diff(rhr_range) / max(diff(ahr_range), 1)
    offset <- rhr_range[1] - ahr_range[1] * scale_factor

    p <- p +
      ggplot2::geom_smooth(
        ggplot2::aes(y = avg_hr * scale_factor + offset),
        method = "loess", formula = "y ~ x",
        colour = "darkorange", se = FALSE, linewidth = 0.7,
        linetype = "dashed", na.rm = TRUE
      ) +
      ggplot2::scale_y_continuous(
        name = "Recovery HR (bpm)",
        sec.axis = ggplot2::sec_axis(
          ~ (. - offset) / scale_factor,
          name = "Medel-HR (bpm)"
        )
      ) +
      ggplot2::theme(
        axis.title.y.right = ggplot2::element_text(colour = "darkorange"),
        axis.text.y.right  = ggplot2::element_text(colour = "darkorange")
      )
  }

  p <- p +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Recovery HR efter löpning") +
    ggplot2::labs(x = NULL) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        angle = if (span <= 60) 45 else 0, hjust = if (span <= 60) 1 else 0.5)
    )

  return(p)
}

#' Two-panel plot of Aerobic Decoupling over time
#'
#' Upper panel: per-run decoupling percentage (scatter + 28-day rolling mean)
#' with threshold bands (<3% green, 3-5% yellow, 5-8% orange, >8% red).
#' Lower panel: weekly km bars for volume context.
#'
#' @param decoupling_data Tibble from \code{compute_decoupling()} or
#'   \code{load_decoupling()}.  If NULL, computed from summaries + myruns.
#' @param summaries Summaries tibble (used for weekly km bars and as fallback
#'   if \code{decoupling_data} is NULL).
#' @param myruns Myruns list (only needed if \code{decoupling_data} is NULL).
#' @param from Date or character.  Optional left x-axis limit.
#' @param to Date or character.  Optional right x-axis limit.
#' @return ggplot2 object
#' @export
fetch.plot.decoupling <- function(summaries, myruns = NULL,
                                  from = NULL, to = NULL,
                                  decoupling_data = NULL,
                                  sport = "running") {
  if (is.null(decoupling_data)) {
    decoupling_data <- compute_decoupling(summaries, myruns, sport = sport)
  }

  if (nrow(decoupling_data) == 0) {
    message("Ingen decoupling-data tillg\u00e4nglig.")
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen decoupling-data"))
  }

  # Filter to date range
  decoupling_data <- .filter_date_range(decoupling_data, "sessionStart", from, to)
  if (nrow(decoupling_data) == 0) {
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen decoupling-data i intervallet"))
  }

  span <- .compute_span_days(from, to)
  show_smooth <- nrow(decoupling_data) >= 8 && span > 60
  show_rolling <- span > 35
  pt_size <- if (span <= 30) 3 else 1.5
  pt_alpha <- if (span <= 30) 0.7 else 0.4

  # Weekly km for volume panel — must follow the same sport as the
  # decoupling points so a cycling-decoupling chart isn't rendered
  # against running km totals.
  acwr_data <- compute_acwr(summaries, sport = sport) %>%
    dplyr::filter(
      date >= min(decoupling_data$sessionStart),
      date <= max(decoupling_data$sessionStart)
    )

  # Decoupling panel data — only include rolling if we'll show it
  dc_cols <- if (show_rolling) {
    c("decoupling_pct", "decoupling_rolling28")
  } else {
    "decoupling_pct"
  }
  dc_panel <- decoupling_data %>%
    dplyr::select(sessionStart, dplyr::all_of(dc_cols)) %>%
    tidyr::pivot_longer(
      cols = dplyr::all_of(dc_cols),
      names_to = "metrik", values_to = "value"
    ) %>%
    dplyr::mutate(
      panel = factor("Decoupling (%)",
                     levels = c("Decoupling (%)", "Veckokilometer"))
    )

  # Volume panel data
  km_panel <- acwr_data %>%
    dplyr::select(date, weekly_km) %>%
    dplyr::rename(sessionStart = date) %>%
    dplyr::mutate(
      metrik = "weekly_km",
      value = weekly_km,
      panel = factor("Veckokilometer",
                     levels = c("Decoupling (%)", "Veckokilometer"))
    ) %>%
    dplyr::select(sessionStart, metrik, value, panel)

  combined <- dplyr::bind_rows(dc_panel, km_panel)

  p <- combined %>%
    ggplot2::ggplot(ggplot2::aes(x = sessionStart)) +
    # Threshold bands (only visible in decoupling panel)
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = -Inf, ymax = 3,
      fill = "#27ae60", alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 3, ymax = 5,
      fill = "#f1c40f", alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 5, ymax = 8,
      fill = "#e67e22", alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 8, ymax = Inf,
      fill = "#e74c3c", alpha = 0.06
    ) +
    ggplot2::geom_hline(yintercept = c(3, 5, 8),
      colour = "grey70", linetype = "dotted", linewidth = 0.4
    ) +
    # Decoupling points
    ggplot2::geom_point(
      data = dplyr::filter(combined, metrik == "decoupling_pct"),
      ggplot2::aes(y = value),
      alpha = pt_alpha, size = pt_size, colour = "grey40"
    )

  if (show_smooth) {
    p <- p + ggplot2::geom_smooth(
      data = dplyr::filter(combined, metrik == "decoupling_pct"),
      ggplot2::aes(y = value),
      method = "loess", formula = "y ~ x",
      colour = "steelblue", se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      data = dplyr::filter(combined, metrik == "decoupling_rolling28"),
      ggplot2::aes(y = value),
      colour = "firebrick", linewidth = 0.9, na.rm = TRUE
    )
  }

  p <- p +
    # Weekly km bars
    ggplot2::geom_col(
      data = dplyr::filter(combined, metrik == "weekly_km"),
      ggplot2::aes(y = value),
      fill = "steelblue", alpha = 0.7, width = 1
    ) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(panel),
      scales = "free_y",
      space = "fixed"
    ) +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Aerob decoupling \u00f6ver tid") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text = ggplot2::element_text(face = "bold"),
      axis.text.x = ggplot2::element_text(
        angle = if (span <= 60) 45 else 0, hjust = if (span <= 60) 1 else 0.5)
    )

  return(p)
}

# =============================================================================
# Yearly characterization plots (L\u00f6pprofil tab)
# =============================================================================

# Shared filter+mutate pipeline used by all run-profile plots. Mirrors the
# iterate_round*.R sandbox: same outlier cuts, same minimum year, same
# derived columns.
#
# pace_filter = TRUE drops sessions outside running's typical pace band
# (2.5–10 min/km). For pace-centric plots (pace_year, ridges, tertile
# share, season_pace, distance_pace_era) this strips degenerate values
# and keeps the y/x-axis readable. Volume-centric plots (cumulative_km,
# heatmap_km, longest_runs_year) don't display pace and would otherwise
# silently drop cycling (pace ~1.5–3) and walking (pace >10) sessions —
# they pass pace_filter = FALSE.
.run_profile_runs <- function(summaries, sport = "running", year_min = 2005,
                               pace_filter = TRUE) {
  out <- .filter_sport(summaries, sport) %>%
    dplyr::mutate(
      date = as.Date(sessionStart),
      year = lubridate::year(sessionStart),
      woy  = lubridate::isoweek(sessionStart),
      month = lubridate::month(sessionStart),
      km   = distance / 1000,
      dur_min = as.numeric(durationMoving, units = "mins"),
      pace = avgPaceMoving
    ) %>%
    dplyr::filter(
      !is.na(km), km > 0.5,
      !is.na(dur_min), dur_min > 5,
      year >= year_min
    )
  if (pace_filter) {
    out <- dplyr::filter(out, !is.na(pace), pace > 2.5, pace < 10)
  }
  out
}

# Apply a from/to date filter on the derived `date` column. NULL => no-op.
.run_profile_filter_range <- function(runs, from, to) {
  if (!is.null(from)) runs <- dplyr::filter(runs, date >= as.Date(from))
  if (!is.null(to))   runs <- dplyr::filter(runs, date <  as.Date(to))
  runs
}

# Vector-input variant of .year_breaks() (which is a closure in plot_reports.R
# and not reusable on bare integer vectors).
.year_breaks_int <- function(years, target = 10) {
  yrs <- sort(unique(years))
  if (length(yrs) <= target) return(yrs)
  step <- ceiling(length(yrs) / target)
  yrs[seq(1, length(yrs), by = step)]
}

# Shared theme for run-profile plots.
.theme_run_profile <- function() {
  ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold"),
      plot.subtitle = ggplot2::element_text(colour = "grey40"),
      panel.grid.minor = ggplot2::element_blank(),
      strip.text = ggplot2::element_text(face = "bold")
    )
}

# Empty-state placeholder when filters strip the data to zero rows.
.run_profile_empty <- function(msg = "Ingen data i intervallet") {
  ggplot2::ggplot() + ggplot2::ggtitle(msg) + .theme_run_profile()
}

#' Tempo per \u00e5r: median + 25-75 % band + objektiva milstolpar
#'
#' En punkt per \u00e5r = \u00e5rets medianpace; ribbon = 25-75 %-percentil; gula
#' etiketter pekar ut sex objektiva milstolpar (snabbaste/l\u00e5ngsammaste
#' pass, l\u00e4ngsta pass, snabbast/l\u00e5ngsammast median\u00e5r, h\u00f6gsta volym-\u00e5r).
#'
#' @param summaries Data frame fr\u00e5n \code{my_dbs_load()}.
#' @param from,to Valfri datumavgr\u00e4nsning p\u00e5 pass-datum.
#' @param sport Sport-bucket (default \code{"running"}).
#' @return ggplot2-objekt.
#' @export
fetch.plot.pace_year <- function(summaries, from = NULL, to = NULL,
                                  sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  yearly <- runs %>% dplyr::group_by(year) %>%
    dplyr::summarise(
      median_pace = stats::median(pace),
      p25 = stats::quantile(pace, .25),
      p75 = stats::quantile(pace, .75),
      total_km = sum(km), .groups = "drop")

  fastest        <- runs %>% dplyr::slice_min(pace, n = 1, with_ties = FALSE)
  slowest        <- runs %>% dplyr::slice_max(pace, n = 1, with_ties = FALSE)
  longest_pass   <- runs %>% dplyr::slice_max(km,   n = 1, with_ties = FALSE)
  peak_year      <- yearly %>% dplyr::slice_min(median_pace, n = 1)
  worst_year     <- yearly %>% dplyr::slice_max(median_pace, n = 1)
  top_volume_year<- yearly %>% dplyr::slice_max(total_km,   n = 1)

  milestones <- dplyr::bind_rows(
    tibble::tibble(year = fastest$year, pace = fastest$pace,
      label = sprintf("Snabbaste pass\n%.2f (%d)", fastest$pace, fastest$year)),
    tibble::tibble(year = slowest$year, pace = slowest$pace,
      label = sprintf("L\u00e5ngsammaste pass\n%.2f (%d)", slowest$pace, slowest$year)),
    tibble::tibble(year = longest_pass$year,
      pace = yearly$median_pace[match(longest_pass$year, yearly$year)],
      label = sprintf("L\u00e4ngsta pass\n%.0f km (%d)", longest_pass$km, longest_pass$year)),
    tibble::tibble(year = peak_year$year, pace = peak_year$median_pace,
      label = sprintf("Snabbast median\u00e5r\n%.2f (%d)", peak_year$median_pace, peak_year$year)),
    tibble::tibble(year = worst_year$year, pace = worst_year$median_pace,
      label = sprintf("L\u00e5ngsammast median\u00e5r\n%.2f (%d)", worst_year$median_pace, worst_year$year)),
    tibble::tibble(year = top_volume_year$year,
      pace = top_volume_year$median_pace,
      label = sprintf("Mest km-\u00e5r\n%.0f km (%d)", top_volume_year$total_km, top_volume_year$year))
  )

  y_lo <- min(yearly$p25) - 0.2
  y_hi <- max(yearly$p75) + 0.2
  milestones <- milestones %>% dplyr::mutate(
    y_anchor = dplyr::case_when(
      pace < y_lo ~ y_lo, pace > y_hi ~ y_hi, TRUE ~ pace))

  yb <- .year_breaks_int(yearly$year)

  ggplot2::ggplot(yearly, ggplot2::aes(x = year, y = median_pace)) +
    ggplot2::geom_ribbon(ggplot2::aes(ymin = p25, ymax = p75),
                          fill = "#4682B4", alpha = 0.18) +
    ggplot2::geom_line(colour = "#4682B4", linewidth = 0.7) +
    ggplot2::geom_point(colour = "#4682B4", size = 1.6) +
    ggplot2::geom_point(data = milestones,
      ggplot2::aes(x = year, y = y_anchor),
      shape = 21, fill = "#FFE082", colour = "#7B5C00",
      size = 3.2, stroke = 0.8) +
    ggrepel::geom_label_repel(data = milestones,
      ggplot2::aes(x = year, y = y_anchor, label = label),
      size = 2.6, colour = "#5C4400", fill = "#FFFBEB",
      label.size = 0.4, min.segment.length = 0,
      box.padding = 0.5, force = 5, max.overlaps = Inf) +
    ggplot2::scale_x_continuous(breaks = yb) +
    ggplot2::scale_y_reverse() +
    ggplot2::coord_cartesian(ylim = c(y_lo, y_hi), clip = "off") +
    ggplot2::labs(title = "Tempo per \u00e5r",
                   subtitle = "Median + 25\u201375 %-band per \u00e5r. L\u00e4gre = snabbare.",
                   x = NULL, y = "Tempo (min/km)") +
    .theme_run_profile() +
    ggplot2::theme(plot.margin = ggplot2::margin(12, 12, 28, 12))
}

#' Tempo per \u00e5r som ridges, f\u00e4rgade efter \u00e5rsvolym
#'
#' Densitet av tempo per \u00e5r (ggridges). F\u00e4rgfyllning = \u00e5rets totala km
#' (m\u00f6rkare = mer). Bra f\u00f6r att se b\u00e5de f\u00f6rdelningsform och volym i samma
#' bild.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.pace_year_ridges <- function(summaries, from = NULL, to = NULL,
                                          sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  runs <- runs %>% dplyr::group_by(year) %>%
    dplyr::mutate(yr_total_km = sum(km)) %>% dplyr::ungroup()

  ggplot2::ggplot(runs, ggplot2::aes(x = pace, y = factor(year),
                                       fill = yr_total_km)) +
    ggridges::geom_density_ridges(scale = 1.8, alpha = 0.78,
                                    colour = "white", linewidth = 0.4) +
    ggplot2::scale_fill_viridis_c(option = "viridis", trans = "sqrt",
                                    direction = -1,
                                    name = "Total km / \u00e5r") +
    ggplot2::scale_x_reverse() +
    ggplot2::labs(title = "Tempo per \u00e5r (t\u00e4thet)",
                   subtitle = "F\u00e4rg = \u00e5rets totala km (m\u00f6rkare = mer).",
                   x = "Tempo (min/km)", y = NULL) +
    .theme_run_profile()
}

#' Tempo-f\u00f6rdelning per \u00e5r: andel km i lugnt / medel / snabbt
#'
#' 100 %-staplad areachart. Tertiler ber\u00e4knas p\u00e5 hela datasetets pace-
#' f\u00f6rdelning, s\u00e5 "snabbt" \u00e4r konsekvent definierat \u00f6ver alla \u00e5r.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.pace_tertile_share <- function(summaries, from = NULL, to = NULL,
                                            sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  pace_q <- stats::quantile(runs$pace, c(1/3, 2/3))
  palette_traffic <- c("Lugn" = "#5E9C7A",
                        "Medel" = "#E0B45A",
                        "Snabb" = "#C0392B")

  runs_int <- runs %>% dplyr::mutate(
    intensity = dplyr::case_when(
      pace <= pace_q[1] ~ "Snabb",
      pace <= pace_q[2] ~ "Medel",
      TRUE              ~ "Lugn")) %>%
    dplyr::mutate(intensity = factor(intensity,
                                      levels = c("Lugn", "Medel", "Snabb")))

  stream_km_norm <- runs_int %>% dplyr::group_by(year, intensity) %>%
    dplyr::summarise(km = sum(km), .groups = "drop")

  yb <- .year_breaks_int(stream_km_norm$year)

  ggplot2::ggplot(stream_km_norm,
                   ggplot2::aes(x = year, y = km, fill = intensity)) +
    ggplot2::geom_area(position = ggplot2::position_fill(reverse = TRUE),
                        alpha = 0.92) +
    ggplot2::scale_x_continuous(breaks = yb) +
    ggplot2::scale_y_continuous(labels = scales::percent) +
    ggplot2::scale_fill_manual(values = palette_traffic, name = NULL,
                                breaks = c("Snabb", "Medel", "Lugn")) +
    ggplot2::labs(title = "Tempo-f\u00f6rdelning per \u00e5r",
                   subtitle = "Andel av \u00e5rets km i lugnt / medel / snabbt tempo.",
                   x = NULL, y = "Andel km") +
    .theme_run_profile() +
    ggplot2::theme(legend.position = "bottom")
}

#' L\u00e4ngsta pass per \u00e5r (topp-5 staplat)
#'
#' Stapeln f\u00f6r varje \u00e5r staplar de fem l\u00e4ngsta passen. \u00d6versta segmentet =
#' \u00e5rets enskilt l\u00e4ngsta pass (km-siffran \u00e4r samma v\u00e4rde).
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.longest_runs_year <- function(summaries, from = NULL, to = NULL,
                                           sport = "running") {
  # Volume-centric — pace isn't shown, so don't drop non-running
  # sessions on running's pace band.
  runs <- .run_profile_runs(summaries, sport = sport, pace_filter = FALSE)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  top5 <- runs %>% dplyr::group_by(year) %>%
    dplyr::arrange(dplyr::desc(km)) %>%
    dplyr::mutate(rank = dplyr::row_number()) %>%
    dplyr::filter(rank <= 5) %>% dplyr::ungroup()

  segs5 <- top5 %>% dplyr::select(year, rank, km) %>%
    tidyr::pivot_wider(names_from = rank, values_from = km,
                        names_prefix = "k") %>%
    dplyr::mutate(dplyr::across(dplyr::starts_with("k"),
                                  ~ replace(., is.na(.), 0))) %>%
    dplyr::mutate(
      seg5 = pmin(k1, k2, k3, k4, k5),
      seg4 = pmax(k4, k5) - seg5,
      seg3 = pmax(k3, k4) - (seg5 + seg4),
      seg2 = pmax(k2, k3) - (seg5 + seg4 + seg3),
      seg1 = k1 - (seg5 + seg4 + seg3 + seg2)) %>%
    dplyr::select(year, seg1, seg2, seg3, seg4, seg5) %>%
    tidyr::pivot_longer(c(seg1, seg2, seg3, seg4, seg5),
                         names_to = "segment", values_to = "km") %>%
    dplyr::mutate(segment = factor(segment,
      levels = c("seg5", "seg4", "seg3", "seg2", "seg1"),
      labels = c("5:e l\u00e4ngsta", "4:e", "3:e", "2:a", "1:a l\u00e4ngsta")))

  top1_labels <- top5 %>% dplyr::filter(rank == 1) %>%
    dplyr::select(year, total = km)

  yb <- .year_breaks_int(segs5$year)

  ggplot2::ggplot(segs5, ggplot2::aes(x = year, y = km, fill = segment)) +
    ggplot2::geom_col(alpha = 0.92, width = 0.85,
                       position = ggplot2::position_stack(reverse = TRUE)) +
    ggplot2::geom_text(data = top1_labels,
      ggplot2::aes(x = year, y = total, label = round(total, 0)),
      inherit.aes = FALSE, vjust = -0.4, size = 2.6, colour = "grey25") +
    ggplot2::scale_x_continuous(breaks = yb) +
    ggplot2::scale_fill_manual(
      values = c("5:e l\u00e4ngsta" = "#1F4D33",
                  "4:e"           = "#3F7D5C",
                  "3:e"           = "#6FA887",
                  "2:a"           = "#9CC1A8",
                  "1:a l\u00e4ngsta" = "#CFE0D5"),
      name = NULL,
      guide = ggplot2::guide_legend(reverse = TRUE)) +
    ggplot2::expand_limits(y = max(top1_labels$total) * 1.12) +
    ggplot2::labs(title = "L\u00e4ngsta pass per \u00e5r",
                   subtitle = "Stapeln visar de fem l\u00e4ngsta passen; siffran ovanf\u00f6r = l\u00e4ngsta enskilda passet.",
                   x = NULL, y = "Kilometer (kumulerat)") +
    .theme_run_profile() +
    ggplot2::theme(legend.position = "bottom")
}

#' S\u00e4songsm\u00f6nster i tempo \u00f6ver alla \u00e5r
#'
#' Veckans medeltempo \u00f6ver alla \u00e5r som punkter; \u00e5rstidsband i bakgrunden;
#' loess-kurva med konfidensband.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.season_pace <- function(summaries, from = NULL, to = NULL,
                                     sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  woy_data <- runs %>% dplyr::filter(woy <= 52) %>%
    dplyr::group_by(woy) %>%
    dplyr::summarise(mean_pace = mean(pace),
                      p25 = stats::quantile(pace, .25),
                      p75 = stats::quantile(pace, .75),
                      n = dplyr::n(), .groups = "drop")

  seasons <- tibble::tribble(
    ~name,     ~start, ~end, ~fill,
    "Vinter",  1,      12,   "#D7E5F2",
    "V\u00e5r", 13,    21,   "#DDEED6",
    "Sommar",  22,     35,   "#FFF4D6",
    "H\u00f6st",36,    47,   "#EFD9C2",
    "Vinter",  48,     52,   "#D7E5F2"
  )
  season_labels <- tibble::tribble(
    ~name,     ~x,
    "Vinter",  6,
    "V\u00e5r", 17,
    "Sommar",  28,
    "H\u00f6st",41,
    "Vinter",  50
  )
  woy_breaks <- c(1, 13, 26, 39, 52)
  woy_labels <- c("V1\njan", "V13\napr", "V26\njul", "V39\nokt", "V52\ndec")

  ggplot2::ggplot(woy_data, ggplot2::aes(x = woy, y = mean_pace)) +
    ggplot2::geom_rect(data = seasons, inherit.aes = FALSE,
      ggplot2::aes(xmin = start - 0.5, xmax = end + 0.5,
                    ymin = -Inf, ymax = Inf, fill = fill),
      alpha = 0.55, show.legend = FALSE) +
    ggplot2::scale_fill_identity() +
    ggplot2::geom_point(colour = "#C97B4A", size = 2.2, alpha = 0.85) +
    ggplot2::geom_smooth(method = "loess", formula = y ~ x, se = TRUE,
                          colour = "#4682B4", fill = "#4682B4",
                          alpha = 0.18) +
    ggplot2::geom_text(data = season_labels, inherit.aes = FALSE,
      ggplot2::aes(x = x, y = Inf, label = name),
      vjust = 1.6, colour = "grey40", size = 3.2,
      fontface = "italic") +
    ggplot2::scale_y_reverse() +
    ggplot2::scale_x_continuous(breaks = woy_breaks, labels = woy_labels,
                                  expand = c(0.01, 0.01)) +
    ggplot2::labs(title = "S\u00e4songsm\u00f6nster i tempo",
                   subtitle = "Veckans medeltempo \u00f6ver alla \u00e5r. Bakgrund = \u00e5rstid; kurva = loess.",
                   x = NULL, y = "Tempo (min/km)") +
    .theme_run_profile()
}

#' Veckokilometer per \u00e5r som heatmap
#'
#' En cell per (\u00e5r, vecka). Cellf\u00e4rg = veckans totala km. Saknad data
#' visas i gr\u00e5tt.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.heatmap_km <- function(summaries, from = NULL, to = NULL,
                                    sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport, pace_filter = FALSE)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  heatmap_km <- runs %>% dplyr::filter(woy <= 52) %>%
    dplyr::group_by(year, woy) %>%
    dplyr::summarise(total_km = sum(km), .groups = "drop")
  heatmap_full <- expand.grid(year = sort(unique(runs$year)),
                               woy = 1:52,
                               KEEP.OUT.ATTRS = FALSE,
                               stringsAsFactors = FALSE) %>%
    dplyr::left_join(heatmap_km, by = c("year", "woy"))

  quarter_gaps   <- c(13, 26, 39)
  quarter_labels <- c("jan\u2013mar", "apr\u2013jun",
                      "jul\u2013sep", "okt\u2013dec")

  ggplot2::ggplot(heatmap_full,
                   ggplot2::aes(x = woy, y = factor(year), fill = total_km)) +
    ggplot2::geom_tile(colour = "white", linewidth = 0.1) +
    ggplot2::geom_vline(xintercept = quarter_gaps + 0.5,
                         colour = "white", linewidth = 1.5) +
    ggplot2::annotate("text", x = c(7, 19, 32, 45),
      y = length(unique(heatmap_full$year)) + 0.6,
      label = quarter_labels,
      colour = "grey35", fontface = "bold", size = 3.4) +
    ggplot2::scale_fill_viridis_c(option = "viridis", trans = "sqrt",
                                    na.value = "grey88", name = "Km/vecka") +
    ggplot2::scale_x_continuous(breaks = c(1, 13, 26, 39, 52),
                                  labels = c("V1", "V13", "V26", "V39", "V52"),
                                  expand = c(0.005, 0.005)) +
    ggplot2::coord_cartesian(clip = "off") +
    ggplot2::labs(title = "Veckokilometer per \u00e5r",
                   subtitle = "Cellf\u00e4rg = veckans totala km. Saknad data = gr\u00e5.",
                   x = NULL, y = NULL) +
    .theme_run_profile() +
    ggplot2::theme(axis.text.y = ggplot2::element_text(size = 8),
                    plot.margin = ggplot2::margin(28, 12, 12, 12))
}

#' Kumulativ km \u2014 innevarande \u00e5r vs historik
#'
#' En linje per \u00e5r som visar kumulativ km vecka f\u00f6r vecka. Innevarande \u00e5r
#' framh\u00e4vs i orange; alla tidigare \u00e5r \u00e4r gr\u00e5a bakgrundskurvor.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.cumulative_km <- function(summaries, from = NULL, to = NULL,
                                       sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport, pace_filter = FALSE)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  weekly_raw <- runs %>% dplyr::filter(woy <= 52) %>%
    dplyr::group_by(year, woy) %>%
    dplyr::summarise(km = sum(km), .groups = "drop")

  # Complete each year to weeks 1..52 with km = 0, so cumulative km
  # stays flat across gaps instead of linearly interpolating between
  # the previous and next run. For the current year we still want the
  # line to stop at the last observed week (no zero-padding into the
  # unrun future), so trim its tail after completion.
  current_year <- max(weekly_raw$year)
  current_max_woy <- max(weekly_raw$woy[weekly_raw$year == current_year])

  weekly <- weekly_raw %>%
    tidyr::complete(year, woy = 1:52, fill = list(km = 0)) %>%
    dplyr::filter(year != current_year | woy <= current_max_woy) %>%
    dplyr::arrange(year, woy) %>%
    dplyr::group_by(year) %>%
    dplyr::mutate(cumkm = cumsum(km)) %>% dplyr::ungroup()

  end_pts <- weekly %>% dplyr::group_by(year) %>%
    dplyr::slice_max(woy, n = 1) %>% dplyr::ungroup()

  weekly_split <- weekly %>% dplyr::mutate(is_current = year == current_year)

  ggplot2::ggplot(weekly_split,
                   ggplot2::aes(x = woy, y = cumkm, group = year)) +
    ggplot2::geom_line(data = dplyr::filter(weekly_split, !is_current),
                        colour = "grey75", linewidth = 0.4, alpha = 0.65) +
    ggplot2::geom_line(data = dplyr::filter(weekly_split, is_current),
                        colour = "#C97B4A", linewidth = 1.4) +
    ggplot2::geom_point(data = dplyr::filter(weekly_split, is_current),
                         colour = "#C97B4A", size = 1.8) +
    ggplot2::geom_text(data = dplyr::filter(end_pts, year == current_year),
      ggplot2::aes(label = sprintf("%d: %.0f km", year, cumkm)),
      hjust = -0.15, size = 3.2, colour = "#C97B4A", fontface = "bold") +
    ggplot2::scale_x_continuous(breaks = c(1, 13, 26, 39, 52),
                                  labels = c("V1", "V13", "V26", "V39", "V52"),
                                  expand = ggplot2::expansion(add = c(0, 6))) +
    ggplot2::labs(title = "Kumulativ km \u2014 innevarande \u00e5r vs historik",
                   subtitle = "Gr\u00e5 linjer = tidigare \u00e5r. Orange = innevarande \u00e5r.",
                   x = NULL, y = "Kumulerad km") +
    .theme_run_profile()
}

#' Distans \u00d7 tempo som hex-densitet per epok
#'
#' Hex-bin av enskilda pass (distans vs tempo), uppdelat i fyra epoker.
#' Vita streck + prick = hela datasetets median (samma referens i alla
#' paneler, s\u00e5 epokernas tyngdpunkter g\u00e5r att j\u00e4mf\u00f6ra med varandra).
#'
#' Epok-gr\u00e4nserna \u00e4r 2005\u20132010, 2011\u20132016, 2017\u20132021, 2022\u20132026.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.distance_pace_era <- function(summaries, from = NULL, to = NULL,
                                            sport = "running") {
  runs <- .run_profile_runs(summaries, sport = sport)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) == 0) return(.run_profile_empty())

  runs_era <- runs %>%
    dplyr::mutate(era_base = dplyr::case_when(
      year <= 2010 ~ "2005\u20132010",
      year <= 2016 ~ "2011\u20132016",
      year <= 2021 ~ "2017\u20132021",
      TRUE         ~ "2022\u20132026")) %>%
    dplyr::mutate(era = factor(era_base,
      levels = c("2022\u20132026", "2017\u20132021",
                  "2011\u20132016", "2005\u20132010")))

  all_median_pace <- stats::median(runs$pace)
  all_median_km   <- stats::median(runs$km)

  ggplot2::ggplot(runs_era, ggplot2::aes(x = km, y = pace)) +
    ggplot2::geom_hex(bins = 30, alpha = 0.92) +
    ggplot2::geom_hline(yintercept = all_median_pace,
                         colour = "white", linewidth = 0.6,
                         linetype = "dashed") +
    ggplot2::geom_vline(xintercept = all_median_km,
                         colour = "white", linewidth = 0.6,
                         linetype = "dashed") +
    ggplot2::annotate("point", x = all_median_km, y = all_median_pace,
                       colour = "white", fill = "#C97B4A", shape = 21,
                       size = 4, stroke = 0.9) +
    ggplot2::scale_fill_viridis_c(option = "plasma", trans = "log",
                                    name = "Pass",
                                    breaks = c(1, 10, 100, 1000)) +
    ggplot2::scale_x_log10() +
    ggplot2::scale_y_reverse() +
    ggplot2::facet_wrap(~ era, ncol = 1) +
    ggplot2::labs(title = "Distans \u00d7 tempo per epok",
                   subtitle = "Hex-t\u00e4thet av enskilda pass. Vita streck + prick = hela datasetets median (samma i alla paneler).",
                   x = "Kilometer (log)", y = "Tempo (min/km)") +
    .theme_run_profile()
}
