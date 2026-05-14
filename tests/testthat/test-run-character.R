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

test_that("fetch.plot.pace_year builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.pace_year(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.pace_year_ridges builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.pace_year_ridges(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.pace_tertile_share builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.pace_tertile_share(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.longest_runs_year builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.longest_runs_year(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.season_pace builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.season_pace(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.heatmap_km builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.heatmap_km(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.cumulative_km builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.cumulative_km(df)
  expect_s3_class(p, "ggplot")
})

test_that("fetch.plot.distance_pace_era builds a ggplot", {
  df <- .fixture_run_profile()
  p <- fetch.plot.distance_pace_era(df)
  expect_s3_class(p, "ggplot")
})

test_that("run-profile plots return empty-state when filter strips data", {
  df <- .fixture_run_profile()
  # Future window with no rows
  p <- fetch.plot.pace_year(df, from = "2100-01-01", to = "2100-12-31")
  expect_s3_class(p, "ggplot")
  p2 <- fetch.plot.cumulative_km(df, from = "2100-01-01", to = "2100-12-31")
  expect_s3_class(p2, "ggplot")
})
