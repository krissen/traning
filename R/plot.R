# Plot functions — each returns a ggplot2 object

# --- Adaptive granularity helpers --------------------------------------------

# Compute span in days from from/to, with a fallback default. If
# `data_dates` is supplied and from/to are not both set, the span is
# derived from the data range — this keeps .adaptive_date_scale() in
# sync when callers pass NULL/NULL ("Allt"-presetet) on a multi-year
# dataset (otherwise the 365-day fallback would pick monthly breaks
# for a chart spanning two decades, triggering scale_x_date warnings).
.compute_span_days <- function(from, to, fallback_days = 365,
                               data_dates = NULL) {
  if (!is.null(from) && !is.null(to)) {
    return(as.numeric(as.Date(to) - as.Date(from)))
  }
  if (!is.null(data_dates) && length(data_dates) > 0) {
    rng <- suppressWarnings(range(as.Date(data_dates), na.rm = TRUE))
    if (all(is.finite(rng))) return(as.numeric(diff(rng)))
  }
  fallback_days
}

# Single source of truth for break/label/rotation choice per span. The
# adaptive helpers below build a scale_x_date() / scale_x_datetime() on
# top of this spec. Targets ≤ ~8 visible labels per panel at typical
# widths; check.overlap = TRUE on the guide is a safety net that drops
# labels which would still collide on narrow panels.
#
# Thresholds derived from: "%d %b" labels are narrow (~40 px),
# "%b %Y" are ~70 px, "%Y" are ~30 px. With a ~700 px panel we can
# afford ~10 wide / ~17 narrow labels — we aim well below.
.adaptive_date_spec <- function(span_days) {
  if (span_days <= 14) {
    list(labels = "%d %b", breaks = "1 day",    angle = 45)
  } else if (span_days <= 60) {
    list(labels = "%d %b", breaks = "1 week",   angle = 45)
  } else if (span_days <= 180) {
    list(labels = "%b %Y", breaks = "1 month",  angle = 45)
  } else if (span_days <= 365 * 2) {
    list(labels = "%b %Y", breaks = "2 months", angle = 45)
  } else if (span_days <= 365 * 5) {
    list(labels = "%b %Y", breaks = "6 months", angle = 45)
  } else {
    list(labels = "%Y",    breaks = "1 year",   angle = 0)
  }
}

# Return a scale_x_date() layer with adaptive breaks/labels/rotation for
# the span. Rotation is baked into the scale via guide_axis() so callers
# don't need a separate theme(axis.text.x = ...) override.
.adaptive_date_scale <- function(span_days) {
  spec <- .adaptive_date_spec(span_days)
  ggplot2::scale_x_date(
    date_labels = spec$labels,
    date_breaks = spec$breaks,
    guide = ggplot2::guide_axis(check.overlap = TRUE, angle = spec$angle)
  )
}

# POSIXct (sessionStart) variant of .adaptive_date_scale().
.adaptive_datetime_scale <- function(span_days) {
  spec <- .adaptive_date_spec(span_days)
  ggplot2::scale_x_datetime(
    date_labels = spec$labels,
    date_breaks = spec$breaks,
    guide = ggplot2::guide_axis(check.overlap = TRUE, angle = spec$angle)
  )
}

