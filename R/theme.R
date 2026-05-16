# Unified visual theme for tRäning plots.
#
# Source of truth: app/tRanat/www/styles.css (the Shiny app's CSS custom
# properties define the look-and-feel). This file mirrors the relevant
# variables for use in ggplot output (CLI PNG renders + Shiny plots).
#
# If a CSS variable in styles.css changes, update the matching hex below
# in the same commit. Layout:
#
#   styles.css                          this file
#   --primary:     #3e2723   →  traning_palette$primary
#   --secondary:   #6d4c41   →  traning_palette$secondary
#   --accent:      #8d6e63   →  traning_palette$accent
#   --accent-warm: #c8a882   →  traning_palette$accent_warm
#   --bg-card:     #faf8f5   →  traning_palette$bg_card
#   --text-dark:   #2c2013   →  traning_palette$text_dark
#   --border-warm: #d4c8b8   →  traning_palette$border_warm
#   --status-green:#5a8a5a   →  traning_palette$status[["green"]]
#   --status-yellow:#b8963a  →  traning_palette$status[["yellow"]]
#   --status-red:  #a85a4a   →  traning_palette$status[["red"]]
#   --status-blue: #5a7a9a   →  traning_palette$status[["blue"]]
#
# Sub-palettes below (zones, traffic, traffic_bg, sleep_stages, seasons,
# run_profile) intentionally diverge from CSS. Each carries an
# AVVIKELSE FRÅN TEMA comment explaining why.

#' Palette for tRäning plots
#'
#' Named list mirroring the Shiny app's CSS custom properties, plus
#' sub-palettes for domain-specific colour needs (HR zones, traffic-light
#' semantics, sleep stages, seasonal backgrounds, run-profile contrast).
#'
#' Use these instead of hardcoded hex literals in plot code. The only
#' acceptable inline hex is one marked with an `AVVIKELSE FRÅN TEMA`
#' comment explaining the reason.
#'
#' @export
traning_palette <- list(
  # CSS --accent: warm brown for single-series bars
  accent = "#8d6e63",
  # CSS --primary: dark brown for axes, dark series anchors
  primary = "#3e2723",
  # CSS --secondary: medium brown
  secondary = "#6d4c41",
  # CSS --accent-warm: light cream-brown
  accent_warm = "#c8a882",
  # CSS --border-warm: soft warm border tone
  border_warm = "#d4c8b8",
  # CSS --bg-card: card background (used in Shiny mini-charts)
  bg_card = "#faf8f5",
  # CSS --text-dark: deep brown body text
  text_dark = "#2c2013",

  # CSS --status-*: muted semantics (matches bslib theme in app.R:37-44)
  status = c(
    green  = "#5a8a5a",
    yellow = "#b8963a",
    red    = "#a85a4a",
    blue   = "#5a7a9a"
  ),

  # AVVIKELSE FRÅN TEMA: HR zones use saturated training-convention colours
  # (blue/green/yellow/orange/red) so they read as zone semantics, not
  # ornament. Same convention as Garmin/TrainingPeaks visualisations.
  zones = c(
    Z1 = "#3498db",
    Z2 = "#27ae60",
    Z3 = "#f1c40f",
    Z4 = "#e67e22",
    Z5 = "#e74c3c"
  ),

  # AVVIKELSE FRÅN TEMA: pace traffic-light (lugn/medium/snabb) is
  # semantic, not decorative. Muted earth tones to stay reasonably on
  # palette while still reading as a gradient.
  traffic = c(
    calm   = "#5E9C7A",
    medium = "#E0B45A",
    fast   = "#C0392B"
  ),

  # AVVIKELSE FRÅN TEMA: PMC zone backgrounds use saturated traffic-light
  # so ACWR / TSB / readiness panels signal status at a glance. Status
  # palette would be too muted for full-panel background fills.
  traffic_bg = c(
    green  = "#27ae60",
    yellow = "#f1c40f",
    orange = "#e67e22",
    red    = "#e74c3c"
  ),

  # AVVIKELSE FRÅN TEMA: pastel backgrounds for readiness mini-charts in
  # Shiny — saturated would compete with the foreground line. These are
  # desaturated tints of the traffic-light semantics above.
  readiness_bg = c(
    high   = "#e8f0e8",
    medium = "#f5f0e0",
    low    = "#f0e8e6"
  ),

  # AVVIKELSE FRÅN TEMA: sleep stages map to a deep→light blue gradient
  # (deep/core/REM) plus red for wake. Domain convention from Withings,
  # Garmin Connect, Apple Health.
  sleep_stages = c(
    deep  = "#1a3a5c",
    core  = "#4a90d9",
    rem   = "#7fb3e0",
    awake = "#d9534f"
  ),

  # AVVIKELSE FRÅN TEMA: seasonal background bands in
  # plot_distance_pace_era. Muted tints aligned with winter/spring/
  # summer/autumn intuition (blue/green/yellow/orange).
  seasons = c(
    winter = "#D7E5F2",
    spring = "#DDEED6",
    summer = "#FFF4D6",
    autumn = "#EFD9C2"
  ),

  # AVVIKELSE FRÅN TEMA: run-profile uses a terracotta/steelblue
  # contrast pair so current period reads against the multi-year
  # backdrop. Two browns would smear together in density overlays.
  run_profile = list(
    current = "#C97B4A",  # terracotta for current period
    history = "#4682B4",  # steelblue for historical backdrop
    fill = list(
      light  = "#FFE082",
      dark   = "#7B5C00",
      darker = "#5C4400",
      bg     = "#FFFBEB"
    )
  ),

  # AVVIKELSE FRÅN TEMA: ordered green gradient for duration-rank
  # heatmaps (light=short, dark=long). Hue chosen for legibility on the
  # warm-brown background of the rest of the app.
  duration_rank = c("#1F4D33", "#3F7D5C", "#6FA887", "#9CC1A8", "#CFE0D5"),

  # Ordered categorical palette for stacked / grouped bars. Brown ramp
  # from --primary through --accent-warm to --border-warm; stays on
  # CSS theme.
  sequence = c("#3e2723", "#6d4c41", "#8d6e63", "#c8a882", "#d4c8b8")
)

