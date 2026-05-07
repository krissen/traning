# Tests for R/plot_multisport.R

.fixture_multisport_plots <- function() {
  base <- as.POSIXct("2026-01-01 08:00:00", tz = "UTC")
  data.frame(
    sessionStart = base + (0:23) * 86400 * 7,  # weekly for 24 weeks
    sport = rep(c("running", "cycling", "walking", "strength"), 6),
    distance = rep(c(8000, 25000, 4000, 0), 6),
    durationMoving = as.difftime(rep(c(40, 60, 30, 45), 6), units = "mins"),
    avgSpeedMoving = rep(c(3.3, 6.9, 2.2, 0), 6),
    avgPaceMoving = rep(c(5.0, 2.4, 7.6, NA), 6),
    avgHeartRateMoving = rep(c(140, 130, 95, 120), 6),
    duration = as.difftime(rep(c(40, 60, 30, 45), 6), units = "mins"),
    stringsAsFactors = FALSE
  )
}

# --- .sport_mix_data --------------------------------------------------------

test_that(".sport_mix_data aggregates per period × sport", {
  df <- .fixture_multisport_plots()
  res <- traning:::.sport_mix_data(df, period_fmt = "%Y-%m")
  expect_s3_class(res, "data.frame")
  expect_named(res, c("period", "sport", "km"))
  # 4 sports × ~6 months = up to 24 cells, but strength has 0 km so
  # gets filtered out via min_km = 0.1.
  expect_setequal(unique(res$sport), c("running", "cycling", "walking"))
  expect_true(all(res$km >= 0.1))
})

test_that(".sport_mix_data respects min_km filter", {
  df <- .fixture_multisport_plots()
  # Set the bar very high so no sport survives
  res <- traning:::.sport_mix_data(df, period_fmt = "%Y-%m", min_km = 1e6)
  expect_equal(nrow(res), 0)
})

test_that(".sport_mix_data returns empty tibble on empty input", {
  res <- traning:::.sport_mix_data(NULL)
  expect_equal(nrow(res), 0)
  expect_named(res, c("period", "sport", "km"))
})

# --- plot_sport_mix ---------------------------------------------------------

test_that("plot_sport_mix returns a ggplot for valid input", {
  df <- .fixture_multisport_plots()
  p <- plot_sport_mix(df, period = "month")
  expect_s3_class(p, "ggplot")
})

test_that("plot_sport_mix accepts week and year period", {
  df <- .fixture_multisport_plots()
  expect_s3_class(plot_sport_mix(df, period = "week"), "ggplot")
  expect_s3_class(plot_sport_mix(df, period = "year"), "ggplot")
})

test_that("plot_sport_mix rejects unknown period values", {
  df <- .fixture_multisport_plots()
  expect_error(plot_sport_mix(df, period = "decade"), "period")
})

test_that("plot_sport_mix returns a placeholder ggplot when no data", {
  empty <- .fixture_multisport_plots()[0, ]
  p <- plot_sport_mix(empty)
  expect_s3_class(p, "ggplot")
})

# --- plot_sport_ctl_overlay -------------------------------------------------

test_that("plot_sport_ctl_overlay produces a ggplot across sports", {
  df <- .fixture_multisport_plots()
  p <- plot_sport_ctl_overlay(df, sports = c("running", "cycling", "all"))
  expect_s3_class(p, "ggplot")
})

test_that("plot_sport_ctl_overlay rejects empty sports", {
  df <- .fixture_multisport_plots()
  expect_error(plot_sport_ctl_overlay(df, sports = character(0)), "sport")
})

# --- plot_sport_calendar ----------------------------------------------------

test_that("plot_sport_calendar returns a ggplot heatmap", {
  df <- .fixture_multisport_plots()
  p <- plot_sport_calendar(df,
                            from = as.Date("2026-01-01"),
                            to = as.Date("2026-06-30"))
  expect_s3_class(p, "ggplot")
})

test_that("plot_sport_calendar handles empty input gracefully", {
  empty <- .fixture_multisport_plots()[0, ]
  p <- plot_sport_calendar(empty,
                            from = as.Date("2026-01-01"),
                            to = as.Date("2026-01-31"))
  expect_s3_class(p, "ggplot")
})

test_that("plot_sport_calendar default window is one year", {
  df <- .fixture_multisport_plots()
  p <- plot_sport_calendar(df)  # default from/to → today minus 365
  expect_s3_class(p, "ggplot")
})

test_that("plot_sport_calendar treats 'to' as exclusive upper bound", {
  # The MCP bridge already converts a user-facing inclusive `before`
  # into an exclusive `to = before + 1 day` via _build_args. Adding
  # another +1 day here would overshoot the requested window — reject
  # that regression by asserting that `to_d` equals the passed `to`
  # less one day in the title.
  df <- .fixture_multisport_plots()
  to_excl <- as.Date("2026-04-08")
  p <- plot_sport_calendar(df,
                            from = as.Date("2026-01-01"),
                            to = to_excl)
  expect_s3_class(p, "ggplot")
  expect_true(grepl("2026-04-07", p$labels$title))
  expect_false(grepl("2026-04-08", p$labels$title))
})

test_that(".relabel_sport handles NA without crashing", {
  # Calendar rest days end up as NA after left_join; .relabel_sport()
  # used to crash inside .sport_label_sv(NA).
  out <- traning:::.relabel_sport(c("running", NA, "cycling"))
  expect_equal(unname(out), c("Löpning", NA_character_, "Cykling"))
})

test_that("plot_sport_calendar colours zero-distance gym days", {
  # Regression: .sport_mix_data dropped 0-km buckets which made the
  # calendar treat strength sessions as rest days. The calendar now
  # passes min_km=0 so gym days surface as their own colour cell.
  base <- as.POSIXct("2026-04-22 08:00:00", tz = "UTC")
  s <- tibble::tibble(
    sessionStart = c(base, base + as.difftime(1, units = "days")),
    sport = c("running", "strength"),
    distance = c(8000, 0)
  )
  p <- plot_sport_calendar(s,
                            from = as.Date("2026-04-22"),
                            to = as.Date("2026-04-25"))
  expect_s3_class(p, "ggplot")
  # The plot data should include strength as a labelled (non-NA) row
  layer <- p$data
  expect_true(any(!is.na(layer$sport_sv) & layer$sport_sv == "Styrketräning"))
})
