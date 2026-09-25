# Tests for the device-change annotation added to the MCP bridge's data
# envelope (inst/mcp_bridge_shared.R: .DEVICE_CHANGE_FUNCS /
# .attach_device_changes() / .effective_device_change_bounds()).
# Sources the shared file directly rather than spawning the bridge
# subprocess (see test-mcp-bridge.R) — no dependency on a real
# TRANING_DATA checkout.

source(testthat::test_path("..", "..", "inst", "mcp_bridge_shared.R"), local = TRUE)

.write_mcp_devices_csv <- function(rows) {
  dir <- tempfile()
  dir.create(file.path(dir, "kristian"), recursive = TRUE)
  path <- file.path(dir, "kristian", "devices.csv")
  writeLines(c(
    "valid_from,platform,model,os_version,certainty,origin,note",
    rows
  ), path)
  dirname(dirname(path))
}

# A stand-in for a report_readiness()/report_ef()/report_decoupling()
# result: one "Datum" column (the date column every registered function
# actually uses), rest is irrelevant filler.
.fake_result <- function(dates) {
  data.frame(Datum = as.Date(dates), value = seq_along(dates))
}

test_that(".attach_device_changes is a no-op for functions not in the map", {
  envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
  out <- .attach_device_changes(envelope, "report_monthtop", list(), data.frame(x = 1))
  expect_null(out$device_changes)
  expect_identical(out, envelope)
})

test_that(".attach_device_changes is a no-op when there is no device log", {
  withr::with_envvar(c(TRANING_DATA = tempfile()), {
    envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
    out <- .attach_device_changes(
      envelope, "report_readiness",
      list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01")), data.frame(x = 1)
    )
    expect_null(out$device_changes)
  })
})

test_that(".attach_device_changes adds apple_watch changes for report_readiness", {
  data_root <- .write_mcp_devices_csv(
    "2025-09-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,Ny klocka"
  )
  withr::with_envvar(c(TRANING_DATA = data_root), {
    envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
    out <- .attach_device_changes(
      envelope, "report_readiness",
      list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01")), data.frame(x = 1)
    )
    expect_equal(nrow(out$device_changes), 1)
    expect_equal(out$device_changes$platform, "apple_watch")
  })
})

test_that(".attach_device_changes adds garmin changes for report_ef / report_decoupling", {
  data_root <- .write_mcp_devices_csv(
    "2025-09-01,garmin,Forerunner 965,20.34,exact,manual,Firmware"
  )
  withr::with_envvar(c(TRANING_DATA = data_root), {
    args <- list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01"))
    envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))

    out_ef <- .attach_device_changes(envelope, "report_ef", args, data.frame(x = 1))
    expect_equal(nrow(out_ef$device_changes), 1)

    out_dc <- .attach_device_changes(envelope, "report_decoupling", args, data.frame(x = 1))
    expect_equal(nrow(out_dc$device_changes), 1)
  })
})

test_that(".attach_device_changes respects explicit call_args$from/to bounds", {
  data_root <- .write_mcp_devices_csv(
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,"
  )
  withr::with_envvar(c(TRANING_DATA = data_root), {
    envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
    out <- .attach_device_changes(
      envelope, "report_readiness",
      list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01")), data.frame(x = 1)
    )
    expect_null(out$device_changes)
  })
})

# --- .effective_device_change_bounds() ---

test_that(".effective_device_change_bounds uses call_args when both given", {
  bounds <- .effective_device_change_bounds(
    list(from = as.Date("2025-01-01"), to = as.Date("2025-06-01")),
    .fake_result(c("2020-01-01", "2020-06-01")), # would give a very different range
    "Datum"
  )
  expect_equal(bounds$after, as.Date("2025-01-01"))
  expect_equal(bounds$before, as.Date("2025-06-01"))
})

test_that(".effective_device_change_bounds derives both sides from the result when call_args is empty", {
  bounds <- .effective_device_change_bounds(
    list(),
    .fake_result(c("2025-03-01", "2025-01-10", "2025-06-20")),
    "Datum"
  )
  expect_equal(bounds$after, as.Date("2025-01-10"))
  expect_equal(bounds$before, as.Date("2025-06-20"))
})

test_that(".effective_device_change_bounds derives only the missing side", {
  bounds <- .effective_device_change_bounds(
    list(from = as.Date("2025-01-01")),
    .fake_result(c("2025-02-01", "2025-05-01")),
    "Datum"
  )
  expect_equal(bounds$after, as.Date("2025-01-01")) # from call_args
  expect_equal(bounds$before, as.Date("2025-05-01")) # from result
})

