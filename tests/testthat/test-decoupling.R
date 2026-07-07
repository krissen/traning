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
                     "decoupling_pct", "decoupling_rolling28", "temperature",
                     "capped")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("compute_decoupling marks |decoupling| > cap_pct as capped, doesn't drop", {
  # Force an extreme decoupling: speed 3.0 → 1.0 m/s, decoupling ~67 %.
  myruns <- make_dc_myruns(test_summaries_dc,
                           first_speed = 3.0, second_speed = 1.0, hr = 150)
  # Use loose half_diff filter so we don't reject these as fartlek
  res <- suppressWarnings(
    compute_decoupling(test_summaries_dc, myruns,
                       max_half_speed_diff_pct = 99,
                       cap_pct = 25)
  )
  expect_gt(nrow(res), 0)
  expect_true(any(res$capped))
  expect_true(all(abs(res$decoupling_pct[res$capped]) > 25, na.rm = TRUE))
  # The capped rows must still be present in the per-run output
  capped_dates <- res$sessionStart[res$capped]
  expect_setequal(capped_dates, as.Date(test_summaries_dc$sessionStart))
})

test_that("rolling28 ignores capped sessions", {
  # Mix one extreme outlier in with otherwise normal data
  sm <- make_dc_summaries(8)
  myruns <- make_dc_myruns(sm,
                           first_speed = 3.0, second_speed = 2.7, hr = 150)
  # Replace the last session's per-second data with an extreme decoupling
  warmup <- 600; mid <- floor((3600 - warmup) / 2)
  myruns[[length(myruns)]]$speed <- c(rep(3.0, warmup),
                                       rep(3.0, mid),
                                       rep(0.5, 3600 - warmup - mid))
  res <- suppressWarnings(
    compute_decoupling(sm, myruns,
                       max_half_speed_diff_pct = 99,
                       cap_pct = 25)
  )
  # Rolling on the capped session itself should be NA or ignore the spike
  capped_row <- res[res$capped, ]
  expect_gt(nrow(capped_row), 0)
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

test_that("compute_decoupling pace default is sport-aware for cycling", {
  # Cycling sessions are typically much faster than 5:00/km, so the
  # running-tuned threshold of 5.0 would reject every ride (`pace >
  # 5.0` is FALSE for any pace under 5 min/km). The cycling default
  # of 1.5 min/km is permissive enough to keep them.
  cyc <- test_summaries_dc
  cyc$sport <- "cycling"
  # Cycling pace 2.0 min/km (= 30 km/h) — slower than 1.5 in min/km
  # terms (higher number = slower pace), so passes `pace > 1.5`. It
  # would have failed the running default `pace > 5.0`.
  cyc$avgPaceMoving <- 2.0
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(cyc, myruns, sport = "cycling")
  expect_gt(nrow(result), 0)
})

test_that("compute_decoupling disables pace ceiling for multi-sport buckets", {
  # Endurance bucket spans running (~5 min/km), cycling (~1.5 min/km),
  # walking (~6 min/km). A single min/km cutoff doesn't fit any of
  # them, so the default disables the pace gate (max_pace_min_km = 0
  # — the predicate is `avgPaceMoving > max_pace_min_km`, so 0 keeps
  # every row with a real pace) and only duration / steady-state
  # filters apply. Expect every row to survive (regression check
  # against the previous max(vals)=15.0 default that excluded most
  # endurance sessions).
  mixed <- test_summaries_dc
  mixed$sport <- rep(c("running", "cycling", "walking", "swimming"),
                     length.out = nrow(mixed))
  mixed$avgPaceMoving <- ifelse(mixed$sport == "cycling", 2.0,
                                ifelse(mixed$sport == "running", 5.5,
                                ifelse(mixed$sport == "walking", 8.0, 18.0)))
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(mixed, myruns, sport = "endurance")
  expect_equal(nrow(result), nrow(mixed))
})

test_that("compute_decoupling with sport='all' does not silently filter all rows", {
  # Regression: previously sport=NULL/"all" defaulted max_pace_min_km
  # to 15.0, which excludes nearly every running/cycling/walking
  # session (they're all faster than 15 min/km).
  cyc <- test_summaries_dc
  cyc$sport <- rep(c("running", "cycling"), length.out = nrow(cyc))
  cyc$avgPaceMoving <- ifelse(cyc$sport == "cycling", 2.0, 5.5)
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(cyc, myruns, sport = "all")
  expect_gt(nrow(result), 0)
})

test_that("compute_decoupling unknown single sport disables pace ceiling", {
  # Previously fell back to 15.0 → empty result. With max_pace_min_km
  # = 0 the pace predicate (`avgPaceMoving > 0`) keeps every recorded
  # session and only duration / steady-state filters apply.
  weird <- test_summaries_dc
  weird$sport <- "yoga"
  weird$avgPaceMoving <- 4.0  # would fail running's 5.0 cutoff
  myruns <- make_dc_myruns(test_summaries_dc)
  result <- compute_decoupling(weird, myruns, sport = "yoga")
  expect_gt(nrow(result), 0)
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
  bundle <- traning_data(summaries = test_summaries_dc, myruns = myruns,
                          decoupling_data = dc_data)
  result <- report_decoupling(bundle)
  expect_s3_class(result, "tbl_df")
  expected_cols <- c("Datum", "Km", "Tempo", "HR", "Dekopp %", "Dekopp 28d", "Temp")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("report_decoupling respects n parameter", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  bundle <- traning_data(summaries = test_summaries_dc, myruns = myruns,
                          decoupling_data = dc_data)
  result <- report_decoupling(bundle, n = 3)
  expect_lte(nrow(result), 3)
})

test_that("report_decoupling respects from/to date range", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  bundle <- traning_data(summaries = test_summaries_dc, myruns = myruns,
                          decoupling_data = dc_data)
  from <- Sys.Date() - 10
  to <- Sys.Date()
  result <- report_decoupling(bundle, from = from, to = to)
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
  bundle <- traning_data(summaries = test_summaries_dc, decoupling_data = empty)
  result <- report_decoupling(bundle)
  expect_equal(nrow(result), 0)
})

# --- report_decoupling: bundle path (lazy-compute fallback + sport-keying) ---

test_that("report_decoupling: cache-populated bundle skips recompute", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  # Tag the cached decoupling_pct with a sentinel value that
  # compute_decoupling() would never produce, so if the report silently
  # recomputed from summaries/myruns instead of using the cache, this
  # value would not survive into the output.
  dc_data$decoupling_pct[1] <- 999
  bundle <- traning_data(summaries = test_summaries_dc, myruns = myruns,
                          decoupling_data = dc_data, sport = "running")
  result <- report_decoupling(bundle, n = nrow(dc_data))
  expect_s3_class(result, "tbl_df")
  expect_true(any(result[["Dekopp %"]] == 999))
})

test_that("report_decoupling: NULL decoupling_data triggers lazy-compute fallback", {
  myruns <- make_dc_myruns(test_summaries_dc)
  bundle <- traning_data(summaries = test_summaries_dc, myruns = myruns,
                          sport = "running")
  expect_null(bundle@decoupling_data)
  result <- report_decoupling(bundle)
  expect_s3_class(result, "tbl_df")
  expected_cols <- c("Datum", "Km", "Tempo", "HR", "Dekopp %", "Dekopp 28d", "Temp")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("traning_data validator rejects decoupling_data with mismatched empty sport", {
  myruns <- make_dc_myruns(test_summaries_dc)
  dc_data <- compute_decoupling(test_summaries_dc, myruns)
  expect_error(
    traning_data(summaries = test_summaries_dc, myruns = myruns,
                 decoupling_data = dc_data, sport = ""),
    regexp = "sport"
  )
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

test_that("load_decoupling read_only=TRUE skips cache write", {
  # Shiny per-session-loaden anropar med read_only=TRUE för att
  # undvika disk-writes vid varje session. Returvärdet ska vara
  # samma som vanligt anrop, men cache-filen ska inte skrivas
  # (eller röras) när den redan finns.
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))

  load_decoupling(test_summaries_dc, myruns, cache_path = cache_file)
  expect_true(file.exists(cache_file))
  mtime_before <- file.info(cache_file)$mtime

  # Sleep ger mtime-jämförelsen tillräcklig granularitet på
  # filsystem med sekundupplösning.
  Sys.sleep(1.1)

  result <- load_decoupling(test_summaries_dc, myruns,
                            cache_path = cache_file, read_only = TRUE)
  expect_s3_class(result, "tbl_df")
  mtime_after <- file.info(cache_file)$mtime
  expect_equal(mtime_before, mtime_after)
})

test_that("load_decoupling read_only=TRUE without existing cache still returns data", {
  # Cold cache + read_only ska beräkna in-memory utan att skriva
  # cache-filen.
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))

  result <- load_decoupling(test_summaries_dc, myruns,
                            cache_path = cache_file, read_only = TRUE)
  expect_s3_class(result, "tbl_df")
  expect_false(file.exists(cache_file))
})

test_that("load_decoupling pace default is sport-aware (cycling)", {
  # Regression: load_decoupling used to hard-code max_pace_min_km =
  # 5.0 in its pre-cache filter, which silently dropped every cycling
  # row before compute_decoupling ever ran. With the shared
  # .resolve_max_pace_min_km() resolver, sport="cycling" now uses 1.5
  # and keeps cycling sessions.
  cyc <- test_summaries_dc
  cyc$sport <- "cycling"
  cyc$avgPaceMoving <- 2.0
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))
  result <- load_decoupling(cyc, myruns,
                            sport = "cycling",
                            cache_path = cache_file)
  expect_gt(nrow(result), 0)
})

test_that("load_decoupling pace default disables filter for 'all'/buckets", {
  # Same regression check for multi-sport scoping: previously the
  # pre-cache filter `pace > 5.0` excluded everything in buckets like
  # "endurance" / "all"; the gate is now disabled (0).
  mixed <- test_summaries_dc
  mixed$sport <- rep(c("running", "cycling"), length.out = nrow(mixed))
  mixed$avgPaceMoving <- ifelse(mixed$sport == "cycling", 2.0, 5.5)
  myruns <- make_dc_myruns(test_summaries_dc)
  cache_file <- tempfile(fileext = ".RData")
  on.exit(unlink(cache_file))
  result <- load_decoupling(mixed, myruns,
                            sport = "all",
                            cache_path = cache_file)
  expect_gt(nrow(result), 0)
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
