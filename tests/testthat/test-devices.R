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

test_that("read_device_log treats every origin value identically", {
  path <- .write_devices_csv(c(
    "2026-01-01,apple_watch,Ultra 2,watchOS 26.6,exact,healthkit,Från HealthKit-export",
    "2025-06-01,garmin,Forerunner 965,20.34,known_since,tcx,Härlett från TCX <Creator>",
    "2024-01-01,garmin,Forerunner 235,9.0,exact,manual,",
    "2020-01-01,apple_watch,Ultra,watchOS 6,exact,fit,"
  ))
  out <- read_device_log(path)
  expect_equal(out$origin, c("healthkit", "tcx", "manual", "fit"))
  # No R/Vayu logic branches on origin — device_changes() filtering by
  # platform/date must not discriminate against any origin value.
  gc <- device_changes(out, platform = "garmin")
  expect_equal(nrow(gc), 2)
  expect_true("tcx" %in% gc$origin)
  aw <- device_changes(out, platform = "apple_watch")
  expect_equal(nrow(aw), 2)
  expect_true("healthkit" %in% aw$origin)
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

# --- .collapse_same_day_rows(): at most one row per (platform, day) ---
#
# Nagelfar regression: an Apple Watch Ultra (gen 1) arrived on watchOS
# 9.0.1 and updated itself to 9.1 later the same day. devices.csv only
# carries a date, so a dirty file with both rows misorders whichever
# consumer sorts by valid_from alone — Vayu's device-change note once
# read that as a fictitious downgrade to 9.0.1. read_device_log()
# collapses this defensively; python/traning_cli/devices/log.py's
# write_devices() is the primary enforcement point.

test_that("read_device_log collapses the exact kailash same-day case", {
  path <- .write_devices_csv(c(
    "2022-10-06,apple_watch,Apple Watch Ultra (gen 1),9.0.1,exact,healthkit,healthkit-scan: export.xml",
    "2022-10-06,apple_watch,Apple Watch Ultra (gen 1),9.1,exact,healthkit,healthkit-scan: export.xml",
    "2022-09-14,apple_watch,Apple Watch Series 4,9.1,exact,healthkit,healthkit-scan: export.xml"
  ))
  out <- read_device_log(path)
  expect_equal(nrow(out), 2)

  ultra_row <- out[out$valid_from == as.Date("2022-10-06"), ]
  expect_equal(ultra_row$os_version, "9.1")
  expect_equal(ultra_row$model, "Apple Watch Ultra (gen 1)")
  expect_match(ultra_row$note, "samma dag: 9.0.1")
  expect_equal(ultra_row$certainty, "exact")
  expect_equal(ultra_row$origin, "healthkit")
})

test_that(".collapse_same_day_rows leaves single rows untouched", {
  log <- read_device_log(.write_devices_csv(c(
    "2026-01-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,",
    "2025-01-01,garmin,Forerunner 965,20.34,exact,manual,"
  )))
  expect_equal(nrow(log), 2)
})

test_that(".collapse_same_day_rows is order-independent (highest version wins)", {
  a <- "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,"
  b <- "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,"
  out1 <- read_device_log(.write_devices_csv(c(a, b)))
  out2 <- read_device_log(.write_devices_csv(c(b, a)))
  expect_equal(out1$os_version, "9.1")
  expect_equal(out2$os_version, "9.1")
})

test_that(".collapse_same_day_rows names every collapsed loser in the note", {
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.0.2,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,"
  )))
  expect_equal(nrow(log), 1)
  expect_equal(log$os_version, "9.1")
  expect_match(log$note, "samma dag: 9.0.1")
  expect_match(log$note, "samma dag: 9.0.2")
})

test_that(".collapse_same_day_rows handles three-part versions correctly", {
  # 9.10 must outrank 9.9 — plain string comparison ("9.10" < "9.9"
  # character-by-character) would get this backwards.
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.10,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.9,exact,healthkit,"
  )))
  expect_equal(log$os_version, "9.10")
})

test_that(".collapse_same_day_rows keeps platforms separate on the same day", {
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,",
    "2022-10-06,garmin,Forerunner 965,20.34,exact,fit,"
  )))
  expect_equal(nrow(log), 2)
  expect_setequal(log$platform, c("apple_watch", "garmin"))
})

