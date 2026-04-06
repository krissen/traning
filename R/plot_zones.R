# HR zone visualizations — each returns a ggplot2 object
# Requires: compute_zone_distribution(), compute_polarization_index(),
#           cross_validate_zones() from R/hr_zones.R

# Auto-select date breaks to avoid label overlap
.auto_date_breaks <- function(dates) {
  span_days <- as.numeric(diff(range(dates, na.rm = TRUE)))
  if (span_days > 365 * 10) return("2 years")
  if (span_days > 365 * 4)  return("1 year")
  if (span_days > 365 * 2)  return("6 months")
  "3 months"
}

#' Stacked bar chart of Seiler 3-zone distribution over time
#'
#' Aggregates training time into Seiler's three intensity zones (low,
#' threshold, high) and shows the monthly percentage distribution as a
#' stacked bar chart.  A horizontal reference line at 80 % marks the
#' target proportion for the low-intensity zone recommended in polarised
#' training models (Seiler 2010).
#'
#' Calls \code{compute_zone_distribution()} internally (from
#' \code{R/hr_zones.R}).  The function expects a \code{$monthly} element
#' in the returned list containing at least the columns
#' \code{year_month}, \code{z1_pct}, \code{z2_pct}, \code{z3_pct},
#' \code{n_activities}, and \code{total_min}.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param from Date or NULL. Start of display window.
#' @param to Date or NULL. End of display window.
#' @param by Character. Aggregation level — currently only \code{"monthly"}
#'   is supported.
#' @return ggplot2 object.
#' @export
fetch.plot.hr_zones <- function(summaries, from = NULL, to = NULL,
                                by = "monthly", zone_data = NULL) {
  if (is.null(zone_data)) zone_data <- compute_zone_distribution(summaries)
  monthly   <- zone_data$monthly

  # Optional date-range pre-filter — year_month is "YYYY-MM" character,

  # convert to first-of-month Date for comparison
  if (!is.null(from)) {
    monthly <- monthly %>%
      dplyr::filter(as.Date(paste0(year_month, "-01")) >= as.Date(from))
  }
  if (!is.null(to)) {
    monthly <- monthly %>%
      dplyr::filter(as.Date(paste0(year_month, "-01")) <= as.Date(to))
  }

  # Pivot to long format so ggplot2 can stack the three zones
  long <- monthly %>%
    tidyr::pivot_longer(
      cols      = c(z1_pct, z2_pct, z3_pct),
      names_to  = "zon",
      values_to = "pct"
    ) %>%
    dplyr::mutate(
      zon = dplyr::recode(zon,
        z1_pct = "L\u00e5gintensiv (Z1)",
        z2_pct = "Tr\u00f6skel (Z2)",
        z3_pct = "H\u00f6gintensiv (Z3)"
      ),
      zon = factor(zon,
        levels = c("L\u00e5gintensiv (Z1)", "Tr\u00f6skel (Z2)", "H\u00f6gintensiv (Z3)")
      ),
      year_month = as.Date(paste0(year_month, "-01"))
    )

  zon_farger <- c(
    "L\u00e5gintensiv (Z1)" = "#27ae60",
    "Tr\u00f6skel (Z2)"     = "#f1c40f",
    "H\u00f6gintensiv (Z3)" = "#e74c3c"
  )

  long %>%
    ggplot2::ggplot(
      ggplot2::aes(x = year_month, y = pct, fill = zon)
    ) +
    ggplot2::geom_col(
      position = ggplot2::position_stack(reverse = TRUE),
      width     = 25
    ) +
    # 80 % reference line for ideal Z1 proportion
    ggplot2::geom_hline(
      yintercept = 80,
      colour     = "grey30",
      linetype   = "dashed",
      linewidth  = 0.5
    ) +
    ggplot2::annotate(
      "text",
      x     = min(long$year_month, na.rm = TRUE),
      y     = 81.5,
      label = "80 % m\u00e5l",
      hjust = 0,
      size  = 3,
      colour = "grey30"
    ) +
    ggplot2::scale_fill_manual(
      name   = "Intensitetszon",
      values = zon_farger
    ) +
    ggplot2::scale_y_continuous(
      labels = function(x) paste0(x, " %")
    ) +
    ggplot2::coord_cartesian(ylim = c(0, 100)) +
    ggplot2::scale_x_date(
      date_labels = "%Y-%m",
      date_breaks = .auto_date_breaks(long$year_month)
    ) +
    ggplot2::ggtitle("Zonf\u00f6rdelning per m\u00e5nad (Seiler 3-zon)") +
    ggplot2::labs(x = NULL, y = "Andel (%)") +
    ggplot2::theme(
      axis.text.x     = ggplot2::element_text(angle = 45, hjust = 1),
      legend.position = "bottom"
    ) -> p
  return(p)
}

