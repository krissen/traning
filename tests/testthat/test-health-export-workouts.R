# Tests for R/health_export_workouts.R

# --- Fixtures -----------------------------------------------------------------

.write_hae <- function(dir, name, time_str, name_field, distance_km, duration_s,
                      avg_hr = 130, location = "Utomhus", indoor = FALSE) {
  payload <- list(
    data = list(
      workouts = list(
        list(
          id = paste0("test-", name),
          name = name_field,
          location = location,
          isIndoor = indoor,
          start = time_str,
          end = time_str,  # close enough for tests
          duration = duration_s,
          distance = list(qty = distance_km, units = "km"),
          avgHeartRate = if (is.null(avg_hr)) NULL else
            list(qty = avg_hr, units = "count/min"),
          speed = list(qty = distance_km / (duration_s / 3600), units = "km/hr")
        )
      )
    )
  )
  path <- file.path(dir, paste0(name, ".json"))
  jsonlite::write_json(payload, path, auto_unbox = TRUE, null = "null")
  path
}

# --- Sport mapping (via public parse_hae_workout) -----------------------------

.sport_for_name <- function(name_field) {
  tmp <- withr::local_tempdir()
  path <- .write_hae(tmp, "x", "2026-04-06 12:00:00 +0200",
                     name_field, distance_km = 1.0, duration_s = 600)
  parse_hae_workout(path)$sport
}

test_that("sport mapping recognises Swedish workout names", {
  expect_equal(.sport_for_name("Utomhus Kör"), "running")
  expect_equal(.sport_for_name("Inomhus Kör"), "running")
  expect_equal(.sport_for_name("Löpning"), "running")
  expect_equal(.sport_for_name("Utomhus Cykling"), "cycling")
  expect_equal(.sport_for_name("Inomhus Cykling"), "cycling")
  expect_equal(.sport_for_name("Utomhus Gång"), "walking")
  expect_equal(.sport_for_name("Promenad"), "walking")
  expect_equal(.sport_for_name("Simning"), "swimming")
  expect_equal(.sport_for_name("Styrketräning"), "strength")
  expect_equal(.sport_for_name("Yoga"), "yoga")
})

# --- parse_hae_workout --------------------------------------------------------

test_that("parse_hae_workout reads a running file correctly", {
  tmp <- withr::local_tempdir()
  path <- .write_hae(tmp, "run1", "2026-04-06 15:44:06 +0200",
                     "Utomhus Kör", distance_km = 8.0, duration_s = 2400,
                     avg_hr = 140)
  row <- parse_hae_workout(path)
  expect_equal(nrow(row), 1)
  expect_equal(row$sport, "running")
  expect_equal(row$source, "hae")
  expect_equal(row$distance, 8000)
  expect_s3_class(row$duration, "difftime")
  expect_equal(as.numeric(row$duration, units = "secs"), 2400)
  expect_equal(as.numeric(row$durationMoving, units = "mins"), 40)
  expect_equal(row$avgHeartRate, 140)
  expect_equal(row$avgHeartRateMoving, 140)
  expect_match(row$file, "^hae:run1\\.json$")
  # Pace 5 min/km: 2400s / 8km = 300s/km = 5 min/km
  expect_equal(row$avgPace, 5)
  # Speed in m/s = distance/duration
  expect_equal(row$avgSpeed, 8000 / 2400)
})

test_that("parse_hae_workout reads cycling and walking", {
  tmp <- withr::local_tempdir()
  cyk <- .write_hae(tmp, "cyk1", "2026-04-09 08:02:26 +0200",
                    "Utomhus Cykling", distance_km = 25.0, duration_s = 3600)
  gng <- .write_hae(tmp, "gng1", "2026-04-06 10:08:34 +0200",
                    "Utomhus Gång", distance_km = 2.0, duration_s = 1800)
  expect_equal(parse_hae_workout(cyk)$sport, "cycling")
  expect_equal(parse_hae_workout(gng)$sport, "walking")
})

test_that("parse_hae_workout handles anomaly file (null fields)", {
  tmp <- withr::local_tempdir()
  path <- .write_hae(tmp, "lop1", "2026-04-06 07:00:35 +0200",
                     "Löpning", distance_km = 5.2, duration_s = 2665,
                     avg_hr = NULL, location = NULL, indoor = NULL)
  row <- parse_hae_workout(path)
  expect_equal(row$sport, "running")
  expect_equal(row$distance, 5200)
  expect_true(is.na(row$avgHeartRate))
})

