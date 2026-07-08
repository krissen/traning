# Tests for load_overview_metrics() — Shiny overview-page precache
# (R/advanced_metrics.R). See docs/dev pipeline-design-adjacent design
# notes in the PR description for the rationale (two independent TRIMP
# scans folded into one disk cache).

# --- Test fixtures -----------------------------------------------------------
# Small synthetic summaries/health_daily, same shape as
# test-report-advanced.R's make_test_summaries() — enough columns for
# compute_pmc()/compute_acwr()/compute_readiness() to run without error.

make_ov_summaries <- function(n = 30) {
  dates <- seq(Sys.Date() - n, Sys.Date() - 1, by = "day")
  run_dates <- dates[seq(1, length(dates), by = 2)]
  tibble::tibble(
    sessionStart = as.POSIXct(run_dates),
    sport = "running",
    distance = runif(length(run_dates), 5000, 15000),
    avgSpeedMoving = runif(length(run_dates), 2.5, 3.5),
    avgPaceMoving = runif(length(run_dates), 4.5, 6.5),
    avgHeartRateMoving = runif(length(run_dates), 140, 170),
    durationMoving = runif(length(run_dates), 25, 70)
  )
}

make_ov_health <- function(n = 30) {
  dates <- seq(Sys.Date() - n, Sys.Date() - 1, by = "day")
  metrics <- c("resting_heart_rate", "heart_rate_variability",
              "sleep_totalSleep", "sleep_deep", "sleep_rem")
  tibble::tibble(
    date   = rep(dates, length(metrics)),
    metric = rep(metrics, each = length(dates)),
    value  = c(runif(length(dates), 45, 60),   # resting_heart_rate
               runif(length(dates), 30, 80),   # heart_rate_variability
               runif(length(dates), 360, 480),  # sleep_totalSleep (min)
               runif(length(dates), 60, 120),   # sleep_deep (min)
               runif(length(dates), 60, 120)),  # sleep_rem (min)
    source = "test"
  )
}

test_summaries_ov <- make_ov_summaries(30)
test_health_ov    <- make_ov_health(30)

# Sets up an isolated TRANING_DATA/cache/ dir with real summaries.RData
# and health_daily.RData files (so .overview_source_mtime() has
# something real to stat), and points cache_path at overview.RData in
# the same directory. Returns the cache_path and restores the previous
# TRANING_DATA env var on exit via the caller's `local()`/test scope.
setup_ov_cache_dir <- function() {
  root <- tempfile("overview-cache-")
  dir.create(file.path(root, "cache"), recursive = TRUE)
  old_td <- Sys.getenv("TRANING_DATA", unset = NA)
  Sys.setenv(TRANING_DATA = root)

  summaries <- test_summaries_ov
  save(summaries, file = file.path(root, "cache", "summaries.RData"))
  health_daily <- test_health_ov
  save(health_daily, file = file.path(root, "cache", "health_daily.RData"))

  list(
    root = root,
    cache_path = file.path(root, "cache", "overview.RData"),
    restore = function() {
      if (is.na(old_td)) Sys.unsetenv("TRANING_DATA")
      else Sys.setenv(TRANING_DATA = old_td)
      unlink(root, recursive = TRUE)
    }
  )
}

# --- Basic build / read ------------------------------------------------------

test_that("load_overview_metrics builds and saves a cache on a cold miss", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  expect_false(file.exists(env$cache_path))
  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  expect_true(file.exists(env$cache_path))
  expect_type(result, "list")
  expect_setequal(names(result), c("pmc", "acwr_all", "volume_running",
                                   "readiness"))
  expect_s3_class(result$pmc, "tbl_df")
  expect_s3_class(result$acwr_all, "tbl_df")
  expect_s3_class(result$volume_running, "tbl_df")
})

test_that("load_overview_metrics reads a fresh cache without recomputing", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  first <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                 cache_path = env$cache_path)
  # Tag the cached pmc with a sentinel value compute_pmc() would never
  # produce, then reload — if the cache hit path silently recomputed,
  # the sentinel would be gone.
  load(env$cache_path)  # loads: overview_cache
  overview_cache$pmc$ctl[1] <- -999999
  save(overview_cache, file = env$cache_path)

  second <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  expect_true(any(second$pmc$ctl == -999999, na.rm = TRUE))
})

