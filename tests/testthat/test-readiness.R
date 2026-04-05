# Tests for R/readiness.R

# --- .piecewise_score ---------------------------------------------------------

test_that(".piecewise_score maps known values correctly", {
  bp <- c("0" = 0, "10" = 100)
  expect_equal(traning:::.piecewise_score(0, bp), 0)
  expect_equal(traning:::.piecewise_score(10, bp), 100)
  expect_equal(traning:::.piecewise_score(5, bp), 50)
})

test_that(".piecewise_score clamps outside range", {
  bp <- c("0" = 0, "10" = 100)
  expect_equal(traning:::.piecewise_score(-5, bp), 0)
  expect_equal(traning:::.piecewise_score(20, bp), 100)
})

test_that(".piecewise_score handles NA", {
  bp <- c("0" = 0, "10" = 100)
  expect_true(is.na(traning:::.piecewise_score(NA, bp)))
})

test_that(".piecewise_score handles multi-segment breakpoints", {
  bp <- c("-2" = 0, "-1" = 50, "0" = 75, "1" = 100)
  expect_equal(traning:::.piecewise_score(-2, bp), 0)
  expect_equal(traning:::.piecewise_score(-1, bp), 50)
  expect_equal(traning:::.piecewise_score(0, bp), 75)
  expect_equal(traning:::.piecewise_score(1, bp), 100)
  expect_equal(traning:::.piecewise_score(-1.5, bp), 25)  # midpoint -2...-1
})

# --- Component scoring --------------------------------------------------------

test_that(".score_hrv maps z-scores correctly", {
  expect_equal(traning:::.score_hrv(0), 75)
  expect_equal(traning:::.score_hrv(-2), 0)
  expect_equal(traning:::.score_hrv(1), 100)
  expect_equal(traning:::.score_hrv(-1), 50)
})

test_that(".score_sleep maps hours correctly", {
  expect_equal(traning:::.score_sleep(8), 100)
  expect_equal(traning:::.score_sleep(7), 75)
  expect_equal(traning:::.score_sleep(4), 0)
  expect_equal(traning:::.score_sleep(6), 50)
})

test_that(".score_sleep applies staging bonus", {
  # deep+rem = 3h out of 7h = 0.43 ratio (>= 0.35 -> +10)
  expect_equal(traning:::.score_sleep(7, deep = 1, rem = 2), 85)
})

test_that(".score_sleep applies staging penalty", {
  # deep+rem = 0.5h out of 7h = 0.07 ratio (< 0.20 -> -10)
  expect_equal(traning:::.score_sleep(7, deep = 0.2, rem = 0.3), 65)
})

test_that(".score_sleep without staging data (NA) gives base score", {
  expect_equal(traning:::.score_sleep(7, deep = NA, rem = NA), 75)
})

test_that(".score_rhr maps deviation correctly", {
  expect_equal(traning:::.score_rhr(0), 80)
  expect_equal(traning:::.score_rhr(-3), 100)
  expect_equal(traning:::.score_rhr(8), 0)
  expect_equal(traning:::.score_rhr(5), 25)
})

test_that(".score_trimp maps ratio correctly", {
  expect_equal(traning:::.score_trimp(0), 90)
  expect_equal(traning:::.score_trimp(1), 70)
  expect_equal(traning:::.score_trimp(3), 10)
})

# --- .weighted_composite ------------------------------------------------------

test_that(".weighted_composite computes weighted mean", {
  df <- data.frame(a = 80, b = 60)
  w <- c(a = 0.5, b = 0.5)
  result <- traning:::.weighted_composite(df, w)
  expect_equal(result$score, 70)
  expect_equal(result$n_components, 2L)
})

test_that(".weighted_composite redistributes on NA", {
  df <- data.frame(a = 80, b = NA_real_)
  w <- c(a = 0.5, b = 0.5)
  result <- traning:::.weighted_composite(df, w)
  expect_equal(result$score, 80)  # only 'a' contributes, gets full weight
  expect_equal(result$n_components, 1L)
})

test_that(".weighted_composite returns NA when all NA", {
  df <- data.frame(a = NA_real_, b = NA_real_)
  w <- c(a = 0.5, b = 0.5)
  result <- traning:::.weighted_composite(df, w)
  expect_true(is.na(result$score))
  expect_equal(result$n_components, 0L)
})

# --- .consecutive_flag --------------------------------------------------------

test_that(".consecutive_flag detects 3+ consecutive days", {
  x <- c(0, 6, 6, 6, 0, 6, 0)
  result <- traning:::.consecutive_flag(x, threshold = 5, min_run = 3)
  expect_equal(result, c(FALSE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE))
})

