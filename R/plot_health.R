# Health data visualizations — each returns a ggplot2 object
# Uses adaptive helpers from R/plot.R: .compute_span_days(),
# .adaptive_date_scale(), .filter_date_range()

# --- Resting Heart Rate trend ------------------------------------------------

#' Resting heart rate trend with LOESS smoother
#'
#' Plots daily resting HR from Apple Watch with a 30-day LOESS smoother
#' and annual means. Optionally overlays weekly running distance.
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param summaries Optional Garmin summaries tibble for volume overlay.
#' @param from Start date (character or Date). NULL = all data.
#' @param to End date (character or Date). NULL = all data.
#' @return ggplot2 object.
#' @export
fetch.plot.resting_hr <- function(health_daily, summaries = NULL,
                                   from = NULL, to = NULL) {
  rhr <- health_daily |>
    dplyr::filter(metric == "resting_heart_rate")

  if (!is.null(from)) rhr <- rhr |> dplyr::filter(date >= as.Date(from))
  if (!is.null(to))   rhr <- rhr |> dplyr::filter(date < as.Date(to))

  if (nrow(rhr) == 0) {
    message("Ingen vilopulsdata i intervallet")
    return(ggplot2::ggplot())
  }

  span_days <- .compute_span_days(from, to)

  rhr$year <- factor(format(rhr$date, "%Y"))

  # Adapt point size and loess span to date range
  pt_size  <- if (span_days <= 30) 2 else 0.8
  pt_alpha <- if (span_days <= 30) 0.5 else 0.15
  loess_span <- if (span_days <= 30) 0.75 else if (span_days <= 90) 0.3 else 0.1

  # Annual means for reference lines (only meaningful for longer spans)
  annual <- rhr |>
    dplyr::group_by(year) |>
    dplyr::summarise(mean_rhr = mean(value, na.rm = TRUE),
                     mid_date = mean(date), .groups = "drop")

  p <- ggplot2::ggplot(rhr, ggplot2::aes(x = date, y = value)) +
    ggplot2::geom_point(alpha = pt_alpha, size = pt_size, colour = "grey50")

  if (nrow(rhr) >= 5) {
    p <- p + ggplot2::geom_smooth(method = "loess", span = loess_span,
                                   se = FALSE, colour = "firebrick",
                                   linewidth = 1)
  }

  if (span_days > 90) {
    p <- p +
      ggplot2::geom_point(data = annual,
                          ggplot2::aes(x = mid_date, y = mean_rhr),
                          size = 3, colour = "firebrick", shape = 18) +
      ggplot2::geom_text(data = annual,
                         ggplot2::aes(x = mid_date, y = mean_rhr,
                                      label = round(mean_rhr, 0)),
                         vjust = -1, size = 3, colour = "firebrick")
  }

  p <- p +
    .adaptive_date_scale(span_days) +
    ggplot2::labs(title = "Vilopuls (Apple Watch)",
                  x = NULL, y = "bpm") +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        angle = if (span_days <= 60) 45 else 0,
        hjust = if (span_days <= 60) 1 else 0.5)
    )

  p
}

# --- HRV trend ---------------------------------------------------------------

#' HRV (Ln RMSSD) trend with 7-day rolling baseline
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param from Start date. NULL = all data.
#' @param to End date. NULL = all data.
#' @return ggplot2 object.
#' @export
fetch.plot.hrv <- function(health_daily, from = NULL, to = NULL) {
  hrv <- health_daily |>
    dplyr::filter(metric == "heart_rate_variability") |>
    dplyr::arrange(date) |>
    dplyr::mutate(ln_rmssd = log(value))

  if (!is.null(from)) hrv <- hrv |> dplyr::filter(date >= as.Date(from))
  if (!is.null(to))   hrv <- hrv |> dplyr::filter(date < as.Date(to))

  if (nrow(hrv) == 0) {
    message("Ingen HRV-data i intervallet")
    return(ggplot2::ggplot())
  }

  span_days <- .compute_span_days(from, to)
  pt_size  <- if (span_days <= 30) 2 else 0.8
  pt_alpha <- if (span_days <= 30) 0.5 else 0.2

  # 7-day rolling mean and SD
  hrv <- hrv |>
    dplyr::mutate(
      roll_mean = .rolling_mean(ln_rmssd, 7),
      roll_sd   = .rolling_sd(ln_rmssd, 7),
      upper     = roll_mean + roll_sd,
      lower     = roll_mean - roll_sd
    )

  p <- ggplot2::ggplot(hrv, ggplot2::aes(x = date)) +
    ggplot2::geom_ribbon(ggplot2::aes(ymin = lower, ymax = upper),
                         fill = "steelblue", alpha = 0.2, na.rm = TRUE) +
    ggplot2::geom_point(ggplot2::aes(y = ln_rmssd),
                        alpha = pt_alpha, size = pt_size, colour = "grey50") +
    ggplot2::geom_line(ggplot2::aes(y = roll_mean),
                       colour = "steelblue", linewidth = 0.8, na.rm = TRUE) +
    .adaptive_date_scale(span_days) +
    ggplot2::labs(title = "HRV — Ln(RMSSD) med 7-dagars baseline",
                  x = NULL, y = "Ln(RMSSD)") +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        angle = if (span_days <= 60) 45 else 0,
        hjust = if (span_days <= 60) 1 else 0.5)
    )

  p
}