test_that(".collapse_same_day_rows is idempotent", {
  path <- .write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,",
    "2020-01-01,apple_watch,Series 3,watchOS 6,exact,manual,"
  ))
  once <- read_device_log(path)
  # Re-collapsing an already-collapsed log must be a no-op.
  twice <- .collapse_same_day_rows(once)
  expect_equal(once, twice)
})

# --- Nagelfar rond 2: device swap must beat version, not the other way
# round, once a previous day establishes which model was already current.

test_that("(a) device swap beats a higher version on the old model", {
  # The exact regression: Series 4 (9.1) was already current as of the
  # previous day; an Ultra arrives on a LOWER os_version (9.0.1) the same
  # day Series 4 also logs a bump to 9.1 again. The swap into the new
  # device is the day's real change, even though its version number is
  # lower — must NOT resolve to "highest version" here.
  log <- read_device_log(.write_devices_csv(c(
    "2022-09-14,apple_watch,Series 4,9.1,exact,healthkit,",
    "2022-10-06,apple_watch,Series 4,9.1,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,"
  )))
  expect_equal(nrow(log), 2)
  same_day <- log[log$valid_from == as.Date("2022-10-06"), ]
  expect_equal(same_day$model, "Ultra")
  expect_equal(same_day$os_version, "9.0.1")
  expect_match(same_day$note, "samma dag: Series 4 9.1")
})

test_that("(b) same device swap case, framed as 'no time on file'", {
  # .collapse_same_day_rows() never has time info regardless of where
  # the rows came from, so this is really the same code path as (a);
  # kept as its own test since it's the literal regression framing
  # ("rader på fil utan tid").
  log <- read_device_log(.write_devices_csv(c(
    "2022-09-14,apple_watch,Series 4,9.1,exact,manual,",
    "2022-10-06,apple_watch,Series 4,9.1,exact,manual,",
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,manual,"
  )))
  same_day <- log[log$valid_from == as.Date("2022-10-06"), ]
  expect_equal(same_day$model, "Ultra")
  expect_equal(same_day$os_version, "9.0.1")
})

test_that("(c) unchanged: a single-model same-day pair still uses version", {
  # The pre-nagelfar-rond-2 case must resolve exactly as before: a
  # single model with two same-day os_version candidates still picks
  # the higher version (there's no swap to detect — rule 2 doesn't
  # apply when the whole group shares one model).
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,"
  )))
  expect_equal(nrow(log), 1)
  expect_equal(log$os_version, "9.1")
  expect_match(log$note, "samma dag: 9.0.1")
})

# --- Nagelfar issue-001: note dedup and manual-note preservation -----------

test_that(".merge_day_group does not duplicate an already-absorbed note phrase", {
  # Simulates a dirty file where the winner already carries "samma dag:
  # 9.0.1" (from an earlier collapse) and the same loser is somehow
  # still present as its own row — the note must not gain a second
  # copy of the same phrase on re-collapse.
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,samma dag: 9.0.1",
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,healthkit,"
  )))
  expect_equal(nrow(log), 1)
  expect_equal(lengths(regmatches(log$note, gregexpr("samma dag: 9.0.1", log$note))), 1)
})

test_that(".merge_day_group preserves a loser's own manual note", {
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,manual,viktig anteckning"
  )))
  expect_equal(nrow(log), 1)
  expect_match(log$note, "viktig anteckning", fixed = TRUE)
})

test_that("mixed-model same day with no previous day falls back to version", {
  # No previous day on record for this platform at all -> rule 2 has
  # nothing to compare against, falls through to rule 3.
  log <- read_device_log(.write_devices_csv(c(
    "2022-10-06,apple_watch,Series 4,9.0,exact,healthkit,",
    "2022-10-06,apple_watch,Ultra,9.1,exact,healthkit,"
  )))
  expect_equal(nrow(log), 1)
  expect_equal(log$model, "Ultra")
  expect_match(log$note, "samma dag: Series 4 9.0")
})

# --- (e) R/Python parity: same fixture, same collapse result ----------------
#
# Content equivalence, not row-order equivalence — R's .collapse_same_day_
# rows() returns newest-first (matching read_device_log()'s established
# convention), Python's collapse_same_day_rows() returns oldest-first
# (matching its other callers, see log.py); each language's own tests
# already pin its own order. What must match across languages is WHICH
# row wins each day and what ends up in its note.