# Filter a data frame by from/to on a date-like column.
# closed_upper = TRUE  → use <= to (inclusive upper bound).
#   Use for date-columns (daily aggregates: ACWR, PMC, MS, readiness, RHR, HRV …).
#   A date-row represents a finalised calendar day; the upper bound should be
#   inclusive so that KPI boxes (slice_max(date)) and mini-charts agree on
#   today's value. See docs/dev/filter-consistency.md.
# closed_upper = FALSE → use <  to (half-open, default).
#   Use for sessionStart / POSIXct columns (session-level data: EF, HRE,
#   decoupling, run-mix). A datetime represents a momentary event that may
#   still be in progress; today's in-progress session is excluded until done.
.filter_date_range <- function(data, date_col, from, to, closed_upper = FALSE) {
  if (!is.null(from)) {
    data <- data[as.Date(data[[date_col]]) >= as.Date(from), , drop = FALSE]
  }
  if (!is.null(to)) {
    if (closed_upper) {
      data <- data[as.Date(data[[date_col]]) <= as.Date(to), , drop = FALSE]
    } else {
      data <- data[as.Date(data[[date_col]]) < as.Date(to), , drop = FALSE]
    }
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
      values = c("Tempo, medel" = traning_palette$status[["red"]])) +
    ggplot2::scale_fill_manual(" ",
      values = c("Dist., medel" = traning_palette$primary,
                 "Dist. per dag, medel." = traning_palette$accent_warm)) +
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

  # Weekly km for volume panel — force km mode so a sport="all" caller
  # still gets a populated volume panel (TRIMP-mode would render NA
  # bars since EF's volume axis is fundamentally km).
  acwr_data <- compute_acwr(summaries, sport = sport, mode = "km") %>%
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
      colour = traning_palette$primary, se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      data = dplyr::filter(combined, metrik == "ef_rolling28"),
      ggplot2::aes(y = value),
      colour = traning_palette$status[["red"]], linewidth = 0.9, na.rm = TRUE
    )
  }

  p <- p +
    # Weekly km bars — width must be in seconds for POSIXct x-axis
    # (width = 1 would be 1 second, rendering bars as invisible
    # hairlines over multi-month/year spans). 86400 s = 1 day.
    ggplot2::geom_col(
      data = dplyr::filter(combined, metrik == "weekly_km"),
      ggplot2::aes(y = value),
      fill = traning_palette$accent, alpha = 0.7, width = 86400
    ) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(panel),
      scales = "free_y",
      space = "fixed"
    ) +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Effektivitetsfaktor (EF) över tid") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(strip.text = ggplot2::element_text(face = "bold"))
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
    # Votyakov threshold bands (traffic-light, see traning_palette$traffic_bg)
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = -Inf, ymax = 700,
      fill = traning_palette$traffic_bg[["green"]], alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 700, ymax = 750,
      fill = traning_palette$traffic_bg[["yellow"]], alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 800, ymax = Inf,
      fill = traning_palette$traffic_bg[["red"]], alpha = 0.06
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
      colour = traning_palette$primary, se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      ggplot2::aes(y = hre_rolling28),
      colour = traning_palette$status[["red"]], linewidth = 0.9, na.rm = TRUE
    )
  }

  p <- p +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Hjärtslagskostnad (HRE) över tid") +
    ggplot2::labs(
      x = NULL,
      y = "Hjärtslagskostnad (slag/km)"
    )
  return(p)
}

