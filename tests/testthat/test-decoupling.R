# Tests for aerobic decoupling (Phase 4g)

# --- Test fixtures ---

# Minimal summaries for decoupling (need >45 min, >5:00/km pace)
make_dc_summaries <- function(n = 10) {
  dates <- seq(Sys.Date() - (2 * n), Sys.Date() - 1, by = 2)
  dates <- dates[1:n]
  tibble::tibble(
    sessionStart = as.POSIXct(dates),
    sport = "running",
    distance = runif(n, 8000, 15000),
    avgSpeedMoving = runif(n, 2.5, 3.0),  # ~5:30-6:40/km
    avgPaceMoving = runif(n, 5.5, 6.5),   # slower than 5:00
    avgHeartRateMoving = runif(n, 140, 160),
    durationMoving = as.difftime(runif(n, 50, 80), units = "mins")
  )
}

# Synthetic per-second data with known decoupling
# first_speed, second_speed: m/s for each half
# constant HR throughout
make_dc_myruns <- function(summaries,
                           first_speed = 3.0,
                           second_speed = 2.7,
                           hr = 150,
                           duration_sec = 3600) {
  n <- nrow(summaries)
  myruns <- vector("list", n)
  for (i in seq_len(n)) {
    # Create per-second data: warmup + first half + second half
    n_total <- duration_sec
    warmup <- 600
    usable <- n_total - warmup
    mid <- floor(usable / 2)

    speed <- c(
      rep(first_speed, warmup),       # warmup (will be excluded)
      rep(first_speed, mid),           # first half
      rep(second_speed, usable - mid)  # second half
    )
    heart_rate <- rep(hr, n_total)

    session_df <- data.frame(
      time = seq(from = as.POSIXct("2025-01-01 08:00:00"),
                 by = 1, length.out = n_total),
      speed = speed,
      heart_rate = heart_rate
    )
    myruns[[i]] <- session_df
  }
  myruns
}

# Override as.data.frame for our simple test objects (they're already data.frames)
# (trackeRdata objects normally need as.data.frame, but our mocks are plain DFs)

test_summaries_dc <- make_dc_summaries(10)

# --- compute_decoupling ---

test_that("compute_decoupling returns tibble with expected columns", {
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(test_summaries_dc, myruns)
  expect_s3_class(result, "tbl_df")
  expected_cols <- c("sessionStart", "distance_km", "duration_min",
                     "avg_pace", "avg_hr", "ratio_first", "ratio_second",
                     "decoupling_pct", "decoupling_rolling28", "temperature")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("compute_decoupling calculates known decoupling value", {
  # First half: speed 3.0 m/s, HR 150 → ratio = 3.0/150 = 0.020
  # Second half: speed 2.7 m/s, HR 150 → ratio = 2.7/150 = 0.018
  # Decoupling = 100 * (0.020 - 0.018) / 0.020 = 10%
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 3.0, second_speed = 2.7, hr = 150)
  result <- compute_decoupling(test_summaries_dc, myruns)
  expect_gt(nrow(result), 0)
  # Allow tolerance for rolling mean smoothing on speed
  expect_true(all(abs(result$decoupling_pct - 10) < 2))
})

test_that("compute_decoupling returns ~0% for constant pace", {
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 3.0, second_speed = 3.0, hr = 150)
  result <- compute_decoupling(test_summaries_dc, myruns)
  expect_gt(nrow(result), 0)
  expect_true(all(abs(result$decoupling_pct) < 1))
})

test_that("compute_decoupling returns negative for negative splits", {
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 2.7, second_speed = 3.0, hr = 150)
  result <- compute_decoupling(test_summaries_dc, myruns)
  expect_gt(nrow(result), 0)
  expect_true(all(result$decoupling_pct < 0))
})

test_that("compute_decoupling filters non-running sports", {
  mixed <- test_summaries_dc
  mixed$sport[1:3] <- "cycling"
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(mixed, myruns)
  # Should have fewer results
  full <- compute_decoupling(test_summaries_dc, myruns)
  expect_lt(nrow(result), nrow(full))
})

test_that("compute_decoupling filters short runs (<45 min)", {
  short <- test_summaries_dc
  short$durationMoving[1:3] <- as.difftime(30, units = "mins")
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(short, myruns)
  full <- compute_decoupling(test_summaries_dc, myruns)
  expect_lt(nrow(result), nrow(full))
})

test_that("compute_decoupling filters fast pace (<5:00/km)", {
  fast <- test_summaries_dc
  fast$avgPaceMoving[1:3] <- 4.5  # faster than 5:00
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(fast, myruns)
  full <- compute_decoupling(test_summaries_dc, myruns)
  expect_lt(nrow(result), nrow(full))
})

test_that("compute_decoupling handles NULL myruns entries", {
  myruns <- make_dc_myruns(test_summaries_dc)
  myruns[[1]] <- NULL
  myruns[[2]] <- NULL
  expect_warning(
    result <- compute_decoupling(test_summaries_dc, myruns),
    "sessioner hoppades"
  )
  expect_s3_class(result, "tbl_df")
})