#' Line plot of Polarization Index trend
#'
#' Shows the Polarization Index (PI) over time with a LOESS smoother and
#' colour-coded background bands indicating training character:
#' non-polarised (PI < 1.0), moderately polarised (1.0-2.0), and polarised
#' (PI > 2.0) following Treff et al. (2019).
#'
#' Calls \code{compute_zone_distribution()} and then
#' \code{compute_polarization_index()} internally.  The latter is expected
#' to return a tibble with at least the columns \code{year_month},
#' \code{pi}, \code{z1_pct}, \code{z2_pct}, \code{z3_pct}, and
#' \code{n_activities}.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param from Date or NULL. Start of display window.
#' @param to Date or NULL. End of display window.
#' @return ggplot2 object.
#' @export
fetch.plot.polarization <- function(summaries, from = NULL, to = NULL,
                                    zone_data = NULL) {
  if (is.null(zone_data)) zone_data <- compute_zone_distribution(summaries)
  pi_data   <- compute_polarization_index(zone_data)

  pi_data <- pi_data %>%
    dplyr::mutate(year_month = as.Date(paste0(year_month, "-01"))) %>%
    dplyr::filter(!is.na(pi))

  if (!is.null(from)) {
    pi_data <- pi_data %>% dplyr::filter(year_month >= as.Date(from))
  }
  if (!is.null(to)) {
    pi_data <- pi_data %>% dplyr::filter(year_month <= as.Date(to))
  }

  # Determine x limits for background rectangles
  x_min <- min(pi_data$year_month, na.rm = TRUE)
  x_max <- max(pi_data$year_month, na.rm = TRUE)

  pi_data %>%
    ggplot2::ggplot(ggplot2::aes(x = year_month, y = pi)) +
    # Background bands: Treff 2019 cutoff at PI = 2.0
    ggplot2::annotate("rect",
      xmin = x_min, xmax = x_max, ymin = -Inf,  ymax = 2.0,
      fill = "#f1c40f", alpha = 0.06
    ) +
    ggplot2::annotate("rect",
      xmin = x_min, xmax = x_max, ymin = 2.0,   ymax = Inf,
      fill = "#27ae60", alpha = 0.06
    ) +
    # Band labels
    ggplot2::annotate("text",
      x = x_max, y = 1.0,
      label  = "Icke\u2011polariserad",
      hjust  = 1, vjust = 0.5, size = 3, colour = "#b7950b"
    ) +
    ggplot2::annotate("text",
      x = x_max, y = 2.5,
      label  = "Polariserad",
      hjust  = 1, vjust = 0.5, size = 3, colour = "#1e8449"
    ) +
    # Horizontal reference line at PI = 2.0 (Treff 2019 cutoff)
    ggplot2::geom_hline(
      yintercept = 2.0,
      colour     = "grey60",
      linetype   = "dotted",
      linewidth  = 0.5
    ) +
    # Main PI line
    ggplot2::geom_line(
      colour    = "steelblue",
      linewidth = 0.9,
      na.rm     = TRUE
    ) +
    # LOESS smoother
    ggplot2::geom_smooth(
      method    = "loess",
      formula   = "y ~ x",
      colour    = "grey40",
      linetype  = "dashed",
      se        = FALSE,
      linewidth = 0.7,
      na.rm     = TRUE
    ) +
    ggplot2::scale_x_date(
      date_labels = "%Y-%m",
      date_breaks = .auto_date_breaks(pi_data$year_month)
    ) +
    ggplot2::ggtitle("Polariseringsindex (Treff 2019)") +
    ggplot2::labs(x = NULL, y = "PI") +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1)
    ) -> p
  return(p)
}