# --- Sleep trend --------------------------------------------------------------

#' Sleep duration trend with stage breakdown
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param from Start date. NULL = all data.
#' @param to End date. NULL = all data.
#' @return ggplot2 object.
#' @export
fetch.plot.sleep <- function(health_daily, from = NULL, to = NULL) {
  sleep_metrics <- c("sleep_core", "sleep_deep", "sleep_rem", "sleep_awake")
  sleep <- health_daily |>
    dplyr::filter(metric %in% c(sleep_metrics, "sleep_totalSleep"))

  if (!is.null(from)) sleep <- sleep |> dplyr::filter(date >= as.Date(from))
  if (!is.null(to))   sleep <- sleep |> dplyr::filter(date < as.Date(to))

  if (nrow(sleep) == 0) {
    message("Ingen sömndata i intervallet")
    return(ggplot2::ggplot())
  }

  span_days <- .compute_span_days(from, to)

  # Total sleep as line
  total <- sleep |> dplyr::filter(metric == "sleep_totalSleep")

  # Stages as stacked area (only where staging exists)
  stages <- sleep |>
    dplyr::filter(metric %in% sleep_metrics, value > 0)

  # Swedish labels and colours
  stage_labels <- c(
    "sleep_deep"  = "Djupsömn",
    "sleep_rem"   = "REM",
    "sleep_core"  = "Kärnsömn",
    "sleep_awake" = "Vaken"
  )
  stage_colours <- c(
    "Djupsömn"  = "#1a3a5c",
    "REM"       = "#4a90d9",
    "Kärnsömn"  = "#7fb3e0",
    "Vaken"     = "#d9534f"
  )

  stages$stage <- factor(stage_labels[stages$metric],
                          levels = c("Vaken", "Kärnsömn", "REM", "Djupsömn"))

  # Adapt loess span to date range
  loess_span <- if (span_days <= 30) 0.75 else if (span_days <= 90) 0.3 else 0.15

  p <- ggplot2::ggplot()

  if (nrow(total) >= 5) {
    p <- p + ggplot2::geom_smooth(data = total,
                                   ggplot2::aes(x = date, y = value),
                                   method = "loess", span = loess_span,
                                   se = FALSE, colour = "grey30", linewidth = 1)
  }

  if (nrow(stages) > 0) {
    # Adaptive aggregation: daily / weekly / monthly
    if (span_days < 60) {
      # Daily bars — show each day individually
      stages_agg <- stages |>
        dplyr::group_by(date, stage) |>
        dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") |>
        dplyr::rename(period = date)
      bar_width <- 0.8
    } else if (span_days < 365) {
      # Weekly bars
      stages_agg <- stages |>
        dplyr::mutate(period = lubridate::floor_date(date, "week")) |>
        dplyr::group_by(period, stage) |>
        dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop")
      bar_width <- 5
    } else {
      # Monthly bars
      stages_agg <- stages |>
        dplyr::mutate(period = lubridate::floor_date(date, "month")) |>
        dplyr::group_by(period, stage) |>
        dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop")
      bar_width <- 25
    }

    p <- p +
      ggplot2::geom_col(data = stages_agg,
                        ggplot2::aes(x = period, y = value, fill = stage),
                        width = bar_width, alpha = 0.7) +
      ggplot2::scale_fill_manual(values = stage_colours)
  }

  p <- p +
    .adaptive_date_scale(span_days) +
    ggplot2::labs(title = "Sömn — total och faser",
                  x = NULL, y = "Timmar", fill = NULL) +
    ggplot2::geom_hline(yintercept = 7, linetype = "dashed",
                        colour = "darkgreen", alpha = 0.5) +
    ggplot2::annotate("text", x = min(total$date), y = 7.15,
                      label = "7h mål", hjust = 0, size = 3,
                      colour = "darkgreen") +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        angle = if (span_days <= 60) 45 else 0,
        hjust = if (span_days <= 60) 1 else 0.5)
    )

  p
}