test_that("compute_decoupling handles missing speed column", {
  myruns <- make_dc_myruns(test_summaries_dc)
  myruns[[1]] <- data.frame(
    time = seq(from = as.POSIXct("2025-01-01"), by = 1, length.out = 3600),
    heart_rate = rep(150, 3600)
  )  # no speed column
  expect_warning(
    result <- compute_decoupling(test_summaries_dc, myruns),
    "sessioner hoppades"
  )
  expect_s3_class(result, "tbl_df")
})

test_that("compute_decoupling returns empty tibble for no qualifying sessions", {
  empty_summ <- test_summaries_dc
  empty_summ$sport <- "cycling"  # all non-running
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(empty_summ, myruns)
  expect_equal(nrow(result), 0)
  expect_true(all(c("sessionStart", "decoupling_pct") %in% names(result)))
})

test_that("compute_decoupling includes temperature when available", {
  summ_temp <- test_summaries_dc
  summ_temp$garmin_averageTemperature <- runif(nrow(summ_temp), 10, 25)
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(summ_temp, myruns)
  expect_true("temperature" %in% names(result))
  expect_true(any(!is.na(result$temperature)))
})

test_that("compute_decoupling temperature is NA when column missing", {
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(test_summaries_dc, myruns)
  expect_true(all(is.na(result$temperature)))
})

test_that("compute_decoupling excludes non-steady-state sessions", {
  # First half at 2.0 m/s, second half at 3.5 m/s → 43% difference → excluded
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 2.0, second_speed = 3.5, hr = 150)
  expect_warning(
    result <- compute_decoupling(test_summaries_dc, myruns,
                                 max_half_speed_diff_pct = 10),
    "sessioner hoppades"
  )
  expect_equal(nrow(result), 0)
})

test_that("compute_decoupling keeps steady-state sessions", {
  # First half at 3.0, second half at 2.85 → 5% difference → kept
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 3.0, second_speed = 2.85, hr = 150)
  result <- compute_decoupling(test_summaries_dc, myruns,
                               max_half_speed_diff_pct = 10)
  expect_gt(nrow(result), 0)
})

test_that("compute_decoupling max_half_speed_diff_pct is adjustable", {
  # 15% speed difference between halves
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 3.0, second_speed = 2.5, hr = 150)
  # strict: should exclude (17% diff)
  expect_warning(
    strict <- compute_decoupling(test_summaries_dc, myruns,
                                 max_half_speed_diff_pct = 10),
    "sessioner hoppades"
  )
  # relaxed: should include
  relaxed <- compute_decoupling(test_summaries_dc, myruns,
                                max_half_speed_diff_pct = 20)
  expect_lt(nrow(strict), nrow(relaxed))
})

# --- report_decoupling ---

test_that("report_decoupling returns tibble with Swedish columns", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  result <- report_decoupling(decoupling_data = dc_data)
  expect_s3_class(result, "tbl_df")
  expected_cols <- c("Datum", "Km", "Tempo", "HR", "Dekopp %", "Dekopp 28d", "Temp")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("report_decoupling respects n parameter", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  result <- report_decoupling(decoupling_data = dc_data, n = 3)
  expect_lte(nrow(result), 3)
})

test_that("report_decoupling respects from/to date range", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  from <- Sys.Date() - 10
  to <- Sys.Date()
  result <- report_decoupling(decoupling_data = dc_data, from = from, to = to)
  if (nrow(result) > 0) {
    expect_true(all(result$Datum >= from))
    expect_true(all(result$Datum < to))
  }
})

test_that("report_decoupling handles empty input", {
  empty <- tibble::tibble(
    sessionStart = as.Date(character(0)), distance_km = numeric(0),
    duration_min = numeric(0), avg_pace = numeric(0), avg_hr = numeric(0),
    ratio_first = numeric(0), ratio_second = numeric(0),
    decoupling_pct = numeric(0), decoupling_rolling28 = numeric(0),
    temperature = numeric(0)
  )
  result <- report_decoupling(decoupling_data = empty)
  expect_equal(nrow(result), 0)
})

# --- load_decoupling (cache) ---

test_that("load_decoupling saves and loads cache", {
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))

  result1 <- load_decoupling(test_summaries_dc, myruns, cache_path = cache_file)
  expect_true(file.exists(cache_file))

  result2 <- load_decoupling(test_summaries_dc, myruns, cache_path = cache_file)
  expect_equal(nrow(result1), nrow(result2))
})

test_that("load_decoupling force bypasses cache", {
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))

  load_decoupling(test_summaries_dc, myruns, cache_path = cache_file)
  result <- load_decoupling(test_summaries_dc, myruns,
                            cache_path = cache_file, force = TRUE)
  expect_s3_class(result, "tbl_df")
})

test_that("load_decoupling invalidates on parameter change", {
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))

  load_decoupling(test_summaries_dc, myruns, cache_path = cache_file,
                  min_duration_min = 45)
  # Change parameter → should recompute
  result <- load_decoupling(test_summaries_dc, myruns, cache_path = cache_file,
                            min_duration_min = 30)
  expect_s3_class(result, "tbl_df")
})