#' Scatter plot cross-validating Garmin and per-second HR zones
#'
#' Compares the zone percentages derived from Garmin Connect JSON
#' (pre-computed on the device) against per-second zone assignments
#' computed from raw FIT data.  Each point is one activity; the diagonal
#' identity line represents perfect agreement.  Facets show Z1, Z2, and Z3
#' side by side.  Points are coloured by the absolute percentage-point
#' deviation between the two sources.
#'
#' Calls \code{cross_validate_zones()} internally (from
#' \code{R/hr_zones.R}).
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param myruns List of per-second run data frames (from
#'   \code{my_dbs_load()}).
#' @param from Date or NULL. Filter activities starting from this date.
#' @param to Date or NULL. Filter activities up to this date.
#' @return ggplot2 object.
#' @export
fetch.plot.zone_comparison <- function(summaries, myruns,
                                       from = NULL, to = NULL) {
  cv_data <- cross_validate_zones(summaries, myruns)

  if (!is.null(from)) {
    cv_data <- cv_data %>% dplyr::filter(as.Date(sessionStart) >= as.Date(from))
  }
  if (!is.null(to)) {
    cv_data <- cv_data %>% dplyr::filter(as.Date(sessionStart) <= as.Date(to))
  }

  # Pivot to long format — one row per activity × zone
  long <- cv_data %>%
    tidyr::pivot_longer(
      cols      = c(
        dplyr::starts_with("garmin_z"),
        dplyr::starts_with("persec_z")
      ),
      names_to  = "kalla_zon",
      values_to = "pct"
    ) %>%
    dplyr::mutate(
      kalla = dplyr::if_else(
        stringr::str_starts(kalla_zon, "garmin"), "Garmin", "Persec"
      ),
      zon = dplyr::case_when(
        stringr::str_detect(kalla_zon, "z1") ~ "Z1",
        stringr::str_detect(kalla_zon, "z2") ~ "Z2",
        stringr::str_detect(kalla_zon, "z3") ~ "Z3",
        TRUE                                  ~ NA_character_
      )
    ) %>%
    dplyr::filter(!is.na(zon)) %>%
    tidyr::pivot_wider(
      id_cols     = c(sessionStart, zon),
      names_from  = kalla,
      values_from = pct
    ) %>%
    dplyr::mutate(
      avvikelse = abs(Garmin - Persec),
      zon = factor(zon, levels = c("Z1", "Z2", "Z3"))
    )

  long %>%
    ggplot2::ggplot(
      ggplot2::aes(x = Garmin, y = Persec, colour = avvikelse)
    ) +
    # Identity line (perfect agreement)
    ggplot2::geom_abline(
      intercept = 0,
      slope     = 1,
      colour    = "grey40",
      linetype  = "dashed",
      linewidth = 0.5
    ) +
    ggplot2::geom_point(alpha = 0.7, size = 1.8) +
    ggplot2::scale_colour_gradient(
      name = "Avvikelse\n(%-enheter)",
      low  = "#27ae60",
      high = "#e74c3c"
    ) +
    ggplot2::facet_wrap(
      ggplot2::vars(zon),
      nrow = 1,
      labeller = ggplot2::labeller(
        zon = c(Z1 = "Z1 \u2014 L\u00e5gintensiv",
                Z2 = "Z2 \u2014 Tr\u00f6skel",
                Z3 = "Z3 \u2014 H\u00f6gintensiv")
      )
    ) +
    ggplot2::scale_x_continuous(
      labels = function(x) paste0(x, " %"),
      limits = c(0, 100)
    ) +
    ggplot2::scale_y_continuous(
      labels = function(x) paste0(x, " %"),
      limits = c(0, 100)
    ) +
    ggplot2::ggtitle("Korsvalidering: Garmin vs ber\u00e4knade zoner") +
    ggplot2::labs(
      x = "Garmin (%)",
      y = "Ber\u00e4knad per sek. (%)"
    ) +
    ggplot2::theme(
      strip.text      = ggplot2::element_text(face = "bold"),
      legend.position = "right"
    ) -> p
  return(p)
}
