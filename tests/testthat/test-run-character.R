# Build-time smoke tests for the Löpprofil tab plots.
# Goal: every fetch.plot.* in the run-profile family returns a ggplot on a
# realistic-enough fixture (multi-year, varied pace + distance).

.fixture_run_profile <- function(n_years = 6, runs_per_year = 60,
                                  seed = 17) {
  set.seed(seed)
  start <- as.POSIXct("2018-01-08 07:30:00", tz = "UTC")
  n <- n_years * runs_per_year
  # Spread sessionStarts roughly evenly across the n_years window.
  step_secs <- (n_years * 365.25 * 86400) / n
  ss <- start + (seq_len(n) - 1) * step_secs

  # Pace drifts a bit year over year so tertile/era plots have variance.
  year <- as.integer(format(ss, "%Y"))
  base_pace <- 5.5 - (year - min(year)) * 0.08
  pace <- pmin(pmax(base_pace + stats::rnorm(n, 0, 0.6), 3), 9)

  # Km: most runs 5-12 km, a handful of long runs per year.
  km <- pmax(stats::rnorm(n, 8.5, 4.0), 1.5)
  long_idx <- sample(seq_len(n), size = n_years * 3)
  km[long_idx] <- stats::runif(length(long_idx), 25, 55)
  distance <- km * 1000

  dur_min <- km * pace
  data.frame(
    sessionStart      = ss,
    sport             = "running",
    distance          = distance,
    durationMoving    = as.difftime(dur_min, units = "mins"),
    avgPaceMoving     = pace,
    avgHeartRateMoving = round(stats::runif(n, 130, 175)),
    avgSpeedMoving    = 1 / (pace / 60) * (1000/1000),
    duration          = as.difftime(dur_min, units = "mins"),
    stringsAsFactors  = FALSE
  )
}

# expect_s3_class confirms the function returned a ggplot object, but
# many scale/stat errors only surface at render time. ggplot_build()
# forces the layers and scales to evaluate, catching e.g. invalid
# breaks, NA-only inputs to stats, or unsupported aesthetics.
#
# suppressMessages() absorbs informational notes that some geoms emit
# (e.g. ggridges' "Picking joint bandwidth of …"); we only want
# warnings and errors to fail the test.
.expect_renders <- function(p) {
  expect_s3_class(p, "ggplot")
  expect_no_warning(suppressMessages(ggplot2::ggplot_build(p)))
}

test_that("fetch.plot.pace_year builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.pace_year(df))
})

test_that("fetch.plot.pace_year_ridges builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.pace_year_ridges(df))
})

test_that("fetch.plot.pace_tertile_share builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.pace_tertile_share(df))
})

test_that("fetch.plot.longest_runs_year builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.longest_runs_year(df))
})

test_that("fetch.plot.season_pace builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.season_pace(df))
})

test_that("fetch.plot.heatmap_km builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.heatmap_km(df))
})

test_that("fetch.plot.cumulative_km builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.cumulative_km(df))
})

test_that("fetch.plot.distance_pace_era builds and renders", {
  df <- .fixture_run_profile()
  .expect_renders(fetch.plot.distance_pace_era(df))
})

test_that("run-profile plots return empty-state when filter strips data", {
  df <- .fixture_run_profile()
  # Future window with no rows
  p <- fetch.plot.pace_year(df, from = "2100-01-01", to = "2100-12-31")
  expect_s3_class(p, "ggplot")
  p2 <- fetch.plot.cumulative_km(df, from = "2100-01-01", to = "2100-12-31")
  expect_s3_class(p2, "ggplot")
})

# Regression: distance_pace_era is rendered through plotly::ggplotly() in
# page_runprofile.R (use_plotly = TRUE). plotly silently drops layers
# from unsupported geoms (geom_hex, geom_bin2d) — the panels render
# blank in the dashboard. Lock in geom_tile (the supported equivalent
# we pre-bin into) so a regression to an unsupported geom is caught.
test_that("fetch.plot.distance_pace_era converts to plotly without dropping the density layer", {
  skip_if_not_installed("plotly")
  df <- .fixture_run_profile()
  p <- fetch.plot.distance_pace_era(df)
  unsupported_warnings <- character()
  pp <- withCallingHandlers(
    plotly::ggplotly(p),
    warning = function(w) {
      if (grepl("yet to be implemented in plotly", w$message, fixed = TRUE)) {
        unsupported_warnings <<- c(unsupported_warnings, w$message)
      }
      invokeRestart("muffleWarning")
    }
  )
  expect_s3_class(pp, "plotly")
  expect_length(unsupported_warnings, 0)
  # The "geom yet to be implemented" warning is not always emitted —
  # some unsupported geoms convert to empty traces silently. Lock in
  # that the density layer survived by inspecting the built plotly
  # object: geom_rect converts to filled scatter traces, one per
  # fill-color per facet (plotly groups same-color polygons). The
  # median geom_hline/geom_vline/annotate("point") traces have no
  # fillcolor. Without the density layer, zero filled traces remain.
  build <- suppressWarnings(plotly::plotly_build(pp))
  filled_traces <- vapply(build$x$data, function(tr) {
    fc <- tr$fillcolor
    !is.null(fc) && nzchar(fc)
  }, logical(1))
  expect_gt(sum(filled_traces), 0)
  # Also assert the filled traces carry a non-trivial number of
  # vertices — each geom_rect tile contributes 5 polygon points,
  # so a 30×30 bin grid produces hundreds. A bare median-line plot
  # cannot exceed 0 filled vertices.
  total_filled_pts <- sum(vapply(build$x$data[filled_traces],
    function(tr) length(if (is.null(tr$x)) NULL else tr$x),
    integer(1)))
  expect_gt(total_filled_pts, 50)
})

# Regression: cut()-based binning in distance_pace_era previously
# failed with "'breaks' are not unique" when every run shared the
# same km or pace (Codex P1 finding on PR #29). Now guarded by an
# early return to the empty-state ggplot.
test_that("fetch.plot.distance_pace_era handles degenerate km/pace ranges", {
  df <- .fixture_run_profile()
  # Force all runs to identical km — pace_range stays varied, but
  # cut(km, ...) would explode without the guard.
  df_same_km <- df
  df_same_km$distance <- 8000
  p <- fetch.plot.distance_pace_era(df_same_km)
  expect_s3_class(p, "ggplot")

  df_same_pace <- df
  df_same_pace$avgPaceMoving <- 5.5
  p2 <- fetch.plot.distance_pace_era(df_same_pace)
  expect_s3_class(p2, "ggplot")
})

# Regression: season_pace season bands previously had zero height
# when woy_data had a constant mean_pace (single week, or all weeks
# with same average) because pad = diff(y_rng) * 0.08 collapsed to 0
# (Copilot finding on PR #29). Floor pad ensures non-zero band height.
test_that("fetch.plot.season_pace renders non-degenerate season bands on a single week of data", {
  df <- .fixture_run_profile()
  # Restrict to a single ISO week so woy_data has one row.
  one_week <- df[format(df$sessionStart, "%Y-%V") == format(df$sessionStart[1], "%Y-%V"), ]
  p <- fetch.plot.season_pace(one_week)
  expect_s3_class(p, "ggplot")
  b <- suppressMessages(ggplot2::ggplot_build(p))
  # The annotate("rect") layer is layer 1. ymin and ymax must differ
  # (scale_y_reverse() flips the sign so use abs()).
  rect_data <- b$data[[1]]
  expect_true(all(abs(rect_data$ymax - rect_data$ymin) > 0))
})
