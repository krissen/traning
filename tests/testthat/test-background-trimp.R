# Tests for compute_background_trimp() and compute_trimp()'s
# health_daily integration.

.bg_health <- function(dates = as.Date(c("2026-05-01", "2026-05-02",
                                          "2026-05-03")),
                       wrd = c(10, 5, 0),
                       ae  = c(2500, 1250, 0),
                       steps = c(15000, 8000, 0)) {
  rows <- list()
  for (i in seq_along(dates)) {
    if (!is.na(wrd[i])) {
      rows[[length(rows) + 1L]] <- tibble::tibble(
        date = dates[i],
        metric = "walking_running_distance",
        value = wrd[i],
        source = "Apple Watch"
      )
    }
    if (!is.na(ae[i])) {
      rows[[length(rows) + 1L]] <- tibble::tibble(
        date = dates[i],
        metric = "active_energy",
        value = ae[i],
        source = "Apple Watch"
      )
    }
    if (!is.na(steps[i])) {
      rows[[length(rows) + 1L]] <- tibble::tibble(
        date = dates[i],
        metric = "step_count",
        value = steps[i],
        source = "Apple Watch"
      )
    }
  }
  dplyr::bind_rows(rows)
}

test_that("compute_background_trimp returns empty when health_daily missing", {
  expect_equal(nrow(compute_background_trimp(NULL)), 0)
  expect_equal(nrow(compute_background_trimp(tibble::tibble())), 0)
})

test_that("compute_background_trimp produces positive values from wrd", {
  hd <- .bg_health()
  result <- compute_background_trimp(hd)
  # 10 km × 12 min/km × 0.30 × 0.64 × exp(0.576) ≈ 41.04 TRIMP for day 1
  expect_equal(nrow(result), 2L)  # day 3 has zero wrd → filtered out
  expect_gt(result$background_trimp[1], 30)
  expect_lt(result$background_trimp[1], 50)
  expect_gt(result$background_trimp[1], result$background_trimp[2])
})

test_that("compute_background_trimp subtracts workout walking/running km", {
  hd <- .bg_health()
  # A 5 km run on day 1 (with HR + duration > 10min, so compute_trimp
  # would count it) should knock 5 km off the 10 km wrd → halve TRIMP.
  # The filter alignment is intentional: only workouts that contribute
  # workout TRIMP get their distance stripped from background.
  summaries <- tibble::tibble(
    sessionStart       = as.POSIXct("2026-05-01 09:00:00", tz = "UTC"),
    sport              = "running",
    distance           = 5000,
    avgHeartRateMoving = 150,
    durationMoving     = as.difftime(25, units = "mins")
  )
  with_workout <- compute_background_trimp(hd, summaries = summaries)
  without_workout <- compute_background_trimp(hd)
  expect_lt(with_workout$background_trimp[1],
            without_workout$background_trimp[1])
  # Should roughly halve (5/10 of original wrd remaining)
  expect_equal(with_workout$background_trimp[1] /
                 without_workout$background_trimp[1],
               0.5, tolerance = 0.01)
})

test_that("compute_background_trimp leaves short/HR-less workouts in bg", {
  # The filter alignment with compute_trimp: a sub-10min walk with no
  # HR data shouldn't get subtracted, because compute_trimp won't add
  # workout TRIMP for it either — without this the activity would
  # contribute zero load on both sides.
  hd <- .bg_health()
  short_walk <- tibble::tibble(
    sessionStart       = as.POSIXct("2026-05-01 09:00:00", tz = "UTC"),
    sport              = "walking",
    distance           = 3000,
    avgHeartRateMoving = NA_real_,
    durationMoving     = as.difftime(5, units = "mins")
  )
  with_short <- compute_background_trimp(hd, summaries = short_walk)
  no_summary <- compute_background_trimp(hd)
  expect_equal(with_short$background_trimp[1],
               no_summary$background_trimp[1])
})

test_that("compute_background_trimp skips fallback on non-walking workout days", {
  # Step count drifts up during indoor cycling too (watch counts
  # pedal-strokes / hand motion). Using the step-count fallback on
  # cycling days would credit those as background walking.
  hd_no_wrd <- tibble::tibble(
    date = as.Date("2026-05-01"),
    metric = "step_count",
    value = 14000,
    source = "Apple Watch"
  )
  cycling <- tibble::tibble(
    sessionStart       = as.POSIXct("2026-05-01 09:00:00", tz = "UTC"),
    sport              = "cycling",
    distance           = 30000,
    avgHeartRateMoving = 140,
    durationMoving     = as.difftime(60, units = "mins")
  )
  bg <- compute_background_trimp(hd_no_wrd, summaries = cycling)
  # Cycling workout poisons fallback → no background TRIMP that day
  expect_equal(nrow(bg), 0)
})

