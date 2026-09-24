# Tests for R/devices.R — device log read/query and plot annotation
# layers.

.write_devices_csv <- function(rows) {
  dir <- tempfile()
  dir.create(file.path(dir, "kristian"), recursive = TRUE)
  path <- file.path(dir, "kristian", "devices.csv")
  writeLines(c(
    "valid_from,platform,model,os_version,certainty,origin,note",
    rows
  ), path)
  path
}

# --- read_device_log() ---

test_that("read_device_log returns empty typed tibble for missing file", {
  out <- read_device_log(file.path(tempfile(), "devices.csv"))
  expect_equal(nrow(out), 0)
  expect_named(
    out,
    c("valid_from", "platform", "model", "os_version", "certainty", "origin", "note")
  )
  expect_s3_class(out$valid_from, "Date")
})

test_that("read_device_log returns empty tibble for header-only file", {
  path <- .write_devices_csv(character())
  out <- read_device_log(path)
  expect_equal(nrow(out), 0)
})

test_that("read_device_log parses a valid file, newest first", {
  path <- .write_devices_csv(c(
    "2025-01-15,apple_watch,Ultra,watchOS 11.2,known_since,fit,",
    "2026-06-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,Ny klocka",
    "2024-03-10,garmin,Forerunner 965,20.34,exact,manual,Firmware"
  ))
  out <- read_device_log(path)
  expect_equal(nrow(out), 3)
  expect_equal(out$valid_from, as.Date(c("2026-06-01", "2025-01-15", "2024-03-10")))
  expect_equal(out$platform, c("apple_watch", "apple_watch", "garmin"))
  expect_equal(out$model[out$valid_from == "2025-01-15"], "Ultra")
})

test_that("read_device_log falls back to empty tibble on unexpected schema", {
  dir <- tempfile()
  dir.create(file.path(dir, "kristian"), recursive = TRUE)
  path <- file.path(dir, "kristian", "devices.csv")
  writeLines(c("date,brand", "2025-01-01,Garmin"), path)
  expect_warning(out <- read_device_log(path), "missing expected column")
  expect_equal(nrow(out), 0)
})

test_that("read_device_log resolves the default TRANING_DATA path", {
  path <- .write_devices_csv(
    "2025-05-01,garmin,Forerunner 965,19.0,exact,manual,"
  )
  data_root <- dirname(dirname(path))
  withr::with_envvar(c(TRANING_DATA = data_root), {
    out <- read_device_log()
    expect_equal(nrow(out), 1)
    expect_equal(out$platform, "garmin")
  })
})

# --- device_changes() ---

test_that("device_changes filters by platform", {
  log <- read_device_log(.write_devices_csv(c(
    "2026-06-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,",
    "2024-03-10,garmin,Forerunner 965,20.34,exact,manual,"
  )))
  aw <- device_changes(log, platform = "apple_watch")
  expect_equal(nrow(aw), 1)
  expect_equal(aw$platform, "apple_watch")
})

test_that("device_changes filters by after/before, inclusive", {
  log <- read_device_log(.write_devices_csv(c(
    "2026-06-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,",
    "2025-01-15,apple_watch,Ultra,watchOS 11.2,known_since,fit,",
    "2024-03-10,garmin,Forerunner 965,20.34,exact,manual,"
  )))
  out <- device_changes(log, after = "2025-01-15", before = "2026-06-01")
  expect_equal(nrow(out), 2)
  out_exact <- device_changes(log, after = "2025-01-15", before = "2025-01-15")
  expect_equal(nrow(out_exact), 1)
})

test_that("device_changes on an empty log returns an empty tibble", {
  out <- device_changes(.empty_device_log(), platform = "apple_watch")
  expect_equal(nrow(out), 0)
})

test_that("device_changes with no matches in range returns empty tibble", {
  log <- read_device_log(.write_devices_csv(
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,"
  ))
  out <- device_changes(log, after = "2025-01-01")
  expect_equal(nrow(out), 0)
})

# --- Plot integration: built with and without a device log ---

.make_rhr_bundle <- function() {
  dates <- seq(as.Date("2025-06-01"), as.Date("2026-01-01"), by = "day")
  hd <- tibble::tibble(
    date = dates,
    metric = "resting_heart_rate",
    value = 50 + sin(seq_along(dates) / 10) * 2
  )
  traning_data(
    summaries = tibble::tibble(sessionStart = as.POSIXct(character())),
    health_daily = hd
  )
}