test_that("parse_hae_workout returns NULL for invalid JSON", {
  tmp <- withr::local_tempdir()
  path <- file.path(tmp, "garbage.json")
  writeLines("{ not valid", path)
  expect_null(parse_hae_workout(path))
})

test_that("parse_hae_workout returns NULL when start/duration missing", {
  tmp <- withr::local_tempdir()
  payload <- list(data = list(workouts = list(list(name = "Utomhus Kör"))))
  path <- file.path(tmp, "missing.json")
  jsonlite::write_json(payload, path, auto_unbox = TRUE, null = "null")
  expect_null(parse_hae_workout(path))
})

# --- import_hae_workouts (dedup) ----------------------------------------------

test_that("import_hae_workouts dedups against TCX with same sport", {
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "run1", "2026-04-06 15:44:30 +0200",
             "Utomhus Kör", distance_km = 8.0, duration_s = 2400)

  # Existing summaries with a TCX row 24s before the HAE start
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-04-06 15:44:06 +0200",
                              format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC"),
    sport = "running",
    distance = 8050,
    file = "20260406-running.tcx",
    source = "tcx",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list())
  expect_equal(res$n_imported, 0)
  expect_equal(res$n_skipped_dup, 1)
  expect_equal(nrow(res$summaries), 1)  # unchanged
})

test_that("import_hae_workouts dedups across sport buckets too", {
  # Apple Watch sometimes labels a slow jog as "Utomhus Gång" while Garmin
  # records it as running.  Dedup is time-only; sport mismatch must not
  # cause the duplicate row to slip through.
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "gng1", "2026-04-06 15:44:30 +0200",
             "Utomhus Gång", distance_km = 12.0, duration_s = 1800)

  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-04-06 15:44:06 +0200",
                              format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC"),
    sport = "running",
    distance = 12050,
    file = "20260406-running.tcx",
    source = "tcx",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list())
  expect_equal(res$n_imported, 0)
  expect_equal(res$n_skipped_dup, 1)
  expect_equal(nrow(res$summaries), 1)
})

test_that("import_hae_workouts keeps HAE row if Garmin is far away in time", {
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "run1", "2026-04-06 15:44:06 +0200",
             "Utomhus Kör", distance_km = 8.0, duration_s = 2400)

  # Garmin row 5 minutes off -> beyond default 90s tolerance
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-04-06 15:39:00 +0200",
                              format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC"),
    sport = "running",
    distance = 8050,
    file = "20260406-running.tcx",
    source = "tcx",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list())
  expect_equal(res$n_imported, 1)
  expect_equal(res$n_skipped_dup, 0)
})

test_that("import_hae_workouts skips already-imported HAE files", {
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "run1", "2026-04-06 15:44:06 +0200",
             "Utomhus Kör", distance_km = 8.0, duration_s = 2400)

  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-04-06 15:44:06 +0200",
                              format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC"),
    sport = "running",
    distance = 8000,
    file = "hae:run1.json",
    source = "hae",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list())
  expect_equal(res$n_imported, 0)
  expect_equal(res$n_skipped_dup, 0)
})

test_that("import_hae_workouts handles empty summaries", {
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "run1", "2026-04-06 15:44:06 +0200",
             "Utomhus Kör", distance_km = 8.0, duration_s = 2400)
  .write_hae(tmp, "cyk1", "2026-04-09 08:02:26 +0200",
             "Utomhus Cykling", distance_km = 25.0, duration_s = 3600)

  res <- import_hae_workouts(tmp, data.frame(), list())
  expect_equal(res$n_imported, 2)
  expect_equal(res$n_skipped_dup, 0)
  expect_equal(nrow(res$summaries), 2)
  expect_setequal(res$summaries$sport, c("running", "cycling"))
})

test_that("import_hae_workouts ignores non-JSON files in the directory", {
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "run1", "2026-04-06 15:44:06 +0200",
             "Utomhus Kör", distance_km = 8.0, duration_s = 2400)
  # GPX route file should be ignored
  writeLines("<gpx>...</gpx>", file.path(tmp, "Utomhus_Kor-Route-x.gpx"))

  res <- import_hae_workouts(tmp, data.frame(), list())
  expect_equal(res$n_imported, 1)
})