test_that("compute_background_trimp falls back to step_count when wrd missing", {
  # Day with step_count but no wrd — fallback is now step-based (units
  # are unambiguous, unlike active_energy which HAE can write in kJ
  # or kcal).
  hd <- tibble::tibble(
    date = as.Date("2026-05-01"),
    metric = "step_count",
    value = 14000,  # 14k steps * 0.7 m/step = 9.8 km ≈ same as wrd=10
    source = "Apple Watch"
  )
  result <- compute_background_trimp(hd)
  expect_equal(nrow(result), 1L)
  expect_gt(result$background_trimp[1], 30)
  expect_lt(result$background_trimp[1], 50)
})

test_that("compute_background_trimp filters out zero-TRIMP days", {
  hd <- tibble::tibble(
    date = as.Date(c("2026-05-01", "2026-05-02")),
    metric = "walking_running_distance",
    value = c(5, 0),
    source = "Apple Watch"
  )
  result <- compute_background_trimp(hd)
  expect_equal(nrow(result), 1L)
  expect_equal(result$date, as.Date("2026-05-01"))
})

test_that("compute_trimp adds background when sport='all' and health_daily given", {
  summaries <- tibble::tibble(
    sessionStart       = as.POSIXct("2026-05-01 09:00:00", tz = "UTC"),
    sport              = "running",
    distance           = 5000,
    durationMoving     = as.difftime(30, units = "mins"),
    avgHeartRateMoving = 150,
    avgPaceMoving      = 6,
    avgSpeedMoving     = 2.78,
    duration           = as.difftime(30, units = "mins")
  )
  hd <- .bg_health()  # day 1 wrd = 10 km
  # Without health_daily: only workout TRIMP
  base <- compute_trimp(summaries, hr_max = 185, hr_rest = 50,
                        sport = "all")
  augmented <- compute_trimp(summaries, hr_max = 185, hr_rest = 50,
                             sport = "all", health_daily = hd)
  expect_gt(augmented$daily_trimp[augmented$date == as.Date("2026-05-01")],
            base$daily_trimp[base$date == as.Date("2026-05-01")])
})

test_that("compute_trimp folds background even when no qualifying workouts", {
  # User-facing case: 30k-step vandringsdag with no workout shouldn't
  # read as zero load. Earlier draft hit an early-return in
  # compute_trimp before background was folded in.
  empty_summaries <- tibble::tibble(
    sessionStart       = as.POSIXct(character(0), tz = "UTC"),
    sport              = character(0),
    distance           = numeric(0),
    durationMoving     = as.difftime(numeric(0), units = "mins"),
    avgHeartRateMoving = numeric(0),
    avgPaceMoving      = numeric(0),
    avgSpeedMoving     = numeric(0),
    duration           = as.difftime(numeric(0), units = "mins")
  )
  hd <- .bg_health()  # day 1 wrd = 10 km → ~41 TRIMP
  result <- compute_trimp(empty_summaries, hr_max = 185, hr_rest = 50,
                          sport = "all", health_daily = hd)
  expect_gt(nrow(result), 0)
  expect_true(all(result$daily_trimp > 0))
  expect_true(any(result$daily_trimp > 30))
})

test_that("compute_trimp ignores health_daily for sport-specific buckets", {
  summaries <- tibble::tibble(
    sessionStart       = as.POSIXct("2026-05-01 09:00:00", tz = "UTC"),
    sport              = "running",
    distance           = 5000,
    durationMoving     = as.difftime(30, units = "mins"),
    avgHeartRateMoving = 150,
    avgPaceMoving      = 6,
    avgSpeedMoving     = 2.78,
    duration           = as.difftime(30, units = "mins")
  )
  hd <- .bg_health()
  with_bg <- compute_trimp(summaries, hr_max = 185, hr_rest = 50,
                            sport = "running", health_daily = hd)
  no_bg   <- compute_trimp(summaries, hr_max = 185, hr_rest = 50,
                            sport = "running")
  # Same TRIMP either way — running bucket doesn't fold in background
  expect_equal(with_bg$daily_trimp, no_bg$daily_trimp)
})
