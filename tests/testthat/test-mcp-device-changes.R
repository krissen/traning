# Tests for the device-change annotation added to the MCP bridge's data
# envelope (inst/mcp_bridge_shared.R: .DEVICE_CHANGE_FUNCS /
# .attach_device_changes()). Sources the shared file directly rather
# than spawning the bridge subprocess (see test-mcp-bridge.R) — no
# dependency on a real TRANING_DATA checkout.

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

test_that(".attach_device_changes is a no-op for functions not in the map", {
  envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
  out <- .attach_device_changes(envelope, "report_monthtop", list())
  expect_null(out$device_changes)
  expect_identical(out, envelope)
})

test_that(".attach_device_changes is a no-op when there is no device log", {
  withr::with_envvar(c(TRANING_DATA = tempfile()), {
    envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
    out <- .attach_device_changes(envelope, "report_readiness", list())
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
      list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01"))
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

    out_ef <- .attach_device_changes(envelope, "report_ef", args)
    expect_equal(nrow(out_ef$device_changes), 1)

    out_dc <- .attach_device_changes(envelope, "report_decoupling", args)
    expect_equal(nrow(out_dc$device_changes), 1)
  })
})

test_that(".attach_device_changes respects call_args$from/to bounds", {
  data_root <- .write_mcp_devices_csv(
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,"
  )
  withr::with_envvar(c(TRANING_DATA = data_root), {
    envelope <- list(type = "data", rows = 1, data = data.frame(x = 1))
    out <- .attach_device_changes(
      envelope, "report_readiness",
      list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01"))
    )
    expect_null(out$device_changes)
  })
})

test_that("run_dispatch attaches device_changes to a data-frame result", {
  data_root <- .write_mcp_devices_csv(
    "2025-09-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,Ny klocka"
  )
  # do.call() inside run_dispatch resolves func_name via match.fun(),
  # which walks up through enclosing/global environments but not into
  # this test_that() closure — the dummy function has to live in
  # .GlobalEnv for the lookup to find it.
  assign(".dummy_report_devicetest",
    function(data = NULL, from = NULL, to = NULL) data.frame(x = 1),
    envir = .GlobalEnv
  )
  withr::defer(rm(".dummy_report_devicetest", envir = .GlobalEnv))
  # Register it under a name .attach_device_changes recognises, mirroring
  # report_readiness's mapping — this test exercises run_dispatch's wiring,
  # not the platform-mapping logic (already covered above).
  old_map <- .DEVICE_CHANGE_FUNCS
  .DEVICE_CHANGE_FUNCS[[".dummy_report_devicetest"]] <<- "apple_watch"
  withr::defer(.DEVICE_CHANGE_FUNCS <<- old_map)

  withr::with_envvar(c(TRANING_DATA = data_root), {
    resp <- run_dispatch(
      ".dummy_report_devicetest",
      list(from = as.Date("2025-01-01"), to = as.Date("2026-01-01")),
      do_plot = FALSE, plot_path = NULL
    )
    expect_equal(resp$type, "data")
    expect_equal(nrow(resp$device_changes), 1)
  })
})
