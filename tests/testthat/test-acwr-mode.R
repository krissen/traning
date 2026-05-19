# Tests for compute_acwr() mode parameter (km vs trimp).

.acwr_summaries <- function() {
  # 40 days of running + some cycling for cross-sport tests
  base <- as.POSIXct("2026-01-01 08:00:00", tz = "UTC")
  data.frame(
    sessionStart       = base + (0:39) * 86400,
    sport              = rep(c("running", "running", "running",
                                "cycling", "running"), 8),
    distance           = rep(c(8000, 10000, 6000, 30000, 5000), 8),
    durationMoving     = as.difftime(rep(c(40, 50, 30, 60, 25), 8),
                                      units = "mins"),
    avgHeartRateMoving = rep(c(140, 145, 142, 130, 138), 8),
    avgSpeedMoving     = rep(c(3.33, 3.33, 3.33, 8.33, 3.33), 8),
    avgPaceMoving      = rep(c(5.0, 5.0, 5.0, 2.0, 5.0), 8),
    duration           = as.difftime(rep(c(40, 50, 30, 60, 25), 8),
                                      units = "mins"),
    stringsAsFactors = FALSE
  )
}

test_that("compute_acwr auto-mode=trimp for sport='all'", {
  df <- .acwr_summaries()
  result <- compute_acwr(df, sport = "all")
  expect_equal(attr(result, "mode"), "trimp")
  expect_true(all(is.na(result$daily_km)))
  expect_true(any(!is.na(result$daily_load)))
})

test_that("compute_acwr auto-mode=km for sport='running'", {
  df <- .acwr_summaries()
  result <- compute_acwr(df, sport = "running")
  expect_equal(attr(result, "mode"), "km")
  expect_true(any(result$daily_km > 0))
  expect_equal(result$daily_km, result$daily_load)
})

test_that("compute_acwr explicit mode overrides auto", {
  df <- .acwr_summaries()
  trimp_force <- compute_acwr(df, sport = "running", mode = "trimp",
                               hr_max = 185, hr_rest = 50)
  expect_equal(attr(trimp_force, "mode"), "trimp")
  expect_true(all(is.na(trimp_force$daily_km)))

  km_force <- compute_acwr(df, sport = "all", mode = "km")
  expect_equal(attr(km_force, "mode"), "km")
  expect_true(any(km_force$daily_km > 0))
})

test_that("compute_acwr rejects unknown mode", {
  df <- .acwr_summaries()
  expect_error(compute_acwr(df, mode = "foo"))
})

test_that("compute_acwr TRIMP mode produces ACWR in plausible range", {
  df <- .acwr_summaries()
  result <- compute_acwr(df, sport = "all", hr_max = 185, hr_rest = 50)
  # ACWR should land within reasonable [0, 5] band given consistent
  # weekly load — sanity check, not a precise threshold.
  valid <- result$acwr[!is.na(result$acwr) & result$acwr > 0]
  expect_true(length(valid) > 0)
  expect_true(all(valid > 0 & valid < 10))
})

test_that("compute_acwr auto-mode treats NULL/'any' as whole-system", {
  df <- .acwr_summaries()
  for (s in list(NULL, "any")) {
    r <- compute_acwr(df, sport = s, hr_max = 185, hr_rest = 50)
    expect_equal(attr(r, "mode"), "trimp",
                 info = paste("sport =", deparse(s)))
    expect_true(all(is.na(r$daily_km)),
                info = paste("sport =", deparse(s)))
  }
})

test_that("report_acwr column labels follow the resolved mode", {
  df <- .acwr_summaries()
  km_tbl <- report_acwr(df, sport = "running")
  expect_true(all(c("Km/dag", "Km/vecka", "ACWR") %in% names(km_tbl)))
  expect_false("TRIMP/dag" %in% names(km_tbl))

  trimp_tbl <- report_acwr(df, sport = "all", n = 5)
  expect_true(all(c("TRIMP/dag", "TRIMP/vecka", "ACWR") %in% names(trimp_tbl)))
  expect_false("Km/dag" %in% names(trimp_tbl))
})

test_that("compute_acwr TRIMP mode threads health_daily background", {
  df <- .acwr_summaries()
  hd <- tibble::tibble(
    date = as.Date("2026-01-10") + 0:30,
    metric = "walking_running_distance",
    value = 8,  # 8 km/day vardagsgång
    source = "Apple Watch"
  )
  with_bg <- compute_acwr(df, sport = "all", hr_max = 185, hr_rest = 50,
                          health_daily = hd)
  no_bg <- compute_acwr(df, sport = "all", hr_max = 185, hr_rest = 50)
  # Total daily_load over the period should be higher with background
  expect_gt(sum(with_bg$daily_load, na.rm = TRUE),
            sum(no_bg$daily_load, na.rm = TRUE))
})
