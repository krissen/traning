# Tests for sport= parameter on advanced_metrics functions.
# compute_efficiency_factor / compute_decoupling etc. default to
# sport="running"; compute_trimp() / compute_pmc() default to
# sport="all" so readiness uses multi-sport load.

.metrics_summaries <- function() {
  base <- as.POSIXct("2026-01-01 08:00:00", tz = "UTC")
  data.frame(
    sessionStart       = base + (0:11) * 86400,
    sport              = c("running", "cycling", "running", "cycling",
                           "walking", "running", "cycling", "walking",
                           "running", "cycling", "walking", "running"),
    distance           = c(8000, 25000, 6000, 15000,
                           3000, 10000, 30000, 4000,
                           7000, 20000, 5500, 8500),
    durationMoving     = as.difftime(
      c(40, 60, 31, 38,
        36, 48, 70, 46,
        36, 50, 50, 42),
      units = "mins"),
    avgSpeedMoving     = c(3.33, 6.94, 3.22, 6.58,
                           1.39, 3.47, 7.14, 1.45,
                           3.24, 6.67, 1.83, 3.37),
    avgPaceMoving      = c(5.0, 2.4, 5.2, 2.5,
                           12.0, 4.8, 2.3, 11.5,
                           5.1, 2.4, 9.1, 5.0),
    avgHeartRateMoving = c(140, 130, 142, 135,
                           95, 138, 132, 100,
                           145, 128, 105, 140),
    duration           = as.difftime(
      c(40, 60, 31, 38,
        36, 48, 70, 46,
        36, 50, 50, 42),
      units = "mins"),
    stringsAsFactors = FALSE
  )
}

test_that("compute_efficiency_factor sport='cycling' returns cycling rows", {
  df <- .metrics_summaries()
  result <- compute_efficiency_factor(df, sport = "cycling")
  # Cycling > 5km: rows 2, 4, 7, 10 → distance 25, 15, 30, 20 km
  expect_equal(nrow(result), 4)
  expect_equal(unique(round(result$distance_km)), c(25, 15, 30, 20))
})

test_that("compute_efficiency_factor default still running", {
  df <- .metrics_summaries()
  result <- compute_efficiency_factor(df)
  # Running > 5km: rows 1, 3, 6, 9, 12 → 8, 6, 10, 7, 8.5 km
  expect_equal(nrow(result), 5)
})

test_that("compute_efficiency_factor min_distance is configurable", {
  # Add an explicit short run so the threshold actually changes the count.
  base <- as.POSIXct("2026-02-01 08:00:00", tz = "UTC")
  short <- data.frame(
    sessionStart       = base,
    sport              = "running",
    distance           = 3000,  # < 5 km
    durationMoving     = as.difftime(20, units = "mins"),
    avgSpeedMoving     = 2.5,
    avgPaceMoving      = 6.7,
    avgHeartRateMoving = 130,
    duration           = as.difftime(20, units = "mins"),
    stringsAsFactors = FALSE
  )
  df <- rbind(.metrics_summaries(), short)

  # Default (5000) excludes the 3 km run
  res_default <- compute_efficiency_factor(df, sport = "running")
  # min_distance = 0 includes everything
  res_all <- compute_efficiency_factor(df, sport = "running", min_distance = 0)
  expect_equal(nrow(res_all) - nrow(res_default), 1)
})

test_that("compute_efficiency_factor returns empty tibble when no rows match", {
  df <- .metrics_summaries()
  # No "swimming" rows in fixture → no qualifying sessions
  res <- compute_efficiency_factor(df, sport = "swimming")
  expect_equal(nrow(res), 0)
  expect_named(res, c("sessionStart", "distance_km", "avgSpeedMoving",
                      "avgHeartRateMoving", "ef", "ef_rolling28"))
})

test_that("compute_hre returns empty tibble when no rows match", {
  df <- .metrics_summaries()
  res <- compute_hre(df, sport = "swimming")
  expect_equal(nrow(res), 0)
  expect_named(res, c("sessionStart", "distance_km", "avgHeartRateMoving",
                      "avgPaceMoving", "hre", "hre_rolling28"))
})

test_that("compute_acwr returns empty tibble when no rows match", {
  df <- .metrics_summaries()
  # No rows match — date-spine min/max would crash on empty input
  expect_no_error(res <- compute_acwr(df, sport = "swimming"))
  expect_equal(nrow(res), 0)
})

test_that("compute_monotony_strain returns empty tibble when no rows match", {
  df <- .metrics_summaries()
  expect_no_error(res <- compute_monotony_strain(df, sport = "swimming"))
  expect_equal(nrow(res), 0)
})

test_that("compute_acwr sport='cycling' aggregates cycling km only", {
  df <- .metrics_summaries()
  result <- compute_acwr(df, sport = "cycling")
  # Cycling sessions: 25 + 15 + 30 + 20 = 90 km total
  total_km <- sum(result$daily_km)
  expect_equal(total_km, 90)
})

test_that("compute_acwr sport='all' aggregates everything", {
  df <- .metrics_summaries()
  # sport='all' auto-resolves to mode='trimp' (km doesn't compose across
  # sports); force mode='km' here to verify the cross-sport aggregation
  # path still works on the legacy km columns.
  result <- compute_acwr(df, sport = "all", mode = "km")
  total_km <- sum(result$daily_km)
  expect_equal(total_km, sum(df$distance) / 1000)
})

test_that("compute_monotony_strain honours sport filter", {
  df <- .metrics_summaries()
  result <- compute_monotony_strain(df, sport = "walking")
  # walking sessions: 3 + 4 + 5.5 = 12.5 km
  expect_equal(sum(result$daily_km), 12.5)
})

test_that("compute_trimp sport='cycling' computes from cycling HR data", {
  df <- .metrics_summaries()
  trimp_run <- compute_trimp(df, sport = "running")
  trimp_cyc <- compute_trimp(df, sport = "cycling")
  # Different sports → different daily_trimp (assuming HR differs)
  expect_false(identical(sort(trimp_run$daily_trimp),
                         sort(trimp_cyc$daily_trimp)))
})

test_that("compute_pmc with sport='all' gives larger CTL than running-only", {
  df <- .metrics_summaries()
  pmc_run <- compute_pmc(df, sport = "running")
  pmc_all <- compute_pmc(df, sport = "all")
  # 'all' includes more TRIMP sources → CTL/ATL not lower than running-only
  if (nrow(pmc_run) > 0 && nrow(pmc_all) > 0) {
    expect_gte(max(pmc_all$ctl, na.rm = TRUE),
               max(pmc_run$ctl, na.rm = TRUE))
  }
})

test_that("compute_trimp default aggregates across all sports", {
  df <- .metrics_summaries()
  expect_equal(compute_trimp(df), compute_trimp(df, sport = "all"))
})

test_that("compute_pmc default aggregates across all sports", {
  df <- .metrics_summaries()
  expect_equal(compute_pmc(df), compute_pmc(df, sport = "all"))
})

test_that("compute_efficiency_factor with curated bucket sums sports", {
  df <- .metrics_summaries()
  result <- compute_efficiency_factor(df, sport = "endurance")
  # endurance = running + cycling + walking + swimming
  # > 5 km: 5 running + 4 cycling + 1 walking (5.5 km) + 0 swimming = 10
  expect_equal(nrow(result), 10)
})