# --- VO2max trend -------------------------------------------------------------

#' VO2max trend over time
#'
#' Plots Apple Watch VO2max estimates. If \code{summaries} are provided and
#' contain \code{garmin_vO2MaxValue}, overlays Garmin per-activity estimates
#' for a dual-source comparison.
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param summaries Optional Garmin summaries tibble (with garmin_vO2MaxValue).
#' @param from Start date. NULL = all data.
#' @param to End date. NULL = all data.
#' @return ggplot2 object.
#' @export
fetch.plot.vo2max <- function(health_daily, summaries = NULL,
                               from = NULL, to = NULL) {
  vo2 <- health_daily |>
    dplyr::filter(metric == "vo2_max")

  if (!is.null(from)) vo2 <- vo2 |> dplyr::filter(date >= as.Date(from))
  if (!is.null(to))   vo2 <- vo2 |> dplyr::filter(date < as.Date(to))

  # Extract Garmin VO2max from summaries if available
  garmin_vo2 <- NULL
  if (!is.null(summaries) && "garmin_vO2MaxValue" %in% names(summaries)) {
    garmin_vo2 <- summaries |>
      dplyr::filter(!is.na(garmin_vO2MaxValue)) |>
      dplyr::transmute(
        date = as.Date(sessionStart),
        value = garmin_vO2MaxValue
      )
    if (!is.null(from)) garmin_vo2 <- garmin_vo2 |> dplyr::filter(date >= as.Date(from))
    if (!is.null(to))   garmin_vo2 <- garmin_vo2 |> dplyr::filter(date < as.Date(to))
    if (nrow(garmin_vo2) == 0) garmin_vo2 <- NULL
  }

  if (nrow(vo2) == 0 && is.null(garmin_vo2)) {
    message("Ingen VO2max-data i intervallet")
    return(ggplot2::ggplot())
  }

  span_days <- .compute_span_days(from, to)
  pt_size  <- if (span_days <= 30) 2.5 else 0.8
  pt_alpha <- if (span_days <= 30) 0.6 else 0.15
  loess_span <- if (span_days <= 30) 0.75 else if (span_days <= 90) 0.3 else 0.15
  has_both <- nrow(vo2) > 0 && !is.null(garmin_vo2)

  p <- ggplot2::ggplot()

  # Apple Watch series
  if (nrow(vo2) > 0) {
    aw_colour <- if (has_both) "#E69F00" else "grey50"
    p <- p +
      ggplot2::geom_point(data = vo2,
                          ggplot2::aes(x = date, y = value, colour = "Apple Watch"),
                          alpha = pt_alpha, size = pt_size)
    if (nrow(vo2) >= 5) {
      p <- p + ggplot2::geom_smooth(data = vo2,
                                     ggplot2::aes(x = date, y = value),
                                     method = "loess", span = loess_span,
                                     se = FALSE, colour = "#E69F00",
                                     linewidth = 1)
    }
  }

  # Garmin series
  if (!is.null(garmin_vo2)) {
    p <- p +
      ggplot2::geom_point(data = garmin_vo2,
                          ggplot2::aes(x = date, y = value, colour = "Garmin"),
                          alpha = if (span_days <= 30) 0.7 else 0.4,
                          size = if (span_days <= 30) 2.5 else 1.2,
                          shape = 17)
    if (nrow(garmin_vo2) >= 5) {
      p <- p + ggplot2::geom_smooth(data = garmin_vo2,
                                     ggplot2::aes(x = date, y = value),
                                     method = "loess", span = loess_span,
                                     se = FALSE, colour = "#56B4E9",
                                     linewidth = 1)
    }
  }

  title <- if (has_both) "VO2max (Apple Watch + Garmin)" else "VO2max (Apple Watch-estimat)"

  p <- p +
    .adaptive_date_scale(span_days) +
    ggplot2::labs(title = title,
                  x = NULL,
                  y = "ml/(kg\u00b7min)") +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        angle = if (span_days <= 60) 45 else 0,
        hjust = if (span_days <= 60) 1 else 0.5)
    )

  if (has_both) {
    p <- p +
      ggplot2::scale_colour_manual(
        values = c("Apple Watch" = "#E69F00", "Garmin" = "#56B4E9"),
        name = NULL
      ) +
      ggplot2::theme(legend.position = "bottom")
  } else {
    p <- p + ggplot2::guides(colour = "none")
  }

  p
}