#' Line plot of Acute:Chronic Workload Ratio (ACWR) over time
#'
#' Calls \code{compute_acwr()} internally.  The ACWR line is coloured by
#' zone (green = sweet spot 0.8-1.3, yellow = caution 1.3-1.5, red = danger
#' > 1.5 or undertraining < 0.5).  Horizontal reference lines mark the zone
#' boundaries.  A bar panel below shows weekly km.  When \code{from} and
#' \code{to} are both \code{NULL} the full history is shown.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param from,to Optional date bounds. \code{NULL} means no bound — pass
#'   both as \code{NULL} to render the full history.
#' @param sport Sport bucket (default \code{"running"}). Forwarded to
#'   \code{compute_acwr()}.
#' @param mode One of \code{"km"}, \code{"trimp"} or \code{NULL} (auto;
#'   forwarded to \code{compute_acwr()}).
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}; threaded into \code{compute_acwr()} so
#'   the TRIMP-mode rendering can fold in background activity.
#' @return ggplot2 object
#' @export
fetch.plot.acwr <- function(summaries, from = NULL, to = NULL,
                            sport = "running", mode = NULL,
                            health_daily = NULL) {
  acwr_data <- compute_acwr(summaries, sport = sport, mode = mode,
                            health_daily = health_daily)
  resolved_mode <- attr(acwr_data, "mode") %||% "km"

  acwr_window <- .filter_date_range(acwr_data, "date", from, to, closed_upper = TRUE) %>%
    dplyr::filter(!is.na(acwr))

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
  # Panel 2: weekly_load (km in km-mode, TRIMP in trimp-mode) as bars
  volume_panel_label <- if (resolved_mode == "trimp") {
    "Veckobelastning (TRIMP)"
  } else {
    "Veckokilometer"
  }
  acwr_panel <- acwr_window %>%
    dplyr::select(date, acwr, zon) %>%
    dplyr::rename(value = acwr) %>%
    dplyr::mutate(panel = "ACWR")

  km_panel <- acwr_window %>%
    dplyr::select(date, weekly_load) %>%
    dplyr::rename(value = weekly_load) %>%
    dplyr::mutate(zon = NA_character_, panel = volume_panel_label)

  # We need two separate layers, so we build the plot programmatically
  # rather than through facet_grid (zone colouring only applies to the
  # ACWR panel).  Use a shared x axis via a two-panel facet approach:
  # convert to a single data frame with a 'panel' grouping variable and
  # draw geoms conditionally.

  panel_levels <- c("ACWR", volume_panel_label)
  combined <- dplyr::bind_rows(
    acwr_panel %>% dplyr::mutate(zon = as.character(zon)),
    km_panel
  ) %>%
    dplyr::mutate(panel = factor(panel, levels = panel_levels))

  # ACWR zone colours map to traning_palette$traffic_bg.
  zon_farger <- c(
    "Underbelastning" = traning_palette$traffic_bg[["orange"]],
    "Optimalt"        = traning_palette$traffic_bg[["green"]],
    "Varning"         = traning_palette$traffic_bg[["yellow"]],
    "Överbelastning"  = traning_palette$traffic_bg[["red"]]
  )

  # Reference band and lines — drawn only inside the ACWR panel using
  # data arguments that subset to the right panel.
  ref_df <- data.frame(
    panel = factor("ACWR", levels = panel_levels)
  )

  span <- .compute_span_days(from, to, data_dates = acwr_window$date)

  combined %>%
    ggplot2::ggplot(ggplot2::aes(x = date)) +
    # Sweet-spot band (ACWR 0.8-1.3)
    ggplot2::geom_rect(
      data = ref_df,
      ggplot2::aes(xmin = -Inf, xmax = Inf, ymin = 0.8, ymax = 1.3),
      fill = traning_palette$traffic_bg[["green"]], alpha = 0.08, inherit.aes = FALSE
    ) +
    # Danger threshold line
    ggplot2::geom_hline(
      data = ref_df,
      ggplot2::aes(yintercept = 1.5),
      colour = traning_palette$traffic_bg[["red"]], linetype = "dashed", linewidth = 0.5
    ) +
    # Uncoupled ACWR — dashed grey line for comparison
    # (Impellizzeri 2020: coupled ACWR systematically dampens spikes)
    ggplot2::geom_line(
      data = acwr_window %>%
        dplyr::filter(!is.na(acwr_uncoupled)) %>%
        dplyr::mutate(panel = factor("ACWR", levels = panel_levels)),
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
    # Volume bars (km in km-mode, TRIMP in trimp-mode)
    ggplot2::geom_col(
      data = dplyr::filter(combined, panel == volume_panel_label),
      ggplot2::aes(y = value),
      fill = traning_palette$accent, alpha = 0.7, width = 1
    ) +
    ggplot2::scale_colour_manual(
      name   = "Zon",
      values = zon_farger,
      na.value = traning_palette$primary
    ) +
    ggplot2::facet_grid(
      rows   = ggplot2::vars(panel),
      scales = "free_y",
      space  = "fixed"
    ) +
    .adaptive_date_scale(span) +
    ggplot2::ggtitle("Akut:kronisk belastningskvot") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(
      strip.text   = ggplot2::element_text(face = "bold"),
      legend.position = "bottom"
    ) -> p

  # Show individual data points at short spans
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
#' panel shows training strain.  When \code{from} and \code{to} are both
#' \code{NULL} the full history is shown.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param from,to Optional date bounds. \code{NULL} means no bound — pass
#'   both as \code{NULL} to render the full history.
#' @param sport Sport bucket (default \code{"running"}).
#' @return ggplot2 object
#' @export
fetch.plot.monotony <- function(summaries, from = NULL, to = NULL,
                                sport = "running") {
  ms_data <- compute_monotony_strain(summaries, sport = sport)

  ms_window <- .filter_date_range(ms_data, "date", from, to, closed_upper = TRUE)
  span <- .compute_span_days(from, to, data_dates = ms_window$date)

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

  p <- long %>%
    ggplot2::ggplot(ggplot2::aes(x = date, y = value)) +
    # Overtraining threshold line for monotony
    ggplot2::geom_hline(
      data = ref_df,
      ggplot2::aes(yintercept = 2.0),
      colour = traning_palette$traffic_bg[["red"]], linetype = "dashed", linewidth = 0.6
    ) +
    ggplot2::geom_line(
      colour = traning_palette$primary, linewidth = 0.7, na.rm = TRUE
    ) +
    ggplot2::facet_grid(
      rows   = ggplot2::vars(metrik),
      scales = "free_y",
      space  = "fixed"
    ) +
    .adaptive_date_scale(span) +
    ggplot2::ggtitle("Träningsmonotoni och belastning") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(strip.text = ggplot2::element_text(face = "bold"))

  # Show individual data points at short spans
  if (span <= 60) {
    p <- p + ggplot2::geom_point(size = 2, alpha = 0.7, colour = traning_palette$primary)
  }

  return(p)
}

#' Performance Management Chart (PMC)
#'
#' Three-panel chart showing CTL (fitness), ATL (fatigue), and TSB (form)
#' derived from daily TRIMP via exponentially weighted moving averages.
#' TSB zones use coaching heuristics — not validated for recreational running.
#' When \code{from} and \code{to} are both \code{NULL} the full history is shown.
#'
#' @param summaries Summaries data frame.
#' @param hr_max Numeric or NULL. HRmax override.
#' @param hr_rest Numeric or NULL. HRrest override.
#' @param from,to Optional date bounds. \code{NULL} means no bound — pass
#'   both as \code{NULL} to render the full history.
#' @param sport Sport bucket (default \code{"all"} — PMC is a
#'   whole-system load metric, matching how readiness and the overview
#'   KPI cards use it). Pass \code{"running"} (or another bucket) to
#'   restrict to a single sport.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}; threaded into \code{compute_pmc()} so
#'   background-activity TRIMP folds into the displayed PMC for
#'   whole-system buckets.
#' @return ggplot2 object
#' @export
fetch.plot.pmc <- function(summaries, hr_max = NULL, hr_rest = NULL,
                           from = NULL, to = NULL, sport = "all",
                           health_daily = NULL) {
  pmc_data <- compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest,
                          sport = sport, health_daily = health_daily)

  if (nrow(pmc_data) == 0) {
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen TRIMP-data tillgänglig"))
  }

  pmc_window <- .filter_date_range(pmc_data, "date", from, to, closed_upper = TRUE)
  span <- .compute_span_days(from, to, data_dates = pmc_window$date)

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

  # TSB zone palette maps to traffic_bg + cool/neutral tones. "Utvilad"
  # uses the blue zone1 colour (rested/cool).
  # AVVIKELSE FRÅN TEMA: "Produktiv" stays neutral grey (#95a5a6) — it
  # sits between sweet-spot (green) and overload (red), and a chromatic
  # palette tone would imply it leans toward one or the other. The
  # neutral grey communicates "intermediate, no judgement".
  zon_farger <- c(
    "Utvilad"       = traning_palette$zones[["Z1"]],
    "Tävlingsredo"  = traning_palette$traffic_bg[["green"]],
    "Produktiv"     = "#95a5a6",
    "Trött"         = traning_palette$traffic_bg[["yellow"]],
    "Överbelastad"  = traning_palette$traffic_bg[["red"]]
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
    # AVVIKELSE FRÅN TEMA: CTL/ATL is the Allen/Coggan PMC convention;
    # both series overlap so they need high-contrast colours. status$*
    # (muted earth tones) made the two lines indistinguishable in the
    # combined panel. Use zones$Z1 (saturated blue) for the fitness
    # baseline and traffic_bg$red for the fatigue alarm.
    ggplot2::scale_colour_manual(
      name   = NULL,
      values = c("Fitness (CTL)" = traning_palette$zones[["Z1"]],
                 "Trötthet (ATL)" = traning_palette$traffic_bg[["red"]])
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
      fill = traning_palette$accent, alpha = 0.7, width = 1
    ) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(panel),
      scales = "free_y",
      space = "fixed"
    ) +
    .adaptive_date_scale(span) +
    ggplot2::ggtitle("Performance Management Chart (PMC)",
                     subtitle = .pmc_scope_subtitle(sport, health_daily)) +
    ggplot2::labs(
      x = NULL, y = NULL,
      caption = "TSB-trösklar är coaching-heuristik, ej validerade för motionslöpning"
    ) +
    ggplot2::theme(
      strip.text      = ggplot2::element_text(face = "bold"),
      legend.position = "bottom"
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
      colour = traning_palette$primary, se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      ggplot2::aes(y = recovery_hr_rolling28),
      colour = traning_palette$status[["red"]], linewidth = 0.9, na.rm = TRUE
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
    ggplot2::labs(x = NULL)

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
                                  cap_pct = 25,
                                  sport = "running") {
  if (is.null(decoupling_data)) {
    decoupling_data <- compute_decoupling(summaries, myruns,
                                           cap_pct = cap_pct,
                                           sport = sport)
  }

  if (nrow(decoupling_data) == 0) {
    message("Ingen decoupling-data tillg\u00e4nglig.")
    return(ggplot2::ggplot() + ggplot2::ggtitle("Ingen decoupling-data"))
  }

  # Older cache files predate the `capped` column \u2014 backfill so the
  # downstream filters/layers see a consistent shape.
  if (!"capped" %in% names(decoupling_data)) {
    decoupling_data$capped <- FALSE
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
  # against running km totals. Force km mode so a sport="all" caller
  # still gets a populated volume panel.
  acwr_data <- compute_acwr(summaries, sport = sport, mode = "km") %>%
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
    dplyr::select(sessionStart, dplyr::all_of(dc_cols), capped) %>%
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
      capped = FALSE,
      panel = factor("Veckokilometer",
                     levels = c("Decoupling (%)", "Veckokilometer"))
    ) %>%
    dplyr::select(sessionStart, metrik, value, capped, panel)

  combined <- dplyr::bind_rows(dc_panel, km_panel)

  p <- combined %>%
    ggplot2::ggplot(ggplot2::aes(x = sessionStart)) +
    # Threshold bands (only visible in decoupling panel; traffic-light)
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = -Inf, ymax = 3,
      fill = traning_palette$traffic_bg[["green"]], alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 3, ymax = 5,
      fill = traning_palette$traffic_bg[["yellow"]], alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 5, ymax = 8,
      fill = traning_palette$traffic_bg[["orange"]], alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = -Inf, xmax = Inf, ymin = 8, ymax = Inf,
      fill = traning_palette$traffic_bg[["red"]], alpha = 0.06
    ) +
    ggplot2::geom_hline(yintercept = c(3, 5, 8),
      colour = "grey70", linetype = "dotted", linewidth = 0.4
    ) +
    # Decoupling points (regular, non-capped)
    ggplot2::geom_point(
      data = dplyr::filter(combined, metrik == "decoupling_pct", !capped),
      ggplot2::aes(y = value),
      alpha = pt_alpha, size = pt_size, colour = "grey40"
    )

  # Capped sessions: render at the cap line so the y-axis isn't blown
  # up by a single -75 % artefact, but the user can see *that* a
  # session was flagged on this date. NA decoupling_pct rows (rare,
  # produced when ratios are non-finite) get pinned at +cap_pct.
  capped_layer <- combined %>%
    dplyr::filter(metrik == "decoupling_pct", capped) %>%
    dplyr::mutate(value_clamp = ifelse(
      is.na(value),
      cap_pct,
      sign(value) * pmin(abs(value), cap_pct)
    ))
  if (nrow(capped_layer) > 0) {
    p <- p + ggplot2::geom_point(
      data = capped_layer,
      ggplot2::aes(y = value_clamp),
      shape = 17, colour = traning_palette$traffic_bg[["red"]],
      size = pt_size + 0.5, alpha = 0.85
    )
  }

  if (show_smooth) {
    p <- p + ggplot2::geom_smooth(
      data = dplyr::filter(combined, metrik == "decoupling_pct", !capped),
      ggplot2::aes(y = value),
      method = "loess", formula = "y ~ x",
      colour = traning_palette$primary, se = FALSE, linewidth = 0.8
    )
  }

  if (show_rolling) {
    p <- p + ggplot2::geom_line(
      data = dplyr::filter(combined, metrik == "decoupling_rolling28"),
      ggplot2::aes(y = value),
      colour = traning_palette$status[["red"]], linewidth = 0.9, na.rm = TRUE
    )
  }

  p <- p +
    # Weekly km bars \u2014 see fetch.plot.ef for the width-in-seconds note.
    ggplot2::geom_col(
      data = dplyr::filter(combined, metrik == "weekly_km"),
      ggplot2::aes(y = value),
      fill = traning_palette$accent, alpha = 0.7, width = 86400
    ) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(panel),
      scales = "free_y",
      space = "fixed"
    ) +
    .adaptive_datetime_scale(span) +
    ggplot2::ggtitle("Aerob decoupling \u00f6ver tid") +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme(strip.text = ggplot2::element_text(face = "bold"))

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
                          fill = traning_palette$run_profile$history, alpha = 0.18) +
    ggplot2::geom_line(colour = traning_palette$run_profile$history, linewidth = 0.7) +
    ggplot2::geom_point(colour = traning_palette$run_profile$history, size = 1.6) +
    ggplot2::geom_point(data = milestones,
      ggplot2::aes(x = year, y = y_anchor),
      shape = 21, fill = traning_palette$run_profile$fill$light,
      colour = traning_palette$run_profile$fill$dark,
      size = 3.2, stroke = 0.8) +
    ggrepel::geom_label_repel(data = milestones,
      ggplot2::aes(x = year, y = y_anchor, label = label),
      size = 2.6, colour = traning_palette$run_profile$fill$darker,
      fill = traning_palette$run_profile$fill$bg,
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

#' \u0394-staplar mediantempo per vecka
#'
#' Per ISO-vecka: skillnaden i mediantempo mot f\u00f6reg\u00e5ende vecka. Stapel
#' under noll = veckan blev snabbare; \u00f6ver noll = l\u00e5ngsammare. Anv\u00e4nder
#' samma globala tidsfilter som \u00f6vriga Tr\u00e4ning-fliken-plottar.
#'
#' @inheritParams fetch.plot.pace_year
#' @return ggplot2-objekt.
#' @export
fetch.plot.pace_week_delta <- function(summaries, from = NULL, to = NULL,
                                        sport = "running") {
  # pace_filter = FALSE so cycling (~1.5-3 min/km), walking (>10) and
  # other non-running sports still produce data. The week-over-week
  # delta is computed on the bucket's own pace distribution, so the
  # 2.5-10 min/km running band would otherwise zero out every other
  # sport on the global selector.
  runs <- .run_profile_runs(summaries, sport = sport, pace_filter = FALSE)
  runs <- .run_profile_filter_range(runs, from, to)
  if (nrow(runs) < 4) {
    return(.run_profile_empty("F\u00f6r f\u00e5 pass f\u00f6r \u0394-vecka"))
  }

  weekly <- runs %>%
    dplyr::mutate(
      week_start = lubridate::floor_date(.data$date, "week", week_start = 1)
    ) %>%
    dplyr::group_by(.data$week_start) %>%
    dplyr::summarise(median_pace = stats::median(.data$pace, na.rm = TRUE),
                     n = dplyr::n(),
                     .groups = "drop") %>%
    dplyr::filter(!is.na(.data$median_pace)) %>%
    dplyr::arrange(.data$week_start)

  if (nrow(weekly) < 2) {
    return(.run_profile_empty("F\u00f6r f\u00e5 veckor f\u00f6r \u0394"))
  }

  weekly <- weekly %>%
    dplyr::mutate(
      delta  = .data$median_pace - dplyr::lag(.data$median_pace),
      faster = .data$delta < 0
    ) %>%
    dplyr::filter(!is.na(.data$delta))

  if (nrow(weekly) == 0) {
    return(.run_profile_empty("F\u00f6r kort intervall"))
  }

  span <- .compute_span_days(from, to, data_dates = weekly$week_start)

  ggplot2::ggplot(weekly, ggplot2::aes(x = .data$week_start, y = .data$delta,
                                        fill = .data$faster)) +
    # width = 6 (Date axis) gives bars that almost touch on the 7-day
    # ISO grid without overlapping into the next week.
    ggplot2::geom_col(width = 6) +
    ggplot2::geom_hline(yintercept = 0, colour = "grey40", linewidth = 0.4) +
    ggplot2::scale_fill_manual(
      values = c(`TRUE` = traning_palette$traffic_bg[["green"]],
                 `FALSE` = traning_palette$traffic_bg[["red"]]),
      labels = c(`TRUE` = "Snabbare", `FALSE` = "L\u00e5ngsammare"),
      name   = NULL
    ) +
    .adaptive_date_scale(span) +
    ggplot2::labs(
      title = "\u0394 Mediantempo per vecka",
      subtitle = "Stapel under noll = snabbare \u00e4n f\u00f6reg\u00e5ende vecka.",
      x = NULL,
      y = "\u0394 tempo (min/km)"
    ) +
    .theme_run_profile()
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
  # Pace traffic-light: see traning_palette$traffic for rationale.
  palette_traffic <- c("Lugn"  = traning_palette$traffic[["calm"]],
                       "Medel" = traning_palette$traffic[["medium"]],
                       "Snabb" = traning_palette$traffic[["fast"]])

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
    # Duration-rank gradient: see traning_palette$duration_rank.
    ggplot2::scale_fill_manual(
      values = c("5:e l\u00e4ngsta" = traning_palette$duration_rank[1],
                 "4:e"           = traning_palette$duration_rank[2],
                 "3:e"           = traning_palette$duration_rank[3],
                 "2:a"           = traning_palette$duration_rank[4],
                 "1:a l\u00e4ngsta" = traning_palette$duration_rank[5]),
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
  if (nrow(woy_data) == 0) return(.run_profile_empty())

  # Season bands: see traning_palette$seasons.
  seasons <- tibble::tribble(
    ~name,     ~start, ~end, ~fill,
    "Vinter",  1,      12,   traning_palette$seasons[["winter"]],
    "V\u00e5r", 13,    21,   traning_palette$seasons[["spring"]],
    "Sommar",  22,     35,   traning_palette$seasons[["summer"]],
    "H\u00f6st",36,    47,   traning_palette$seasons[["autumn"]],
    "Vinter",  48,     52,   traning_palette$seasons[["winter"]]
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

  # Compute finite y-range with padding so season bands fill the panel
  # including the loess CI band. scale_y_reverse() doesn't reliably
  # propagate -Inf/Inf through the reversed scale, causing rectangles
  # to fall outside the plot domain.
  y_rng <- range(woy_data$mean_pace, na.rm = TRUE)
  # Floor pad so degenerate ranges (single week, constant pace across
  # weeks) still produce non-zero band height. 0.25 min/km is a
  # sensible fallback when there's no spread to compute against.
  pad   <- max(diff(y_rng) * 0.08, 0.25)
  y_lo  <- y_rng[1] - pad   # lower numeric value = faster pace (top of reversed axis)
  y_hi  <- y_rng[2] + pad   # higher numeric value = slower pace (bottom of reversed axis)

  ggplot2::ggplot(woy_data, ggplot2::aes(x = woy, y = mean_pace)) +
    ggplot2::annotate("rect",
      xmin  = seasons$start - 0.5, xmax = seasons$end + 0.5,
      ymin  = y_lo, ymax = y_hi,
      fill  = seasons$fill, alpha = 0.55) +
    ggplot2::geom_point(colour = traning_palette$run_profile$current, size = 2.2, alpha = 0.85) +
    ggplot2::geom_smooth(method = "loess", formula = y ~ x, se = TRUE,
                          colour = traning_palette$run_profile$history, fill = traning_palette$run_profile$history,
                          alpha = 0.18) +
    # Anchor labels at an explicit data y near the band top (= y_lo,
    # the faster-pace edge — top of the panel under scale_y_reverse).
    # Using y = Inf here would land them at the bottom of the
    # reversed panel instead of the top.
    ggplot2::geom_text(data = season_labels, inherit.aes = FALSE,
      ggplot2::aes(x = x, y = y_lo + (y_hi - y_lo) * 0.05, label = name),
      colour = "grey40", size = 3.2, fontface = "italic") +
    ggplot2::scale_y_reverse() +
    ggplot2::scale_x_continuous(breaks = woy_breaks, labels = woy_labels,
                                  expand = c(0.01, 0.01)) +
    # ylim locks the panel to the season-band extent; expand = FALSE
    # disables the default 5% padding so the bands fully reach the
    # panel edge (no thin unshaded strips at top/bottom). clip = "off"
    # is kept for the loess CI ribbon, which is allowed to extend
    # outside the band in cases where it is wider than mean_pace ± pad.
    ggplot2::coord_cartesian(ylim = c(y_lo, y_hi),
                             expand = FALSE, clip = "off") +
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

  n_years <- length(unique(heatmap_full$year))

  ggplot2::ggplot(heatmap_full,
                   ggplot2::aes(x = woy, y = factor(year), fill = total_km)) +
    ggplot2::geom_tile(colour = "white", linewidth = 0.1) +
    ggplot2::geom_vline(xintercept = quarter_gaps + 0.5,
                         colour = "white", linewidth = 1.5) +
    # Quarter labels via geom_text (not scale_x_continuous(sec.axis))
    # because plotly::ggplotly() does not carry secondary axes; the
    # dashboard renders this plot through plotly so the labels would
    # vanish there. geom_text traces survive ggplotly cleanly.
    ggplot2::geom_text(
      data = data.frame(
        x = c(7, 19, 32, 45),
        y = n_years + 0.6,
        label = quarter_labels
      ),
      ggplot2::aes(x = x, y = y, label = label),
      inherit.aes = FALSE,
      colour = "grey35", fontface = "bold", size = 3.4
    ) +
    ggplot2::scale_fill_viridis_c(option = "viridis", trans = "sqrt",
                                    na.value = "grey88", name = "Km/vecka") +
    ggplot2::scale_x_continuous(breaks = c(1, 13, 26, 39, 52),
                                  labels = c("V1", "V13", "V26", "V39", "V52"),
                                  expand = c(0.005, 0.005)) +
    # clip = "off" lets the quarter labels render in plot.margin space
    # above the panel; plot.margin top and plot.title bottom-margin
    # reserve the room so the labels don't overlap the title.
    ggplot2::coord_cartesian(clip = "off") +
    ggplot2::labs(title = "Veckokilometer per \u00e5r",
                   subtitle = "Cellf\u00e4rg = veckans totala km. Saknad data = gr\u00e5.",
                   x = NULL, y = NULL) +
    .theme_run_profile() +
    ggplot2::theme(
      axis.text.y      = ggplot2::element_text(size = 8),
      plot.title       = ggplot2::element_text(face = "bold",
                                                 margin = ggplot2::margin(b = 16)),
      plot.subtitle    = ggplot2::element_text(margin = ggplot2::margin(b = 12)),
      plot.margin      = ggplot2::margin(12, 12, 12, 12)
    )
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
  # the previous and next run. The current year still gets trimmed to
  # today's ISO week — extending zero-padded into unrun future weeks
  # would suggest a flat plateau that hasn't happened yet.
  #
  # current_year is anchored on the system date, not on max(year) in
  # the filtered data: a historical from/to range would otherwise paint
  # the range's last year orange even though the subtitle calls it the
  # innevarande år.
  current_year <- lubridate::year(Sys.Date())
  current_woy  <- as.integer(lubridate::isoweek(Sys.Date()))

  weekly <- weekly_raw %>%
    tidyr::complete(year, woy = 1:52, fill = list(km = 0)) %>%
    dplyr::filter(year != current_year | woy <= current_woy) %>%
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
                        colour = traning_palette$run_profile$current, linewidth = 1.4) +
    ggplot2::geom_point(data = dplyr::filter(weekly_split, is_current),
                         colour = traning_palette$run_profile$current, size = 1.8) +
    ggplot2::geom_text(data = dplyr::filter(end_pts, year == current_year),
      ggplot2::aes(label = sprintf("%d: %.0f km", year, cumkm)),
      hjust = -0.15, size = 3.2, colour = traning_palette$run_profile$current, fontface = "bold") +
    ggplot2::scale_x_continuous(breaks = c(1, 13, 26, 39, 52),
                                  labels = c("V1", "V13", "V26", "V39", "V52"),
                                  expand = ggplot2::expansion(add = c(0, 6))) +
    ggplot2::labs(title = "Kumulativ km \u2014 innevarande \u00e5r vs historik",
                   subtitle = "Gr\u00e5 linjer = tidigare \u00e5r. Orange = innevarande \u00e5r.",
                   x = NULL, y = "Kumulerad km") +
    .theme_run_profile()
}

#' Distans \u00d7 tempo som bin-densitet per epok
#'
#' Rektangul\u00e4r bin-densitet av enskilda pass (distans vs tempo),
#' uppdelat i fyra epoker. Vita streck + prick = hela datasetets
#' median (samma referens i alla paneler, s\u00e5 epokernas tyngdpunkter
#' g\u00e5r att j\u00e4mf\u00f6ra med varandra).
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

  # Pre-bin with cut() so plotly::ggplotly() can render hover-able tiles.
  # geom_bin2d() is not supported by ggplotly; geom_tile() is.
  # Use log10 binning on km (matches scale_x_log10), linear on pace.
  nbins       <- 30
  km_range    <- range(runs_era$km,   na.rm = TRUE)
  pace_range  <- range(runs_era$pace, na.rm = TRUE)
  # Guard against degenerate ranges: when every run has the same km
  # or the same pace, seq(..., length.out = nbins + 1) produces
  # repeated breakpoints and cut() fails with "'breaks' are not
  # unique". A density heatmap is meaningless in that case anyway.
  # Use a specific empty-state message — "Ingen data i intervallet"
  # would mislead users who do have runs in the filter (just not the
  # variation needed for a 2D density).
  if (diff(km_range) == 0 || diff(pace_range) == 0) {
    return(.run_profile_empty("För liten variation i distans/tempo"))
  }
  km_breaks   <- 10^seq(log10(km_range[1]),  log10(km_range[2]),  length.out = nbins + 1)
  pace_breaks <-     seq(pace_range[1],      pace_range[2],       length.out = nbins + 1)

  # Use xmin/xmax/ymin/ymax (geom_rect) instead of x/width (geom_tile)
  # because scale_x_log10() transforms positional aesthetics but not
  # `width` — so log-spaced tile widths get applied in log-space and
  # high-km bins render too wide in plotly. geom_rect's bounds are
  # transformed by the scale, so the bins land at correct extents.
  binned <- runs_era %>%
    dplyr::mutate(
      km_bin   = cut(km,   breaks = km_breaks,   include.lowest = TRUE, labels = FALSE),
      pace_bin = cut(pace, breaks = pace_breaks, include.lowest = TRUE, labels = FALSE)
    ) %>%
    dplyr::group_by(era, km_bin, pace_bin) %>%
    dplyr::summarise(count = dplyr::n(), .groups = "drop") %>%
    dplyr::mutate(
      km_lo   = km_breaks[km_bin],
      km_hi   = km_breaks[km_bin + 1],
      pace_lo = pace_breaks[pace_bin],
      pace_hi = pace_breaks[pace_bin + 1]
    )

  ggplot2::ggplot(runs_era, ggplot2::aes(x = km, y = pace)) +
    ggplot2::geom_rect(data = binned,
      ggplot2::aes(xmin = km_lo, xmax = km_hi,
                   ymin = pace_lo, ymax = pace_hi,
                   fill = count),
      alpha = 0.92, inherit.aes = FALSE) +
    ggplot2::geom_hline(yintercept = all_median_pace,
                         colour = "white", linewidth = 0.6,
                         linetype = "dashed") +
    ggplot2::geom_vline(xintercept = all_median_km,
                         colour = "white", linewidth = 0.6,
                         linetype = "dashed") +
    ggplot2::annotate("point", x = all_median_km, y = all_median_pace,
                       colour = "white", fill = traning_palette$run_profile$current, shape = 21,
                       size = 4, stroke = 0.9) +
    ggplot2::scale_fill_viridis_c(option = "plasma", trans = "log",
                                    name = "Pass",
                                    breaks = c(1, 10, 100, 1000)) +
    ggplot2::scale_x_log10() +
    ggplot2::scale_y_reverse() +
    ggplot2::facet_wrap(~ era, ncol = 1) +
    ggplot2::labs(title = "Distans \u00d7 tempo per epok",
                   subtitle = "Bin-t\u00e4thet av enskilda pass. Vita streck + prick = hela datasetets median (samma i alla paneler).",
                   x = "Kilometer (log)", y = "Tempo (min/km)") +
    .theme_run_profile()
  # `theme(aspect.ratio = ...)` is silently dropped by plotly::ggplotly,
  # so the wide-screen layout cap is applied via a max-width container
  # in app/tRanat/pages/page_runprofile.R instead.
}