test_that("fetch.plot.resting_hr adds a device layer when the log has a matching change", {
  td <- .make_rhr_bundle()
  path <- .write_devices_csv(
    "2025-09-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,Ny klocka"
  )
  data_root <- dirname(dirname(path))

  withr::with_envvar(c(TRANING_DATA = data_root), {
    with_log <- fetch.plot.resting_hr(td)
    without_log <- fetch.plot.resting_hr(td, show_devices = FALSE)
    expect_gt(length(with_log$layers), length(without_log$layers))
  })
})

test_that("fetch.plot.resting_hr is unchanged when the log has no matching change", {
  td <- .make_rhr_bundle()
  # Change is outside the plotted range entirely.
  path <- .write_devices_csv(
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,"
  )
  data_root <- dirname(dirname(path))

  withr::with_envvar(c(TRANING_DATA = data_root), {
    with_log <- fetch.plot.resting_hr(td)
    without_log <- fetch.plot.resting_hr(td, show_devices = FALSE)
    expect_equal(length(with_log$layers), length(without_log$layers))
  })
})

test_that("fetch.plot.resting_hr is unchanged when there is no device log at all", {
  td <- .make_rhr_bundle()
  withr::with_envvar(c(TRANING_DATA = tempfile()), {
    with_log <- fetch.plot.resting_hr(td)
    without_log <- fetch.plot.resting_hr(td, show_devices = FALSE)
    expect_equal(length(with_log$layers), length(without_log$layers))
  })
})

.make_ef_summaries <- function(n = 40) {
  dates <- seq(Sys.Date() - 2 * n, Sys.Date() - 1, by = 2)[1:n]
  tibble::tibble(
    sessionStart = as.POSIXct(dates),
    sport = "running",
    distance = stats::runif(n, 8000, 15000),
    avgSpeedMoving = stats::runif(n, 2.5, 3.0),
    avgHeartRateMoving = stats::runif(n, 140, 160)
  )
}

test_that("fetch.plot.ef adds a device layer for a matching Garmin change", {
  summaries <- .make_ef_summaries()
  mid_date <- summaries$sessionStart[nrow(summaries) %/% 2]
  path <- .write_devices_csv(paste0(
    format(as.Date(mid_date)), ",garmin,Forerunner 965,20.34,exact,manual,Firmware"
  ))
  data_root <- dirname(dirname(path))

  withr::with_envvar(c(TRANING_DATA = data_root), {
    with_log <- fetch.plot.ef(summaries)
    without_log <- fetch.plot.ef(summaries, show_devices = FALSE)
    expect_gt(length(with_log$layers), length(without_log$layers))
  })
})

test_that("fetch.plot.ef ignores Apple Watch changes (Garmin-only overlay)", {
  summaries <- .make_ef_summaries()
  mid_date <- summaries$sessionStart[nrow(summaries) %/% 2]
  path <- .write_devices_csv(paste0(
    format(as.Date(mid_date)), ",apple_watch,Ultra 2,watchOS 26.6,exact,manual,"
  ))
  data_root <- dirname(dirname(path))

  withr::with_envvar(c(TRANING_DATA = data_root), {
    with_log <- fetch.plot.ef(summaries)
    without_log <- fetch.plot.ef(summaries, show_devices = FALSE)
    expect_equal(length(with_log$layers), length(without_log$layers))
  })
})

# --- .device_change_layers() / .device_change_label() ---

test_that(".device_change_layers returns an empty list for zero-row input", {
  expect_equal(.device_change_layers(.empty_device_log()), list())
})

test_that(".device_change_label prefers model + os_version, falls back sensibly", {
  changes <- tibble::tibble(
    model = c("Ultra 2", "Ultra 2", "", ""),
    os_version = c("watchOS 26.6", "", "watchOS 26.6", ""),
    note = c("x", "x", "x", "Ny enhet")
  )
  labels <- .device_change_label(changes)
  expect_equal(labels[1], "Ultra 2 · watchOS 26.6")
  expect_equal(labels[2], "Ultra 2")
  expect_equal(labels[3], "watchOS 26.6")
  expect_equal(labels[4], "Ny enhet")
})