# --- Readiness dashboard (combined) ------------------------------------------

#' Combined readiness dashboard: RHR + HRV + Sleep
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param days Number of recent days to show. Default 90.
#' @return ggplot2 object (combined via patchwork if available, else HRV only).
#' @export
fetch.plot.readiness <- function(health_daily, days = 90) {
  from <- Sys.Date() - days

  p_rhr   <- fetch.plot.resting_hr(health_daily, from = from)
  p_hrv   <- fetch.plot.hrv(health_daily, from = from)
  p_sleep <- fetch.plot.sleep(health_daily, from = from)

  if (requireNamespace("patchwork", quietly = TRUE)) {
    p_rhr / p_hrv / p_sleep +
      patchwork::plot_annotation(
        title = paste("Readiness —", days, "dagar"),
        theme = ggplot2::theme(plot.title = ggplot2::element_text(
          size = 16, face = "bold"))
      )
  } else {
    message("Installera 'patchwork' f\u00f6r kombinerad vy. Visar HRV.")
    p_hrv
  }
}

# --- Integrated readiness score dashboard -------------------------------------

#' Readiness score dashboard with composite score, HRV, sleep, and training load
#'
#' @param health_daily Long-format tibble from \code{load_health_data()}.
#' @param summaries Garmin summaries tibble.
#' @param hr_max Optional HRmax override.
#' @param hr_rest Optional HRrest override.
#' @param from Start date. NULL uses \code{days}.
#' @param to End date. NULL = today.
#' @param days Number of recent days if from/to not specified. Default 90.
#' @return ggplot2 object (patchwork composite).
#' @export
fetch.plot.readiness_score <- function(health_daily, summaries,
                                        hr_max = NULL, hr_rest = NULL,
                                        from = NULL, to = NULL,
                                        days = 90) {
  if (is.null(from)) from <- Sys.Date() - days
  if (is.null(to))   to   <- Sys.Date()

  r <- compute_readiness(health_daily, summaries,
                          hr_max = hr_max, hr_rest = hr_rest,
                          after = from, before = to)

  if (nrow(r) == 0) {
    message("Ingen readiness-data i intervallet")
    return(ggplot2::ggplot())
  }

  if (!requireNamespace("patchwork", quietly = TRUE)) {
    message("Installera 'patchwork' f\u00f6r readiness-dashboard")
    return(ggplot2::ggplot())
  }

  span_days <- .compute_span_days(from, to)
  date_scale <- .adaptive_date_scale(span_days)
  pt_size  <- if (span_days <= 30) 2.5 else 1.5

  theme_panel <- ggplot2::theme_minimal() +
    ggplot2::theme(axis.title.x = ggplot2::element_blank(),
                   plot.title = ggplot2::element_text(size = 10, face = "bold"),
                   axis.text.x = ggplot2::element_text(
                     angle = if (span_days <= 60) 45 else 0,
                     hjust = if (span_days <= 60) 1 else 0.5))

  # Panel 1: Readiness score
  r_score <- r |> dplyr::filter(!is.na(readiness_score))
  p1 <- ggplot2::ggplot(r_score, ggplot2::aes(x = date, y = readiness_score)) +
    ggplot2::annotate("rect", xmin = min(r$date), xmax = max(r$date),
                      ymin = 70, ymax = 100, fill = "#4CAF50", alpha = 0.1) +
    ggplot2::annotate("rect", xmin = min(r$date), xmax = max(r$date),
                      ymin = 40, ymax = 70, fill = "#FFC107", alpha = 0.1) +
    ggplot2::annotate("rect", xmin = min(r$date), xmax = max(r$date),
                      ymin = 0, ymax = 40, fill = "#F44336", alpha = 0.1) +
    ggplot2::geom_line(colour = "grey40", linewidth = 0.4) +
    ggplot2::geom_point(ggplot2::aes(colour = readiness_status), size = pt_size) +
    ggplot2::scale_colour_manual(
      values = c("Grön" = "#4CAF50", "Gul" = "#FFC107",
                 "Röd" = "#F44336"),
      guide = "none"
    ) +
    ggplot2::geom_hline(yintercept = c(40, 70), linetype = "dashed",
                        alpha = 0.3) +
    ggplot2::scale_y_continuous(limits = c(0, 100)) +
    date_scale +
    ggplot2::labs(title = "Beredskap", y = "Po\u00e4ng") +
    theme_panel

  # Panel 2: HRV with baseline band
  r_hrv <- r |> dplyr::filter(!is.na(ln_rmssd))
  p2 <- ggplot2::ggplot(r_hrv, ggplot2::aes(x = date)) +
    ggplot2::geom_ribbon(
      ggplot2::aes(ymin = ln_rmssd_7d_mean - ln_rmssd_7d_sd,
                   ymax = ln_rmssd_7d_mean + ln_rmssd_7d_sd),
      fill = "steelblue", alpha = 0.2, na.rm = TRUE) +
    ggplot2::geom_point(ggplot2::aes(y = ln_rmssd),
                        alpha = if (span_days <= 30) 0.5 else 0.3,
                        size = if (span_days <= 30) 2 else 0.8,
                        colour = "grey50") +
    ggplot2::geom_line(ggplot2::aes(y = ln_rmssd_7d_mean),
                       colour = "steelblue", linewidth = 0.7, na.rm = TRUE) +
    ggplot2::geom_point(
      data = r_hrv |> dplyr::filter(hrv_flag),
      ggplot2::aes(y = ln_rmssd), colour = "red", shape = 17, size = 2) +
    date_scale +
    ggplot2::labs(title = "HRV — Ln(RMSSD)", y = "Ln(RMSSD)") +
    theme_panel

  # Panel 3: Sleep
  r_sleep <- r |> dplyr::filter(!is.na(sleep_total))
  p3 <- ggplot2::ggplot(r_sleep, ggplot2::aes(x = date, y = sleep_total)) +
    ggplot2::geom_col(
      ggplot2::aes(fill = ifelse(sleep_flag, "Flaggad", "Normal")),
      width = 0.8, alpha = 0.7) +
    ggplot2::scale_fill_manual(
      values = c("Normal" = "steelblue", "Flaggad" = "#F44336"),
      guide = "none") +
    ggplot2::geom_hline(yintercept = 7, linetype = "dashed",
                        colour = "darkgreen", alpha = 0.5) +
    date_scale +
    ggplot2::labs(title = "S\u00f6mn", y = "Timmar") +
    theme_panel

  # Panel 4: Training load
  r_load <- r |> dplyr::filter(!is.na(daily_trimp) | !is.na(atl))
  p4 <- ggplot2::ggplot(r_load, ggplot2::aes(x = date)) +
    ggplot2::geom_col(ggplot2::aes(y = daily_trimp),
                      fill = "grey70", alpha = 0.5, width = 0.8) +
    ggplot2::geom_line(ggplot2::aes(y = atl, colour = "ATL"),
                       linewidth = 0.7, na.rm = TRUE) +
    ggplot2::geom_line(ggplot2::aes(y = ctl, colour = "CTL"),
                       linewidth = 0.7, na.rm = TRUE) +
    ggplot2::scale_colour_manual(values = c("ATL" = "tomato", "CTL" = "steelblue")) +
    date_scale +
    ggplot2::labs(title = "Tr\u00e4ningsbelastning", y = "TRIMP",
                  colour = NULL) +
    theme_panel +
    ggplot2::theme(legend.position = "bottom",
                   legend.key.size = ggplot2::unit(0.4, "cm"))

  # Combine
  p1 / p2 / p3 / p4 +
    patchwork::plot_layout(heights = c(2, 1.5, 1, 1.5)) +
    patchwork::plot_annotation(
      title = paste("Readiness-dashboard —",
                    format(from, "%Y-%m-%d"), "till",
                    format(to, "%Y-%m-%d")),
      theme = ggplot2::theme(
        plot.title = ggplot2::element_text(size = 14, face = "bold"))
    )
}