#' ggplot theme for tRäning plots
#'
#' Built on `ggplot2::theme_minimal()`. Removes minor gridlines, bolds
#' titles and facet strips, mutes the subtitle. Set `rotated_x = TRUE`
#' for category x-axes that need angled labels (year/month strings).
#'
#' This replaces the previous private helpers `.theme_run_profile()`
#' (R/plot.R) and `.theme_rotated_x()` (R/plot_reports.R), which now
#' delegate here.
#'
#' @param base_size Base font size, passed to `theme_minimal()`.
#' @param rotated_x If `TRUE`, rotate x-axis labels 45° with hjust=1.
#' @param angle When `rotated_x = TRUE`, the rotation angle.
#' @return A ggplot2 theme object.
#' @export
theme_traning <- function(base_size = 12, rotated_x = FALSE, angle = 45) {
  th <- ggplot2::theme_minimal(base_size = base_size) +
    ggplot2::theme(
      plot.title    = ggplot2::element_text(face = "bold"),
      plot.subtitle = ggplot2::element_text(colour = "grey40"),
      panel.grid.minor = ggplot2::element_blank(),
      strip.text    = ggplot2::element_text(face = "bold")
    )
  if (isTRUE(rotated_x)) {
    th <- th + ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = angle, hjust = 1)
    )
  }
  th
}

#' Discrete fill scale using `traning_palette$sequence`
#'
#' @param ... Passed to `ggplot2::scale_fill_manual()`.
#' @export
scale_fill_traning <- function(...) {
  ggplot2::scale_fill_manual(values = unname(traning_palette$sequence), ...)
}

#' Discrete colour scale using `traning_palette$sequence`
#'
#' @param ... Passed to `ggplot2::scale_colour_manual()`.
#' @export
scale_colour_traning <- function(...) {
  ggplot2::scale_colour_manual(values = unname(traning_palette$sequence), ...)
}

# Back-compat wrapper. .theme_run_profile() callsites in R/plot.R
# stay untouched during migration; the implementation now delegates.
.theme_run_profile <- function() theme_traning(base_size = 12)

# Back-compat wrapper. .theme_rotated_x() in R/plot_reports.R stays
# untouched; implementation delegates here. `size` arg preserved for
# callers that pass it.
.theme_rotated_x <- function(angle = 45, size = NULL) {
  th <- ggplot2::theme(
    axis.text.x = ggplot2::element_text(angle = angle, hjust = 1, size = size)
  )
  th
}