test_that("load_overview_metrics cached values equal direct compute_*() calls", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  cached <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  direct_pmc <- compute_pmc(test_summaries_ov, health_daily = test_health_ov)
  direct_acwr_all <- compute_acwr(test_summaries_ov, sport = "all",
                                  health_daily = test_health_ov)
  direct_volume <- compute_acwr(test_summaries_ov, sport = "running",
                                mode = "km")
  direct_readiness <- compute_readiness(test_health_ov, test_summaries_ov,
                                        pmc = direct_pmc)

  expect_equal(cached$pmc, direct_pmc)
  expect_equal(cached$acwr_all, direct_acwr_all)
  expect_equal(cached$volume_running, direct_volume)
  expect_equal(cached$readiness, direct_readiness)
})

test_that("load_overview_metrics force=TRUE bypasses a fresh cache", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  load_overview_metrics(test_summaries_ov, test_health_ov,
                        cache_path = env$cache_path)
  load(env$cache_path)
  overview_cache$pmc$ctl[1] <- -999999
  save(overview_cache, file = env$cache_path)

  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path, force = TRUE)
  expect_false(any(result$pmc$ctl == -999999, na.rm = TRUE))
})

# --- read_only ---------------------------------------------------------------

test_that("load_overview_metrics read_only=TRUE on a cold miss does not write", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  expect_false(file.exists(env$cache_path))
  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path,
                                  read_only = TRUE)
  expect_type(result, "list")
  expect_false(file.exists(env$cache_path))
})

test_that("load_overview_metrics read_only=TRUE on a fresh cache reads it, doesn't rewrite", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  load_overview_metrics(test_summaries_ov, test_health_ov,
                        cache_path = env$cache_path)
  load(env$cache_path)
  overview_cache$pmc$ctl[1] <- -999999
  save(overview_cache, file = env$cache_path)
  mtime_before <- file.info(env$cache_path)$mtime

  Sys.sleep(1.1)
  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path,
                                  read_only = TRUE)
  # Fresh cache was reused (sentinel survives) ...
  expect_true(any(result$pmc$ctl == -999999, na.rm = TRUE))
  # ... and the file was not rewritten.
  mtime_after <- file.info(env$cache_path)$mtime
  expect_equal(mtime_before, mtime_after)
})

# --- Invalidation triggers ----------------------------------------------------

test_that("load_overview_metrics invalidates when summaries.RData mtime changes", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  load_overview_metrics(test_summaries_ov, test_health_ov,
                        cache_path = env$cache_path)
  load(env$cache_path)
  overview_cache$pmc$ctl[1] <- -999999
  save(overview_cache, file = env$cache_path)

  # Touch summaries.RData so its mtime no longer matches the cache's
  # stored summaries_mtime.
  Sys.sleep(1.1)
  summaries <- test_summaries_ov
  save(summaries, file = file.path(env$root, "cache", "summaries.RData"))

  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  expect_false(any(result$pmc$ctl == -999999, na.rm = TRUE))
})

test_that("load_overview_metrics invalidates when health_daily.RData mtime changes", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  load_overview_metrics(test_summaries_ov, test_health_ov,
                        cache_path = env$cache_path)
  load(env$cache_path)
  overview_cache$pmc$ctl[1] <- -999999
  save(overview_cache, file = env$cache_path)

  Sys.sleep(1.1)
  health_daily <- test_health_ov
  save(health_daily, file = file.path(env$root, "cache", "health_daily.RData"))

  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  expect_false(any(result$pmc$ctl == -999999, na.rm = TRUE))
})

test_that("load_overview_metrics invalidates a cache with a stale built_date", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  load_overview_metrics(test_summaries_ov, test_health_ov,
                        cache_path = env$cache_path)
  load(env$cache_path)
  overview_cache$pmc$ctl[1] <- -999999
  overview_cache$built_date <- Sys.Date() - 1
  save(overview_cache, file = env$cache_path)

  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  expect_false(any(result$pmc$ctl == -999999, na.rm = TRUE))
  # And the rebuilt cache should now be stamped with today's date.
  load(env$cache_path)
  expect_equal(overview_cache$built_date, Sys.Date())
})

# --- Corrupt / missing cache --------------------------------------------------

test_that("load_overview_metrics treats a corrupt cache file as a miss, not an error", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  writeLines("not an RData file", env$cache_path)
  expect_error(
    result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                    cache_path = env$cache_path),
    NA
  )
  expect_type(result, "list")
  expect_s3_class(result$pmc, "tbl_df")
})

test_that("load_overview_metrics treats a missing cache file as a miss", {
  env <- setup_ov_cache_dir()
  on.exit(env$restore())

  expect_false(file.exists(env$cache_path))
  result <- load_overview_metrics(test_summaries_ov, test_health_ov,
                                  cache_path = env$cache_path)
  expect_s3_class(result$pmc, "tbl_df")
})