test_that(".consecutive_flag ignores runs shorter than min_run", {
  x <- c(6, 6, 0, 6, 6)
  result <- traning:::.consecutive_flag(x, threshold = 5, min_run = 3)
  expect_equal(result, c(FALSE, FALSE, FALSE, FALSE, FALSE))
})

test_that(".consecutive_flag handles NA", {
  x <- c(6, NA, 6, 6, 6)
  result <- traning:::.consecutive_flag(x, threshold = 5, min_run = 3)
  # NA breaks the run, so only the last 3 are consecutive
  expect_equal(result, c(FALSE, FALSE, TRUE, TRUE, TRUE))
})

# --- compute_readiness integration --------------------------------------------

# Helper: build minimal test data
make_test_health <- function(n = 30) {
  dates <- seq(Sys.Date() - n, Sys.Date() - 1, by = "day")
  dplyr::bind_rows(
    tibble::tibble(date = dates, metric = "heart_rate_variability",
                   value = rnorm(n, 50, 10), source = "AW"),
    tibble::tibble(date = dates, metric = "resting_heart_rate",
                   value = rnorm(n, 52, 3), source = "AW"),
    tibble::tibble(date = dates, metric = "sleep_totalSleep",
                   value = rnorm(n, 7.2, 0.8), source = "AW"),
    tibble::tibble(date = dates, metric = "sleep_deep",
                   value = pmax(0, rnorm(n, 0.8, 0.2)), source = "AW"),
    tibble::tibble(date = dates, metric = "sleep_rem",
                   value = pmax(0, rnorm(n, 1.5, 0.3)), source = "AW")
  )
}

make_test_summaries <- function(n = 20) {
  dates <- seq(Sys.Date() - 30, Sys.Date() - 1, by = "day")
  run_dates <- sort(sample(dates, n))
  tibble::tibble(
    sessionStart = as.POSIXct(run_dates),
    sport = "running",
    distance = runif(n, 5000, 15000),
    durationMoving = runif(n, 1800, 5400),
    avgPaceMoving = runif(n, 5, 7),
    avgSpeedMoving = runif(n, 2.5, 3.5),
    avgHeartRateMoving = runif(n, 130, 160),
    file = paste0("test_", seq_len(n), ".tcx"),
    year = format(run_dates, "%Y"),
    month = format(run_dates, "%m"),
    total_elevation_gain = runif(n, 20, 100)
  )
}

test_that("compute_readiness returns expected columns", {
  set.seed(42)
  hd <- make_test_health(30)
  s  <- make_test_summaries(15)
  result <- suppressWarnings(compute_readiness(hd, s))

  expected_cols <- c("date", "readiness_score", "readiness_status",
                     "ln_rmssd", "hrv_z", "hrv_score", "hrv_flag",
                     "resting_hr", "rhr_deviation", "rhr_score", "rhr_flag",
                     "sleep_total", "sleep_score", "sleep_flag",
                     "daily_trimp", "atl", "ctl", "tsb", "trimp_score",
                     "load_flag", "data_quality")
  for (col in expected_cols) {
    expect_true(col %in% names(result), info = paste("Missing column:", col))
  }
})

test_that("compute_readiness scores are 0-100", {
  set.seed(42)
  hd <- make_test_health(30)
  s  <- make_test_summaries(15)
  result <- suppressWarnings(compute_readiness(hd, s))

  scores <- result$readiness_score[!is.na(result$readiness_score)]
  expect_true(all(scores >= 0 & scores <= 100))
})

test_that("compute_readiness status is one of three values", {
  set.seed(42)
  hd <- make_test_health(30)
  s  <- make_test_summaries(15)
  result <- suppressWarnings(compute_readiness(hd, s))

  statuses <- result$readiness_status[!is.na(result$readiness_status)]
  expect_true(all(statuses %in% c("Gr\u00f6n", "Gul", "R\u00f6d")))
})

test_that("compute_readiness data_quality reflects component availability", {
  set.seed(42)
  hd <- make_test_health(30)
  s  <- make_test_summaries(15)
  result <- suppressWarnings(compute_readiness(hd, s))

  full_rows <- result[result$data_quality == "full" & !is.na(result$data_quality), ]
  if (nrow(full_rows) > 0) {
    # Full quality means all 4 component scores are non-NA
    expect_true(all(!is.na(full_rows$hrv_score)))
    expect_true(all(!is.na(full_rows$sleep_score)))
    expect_true(all(!is.na(full_rows$rhr_score)))
    expect_true(all(!is.na(full_rows$trimp_score)))
  }
})

test_that("compute_readiness respects after/before filtering", {
  set.seed(42)
  hd <- make_test_health(30)
  s  <- make_test_summaries(15)
  cutoff <- Sys.Date() - 10
  result <- suppressWarnings(
    compute_readiness(hd, s, after = cutoff)
  )
  expect_true(all(result$date >= cutoff))
})