test_that(".effective_device_change_bounds returns NULL/NULL when nothing is derivable", {
  bounds <- .effective_device_change_bounds(list(), data.frame(x = 1), "Datum")
  expect_null(bounds$after)
  expect_null(bounds$before)

  bounds_empty <- .effective_device_change_bounds(list(), .fake_result(character(0)), "Datum")
  expect_null(bounds_empty$after)
  expect_null(bounds_empty$before)
})

# --- n-only call shape (the nagelfar issue-001 regression) ---

test_that(".attach_device_changes scopes an n-only call to the result's own date range", {
  # Two changes: one inside what report_readiness(n=...) actually
  # returned, one long before it. call_args carries only `n` (the real
  # shape tools.py._build_args() sends for get_hrv()/get_resting_hr()/
  # get_sleep()/get_vo2max() with no after/before) — from/to are absent,
  # exactly the gap issue-001 reported.
  data_root <- .write_mcp_devices_csv(c(
    "2025-11-15,apple_watch,Ultra 2,watchOS 26.6,exact,manual,In window",
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,Long before"
  ))
  withr::with_envvar(c(TRANING_DATA = data_root), {
    envelope <- list(type = "data", rows = 3, data = data.frame(x = 1))
    result <- .fake_result(c("2025-11-01", "2025-11-10", "2025-11-20"))
    out <- .attach_device_changes(envelope, "report_readiness", list(n = 14L), result)
    expect_equal(nrow(out$device_changes), 1)
    expect_equal(out$device_changes$note, "In window")
  })
})

test_that(".attach_device_changes omits device_changes for an n-only call with no matches in the result window", {
  data_root <- .write_mcp_devices_csv(
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,"
  )
  withr::with_envvar(c(TRANING_DATA = data_root), {
    envelope <- list(type = "data", rows = 3, data = data.frame(x = 1))
    result <- .fake_result(c("2025-11-01", "2025-11-10", "2025-11-20"))
    out <- .attach_device_changes(envelope, "report_readiness", list(n = 14L), result)
    expect_null(out$device_changes)
  })
})

test_that(".attach_device_changes omits device_changes when neither call_args nor result carry a date", {
  data_root <- .write_mcp_devices_csv(
    "2025-09-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,"
  )
  withr::with_envvar(c(TRANING_DATA = data_root), {
    envelope <- list(type = "data", rows = 0, data = data.frame(x = 1))
    # Empty result, e.g. an all-NA readiness window — no Datum values to derive from.
    out <- .attach_device_changes(
      envelope, "report_readiness", list(n = 14L), .fake_result(character(0))
    )
    expect_null(out$device_changes)
  })
})

# --- run_dispatch() wiring ---

test_that("run_dispatch attaches device_changes scoped to the actual result window", {
  data_root <- .write_mcp_devices_csv(c(
    "2025-09-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,In window",
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,Long before"
  ))
  # do.call() inside run_dispatch resolves func_name via match.fun(),
  # which walks up through enclosing/global environments but not into
  # this test_that() closure — the dummy function has to live in
  # .GlobalEnv for the lookup to find it.
  assign(".dummy_report_devicetest",
    function(data = NULL, n = 14L) {
      data.frame(Datum = as.Date(c("2025-08-15", "2025-09-15")), value = 1:2)
    },
    envir = .GlobalEnv
  )
  withr::defer(rm(".dummy_report_devicetest", envir = .GlobalEnv))
  # Register it under a name .attach_device_changes recognises, mirroring
  # report_readiness's mapping — this test exercises run_dispatch's
  # wiring, not the platform-mapping logic (already covered above).
  old_map <- .DEVICE_CHANGE_FUNCS
  .DEVICE_CHANGE_FUNCS[[".dummy_report_devicetest"]] <<- list(
    platform = "apple_watch", date_col = "Datum"
  )
  withr::defer(.DEVICE_CHANGE_FUNCS <<- old_map)

  withr::with_envvar(c(TRANING_DATA = data_root), {
    # n-only call: no from/to in call_args, mirroring the real MCP shape.
    resp <- run_dispatch(
      ".dummy_report_devicetest",
      list(n = 14L),
      do_plot = FALSE, plot_path = NULL
    )
    expect_equal(resp$type, "data")
    expect_equal(nrow(resp$device_changes), 1)
    expect_equal(resp$device_changes$note, "In window")
  })
})