test_that("(e) R matches Python's collapse_same_day_rows on the swap fixture", {
  # Python (python/tests/test_device_log.py, same fixture):
  #   test_collapse_same_day_rows_device_swap_beats_higher_version_on_old_model
  # gives: 2022-09-14 Series 4 9.1 (unchanged); 2022-10-06 Ultra 9.0.1,
  # note "samma dag: Series 4 9.1". Pinned here so a change to either
  # implementation that breaks parity fails a test in both suites.
  log <- read_device_log(.write_devices_csv(c(
    "2022-09-14,apple_watch,Series 4,9.1,exact,manual,",
    "2022-10-06,apple_watch,Series 4,9.1,exact,manual,",
    "2022-10-06,apple_watch,Ultra,9.0.1,exact,manual,"
  )))
  by_date <- setNames(seq_len(nrow(log)), as.character(log$valid_from))

  early <- log[by_date[["2022-09-14"]], ]
  expect_equal(early$model, "Series 4")
  expect_equal(early$os_version, "9.1")
  expect_equal(early$note, "")

  swap_day <- log[by_date[["2022-10-06"]], ]
  expect_equal(swap_day$model, "Ultra")
  expect_equal(swap_day$os_version, "9.0.1")
  expect_equal(swap_day$note, "samma dag: Series 4 9.1")
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

# --- is_model_change: classified against full history, not the window ---
#
# Regression coverage for the skarp-drift bug reported against kailash's
# get_resting_hr(after="-6m"): a real device swap (into "Ultra (gen 1)")
# happened before the requested window; three watchOS bumps on that same
# watch then land inside it. The oldest of those three has no older
# neighbour WITHIN the window, but device_changes() must still see the
# pre-window swap row (present in the full log passed in) and correctly
# classify all three as firmware bumps, not "the row before the window
# doesn't exist so I must be a swap."

test_that("device_changes classifies a window's oldest row using history before the window", {
  log <- read_device_log(.write_devices_csv(c(
    "2026-07-29,apple_watch,Apple Watch Ultra (gen 1),26.6,exact,healthkit,",
    "2026-05-17,apple_watch,Apple Watch Ultra (gen 1),26.5,exact,healthkit,",
    "2026-03-30,apple_watch,Apple Watch Ultra (gen 1),26.4,exact,healthkit,",
    "2025-01-10,apple_watch,Apple Watch Ultra (gen 1),25.0,exact,healthkit,",
    "2022-09-23,apple_watch,Apple Watch Series 4,20.0,exact,healthkit,"
  )))
  # Mirrors get_resting_hr(after="-6m"): a window that only contains the
  # three watchOS bumps, not the swap into Ultra (gen 1) that precedes it.
  ch <- device_changes(log, platform = "apple_watch", after = as.Date("2026-01-01"))
  expect_equal(nrow(ch), 3)
  expect_equal(ch$is_model_change, c(FALSE, FALSE, FALSE))
})

test_that("device_changes still flags a genuine swap at the very start of the log", {
  log <- read_device_log(.write_devices_csv(
    "2022-09-23,apple_watch,Apple Watch Ultra (gen 1),19.0,exact,healthkit,"
  ))
  ch <- device_changes(log, platform = "apple_watch")
  expect_true(ch$is_model_change)
})

test_that("device_changes classifies per platform independently", {
  log <- read_device_log(.write_devices_csv(c(
    "2026-01-01,apple_watch,Ultra 2,watchOS 26.6,exact,manual,",
    "2025-06-01,garmin,Forerunner 965,20.34,exact,manual,",
    "2024-01-01,garmin,Forerunner 235,9.0,exact,manual,"
  )))
  ch <- device_changes(log) # no platform filter: both platforms present
  expect_true(all(ch$is_model_change)) # each platform's oldest-in-view row is a real swap
})

test_that(".device_change_layers doesn't label a boundary firmware row as a swap", {
  # Same shape as the device_changes() regression above, but exercised
  # through the plot layer: with >many_threshold rows in view, the
  # boundary row must stay unlabelled (dotted line), not get a text
  # label as if it were the device's introduction.
  log <- read_device_log(.write_devices_csv(c(
    "2026-08-01,apple_watch,Apple Watch Ultra (gen 1),26.7,exact,healthkit,",
    "2026-07-01,apple_watch,Apple Watch Ultra (gen 1),26.6,exact,healthkit,",
    "2026-06-01,apple_watch,Apple Watch Ultra (gen 1),26.5,exact,healthkit,",
    "2026-05-01,apple_watch,Apple Watch Ultra (gen 1),26.4,exact,healthkit,",
    "2026-04-01,apple_watch,Apple Watch Ultra (gen 1),26.3,exact,healthkit,",
    "2026-03-01,apple_watch,Apple Watch Ultra (gen 1),26.2,exact,healthkit,",
    "2026-02-01,apple_watch,Apple Watch Ultra (gen 1),26.1,exact,healthkit,",
    # Buffer row: same watch, just before the window queried below — this
    # is what makes 2026-02-01 (the window's oldest row) a bump, not a
    # swap. Without it, 2026-02-01 would be the genuine transition point.
    "2026-01-01,apple_watch,Apple Watch Ultra (gen 1),26.0,exact,healthkit,",
    # The real swap: further outside the window still.
    "2020-01-01,apple_watch,Apple Watch Series 4,20.0,exact,healthkit,"
  )))
  ch <- device_changes(log, platform = "apple_watch", after = as.Date("2026-01-15"))
  expect_equal(nrow(ch), 7) # > many_threshold (6)
  expect_false(any(ch$is_model_change)) # every row in view is a bump on the same watch
  layers <- .device_change_layers(ch)
  text_layer <- Filter(function(l) inherits(l$geom, "GeomText"), layers)
  expect_equal(nrow(text_layer[[1]]$data), 0) # no swaps in view -> nothing labelled
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

# --- Many changes (20+ firmware bumps): label thinning ---

.make_many_changes <- function(n = 25) {
  model_names <- c("Forerunner 235", "Forerunner 965", "Fenix 8")
  models <- model_names[cut(seq_len(n), 3, labels = FALSE)]
  dates <- seq(as.Date("2010-01-01"), as.Date("2025-01-01"), length.out = n)
  tibble::tibble(
    valid_from = dates,
    platform = "garmin",
    model = models,
    os_version = paste0("v", seq_len(n), ".0"),
    certainty = "exact",
    origin = "fit",
    note = ""
  ) |> dplyr::arrange(dplyr::desc(valid_from))
}

test_that(".is_device_model_change flags only genuine device swaps", {
  changes <- .make_many_changes(25)
  flags <- .is_device_model_change(changes)
  expect_equal(sum(flags), 3)
  expect_equal(changes$model[flags], c("Fenix 8", "Forerunner 965", "Forerunner 235"))
})

test_that(".is_device_model_change handles a single row (no older neighbour)", {
  changes <- .make_many_changes(25)[1, ]
  expect_true(.is_device_model_change(changes))
})

test_that(".is_device_model_change treats an empty model as never a labelled swap", {
  changes <- .make_many_changes(3)
  changes$model[1] <- ""
  flags <- .is_device_model_change(changes)
  expect_false(flags[1])
})

test_that(".device_change_layers labels only device swaps above many_threshold", {
  changes <- .make_many_changes(25)
  layers <- .device_change_layers(changes)
  # 3 labelled vlines + 1 geom_text (3 rows) + 1 unlabelled vline (22 rows)
  expect_length(layers, 3)
  text_layer <- Filter(function(l) inherits(l$geom, "GeomText"), layers)
  expect_length(text_layer, 1)
  expect_equal(nrow(text_layer[[1]]$data), 3)
})

test_that(".device_change_layers labels every row at or below many_threshold", {
  changes <- .make_many_changes(6)
  layers <- .device_change_layers(changes)
  text_layer <- Filter(function(l) inherits(l$geom, "GeomText"), layers)
  expect_equal(nrow(text_layer[[1]]$data), 6)
  # No separate "unlabelled" vline layer needed when nothing is thinned.
  expect_length(layers, 2)
})

test_that("fetch.plot.ef renders successfully with 25 device changes in range", {
  summaries <- .make_ef_summaries(200)
  changes <- .make_many_changes(25)
  # Spread the fixture's dates across the summaries' actual span so every
  # row falls inside the plotted window.
  span <- range(as.Date(summaries$sessionStart))
  changes$valid_from <- seq(span[1], span[2], length.out = nrow(changes))
  path <- .write_devices_csv(paste(
    format(changes$valid_from), changes$platform, changes$model,
    changes$os_version, changes$certainty, changes$origin, changes$note,
    sep = ","
  ))
  data_root <- dirname(dirname(path))

  withr::with_envvar(c(TRANING_DATA = data_root), {
    p <- fetch.plot.ef(summaries)
    expect_no_error(ggplot2::ggplot_build(p))
  })
})
