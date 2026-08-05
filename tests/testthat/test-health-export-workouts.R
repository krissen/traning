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

test_that("sport mapping covers the full observed HAE name list", {
  # One assertion per name Apple has actually written into the export,
  # so a rename or a slugifier change surfaces as a failing case rather
  # than as a second sport value for the same activity.
  expected <- list(
    "Löpning" = "running", "Kör" = "running",
    "Utomhus Kör" = "running", "Inomhus Kör" = "running",
    "Cykling" = "cycling", "Utomhus Cykling" = "cycling",
    "Gång" = "walking", "Utomhus Gång" = "walking",
    "Inomhus Gång" = "walking", "Vandring" = "walking",
    "Öppet vatten-Simning" = "swimming",
    "Paddelsporter" = "paddelsporter",
    "Rodd" = "rodd",
    "Skridskosporter" = "skridskosporter",
    "Snösporter" = "snosporter",
    "Utförsåkning" = "utforsakning",
    "Funktionell styrketräning" = "strength",
    "Kärnträning" = "karntraning",
    "Yoga" = "yoga",
    "Sinne & kropp" = "sinne_&_kropp",
    "Övrigt" = "ovrigt",
    "Badminton" = "badminton",
    "Bordtennis" = "bordtennis",
    "Tennis" = "tennis",
    "Fotboll" = "fotboll",
    "Hockey" = "hockey",
    "Fitness-spel" = "fitness-spel",
    "Bågskytte" = "bagskytte"
  )
  for (nm in names(expected)) {
    expect_equal(traning:::.hae_sport_from_name(nm), expected[[nm]],
                 info = paste("HAE name:", nm))
    expect_true(traning:::.hae_sport_is_mapped(nm),
                info = paste("HAE name:", nm))
  }
})

test_that("every mapped sport has a Swedish label", {
  # A sport without a label falls back to capitalising the slug, which
  # is what produced "Sinne_&_kropp" in the notification text.
  for (sport in unique(unlist(traning:::.HAE_SPORT_NAMES))) {
    label <- traning::sport_label(sport)
    expect_false(grepl("_", label, fixed = TRUE),
                 info = paste("sport:", sport, "label:", label))
  }
})

test_that("unknown activity types are reported, not silently slugged", {
  expect_false(traning:::.hae_sport_is_mapped("Klättring"))
  expect_equal(traning:::.hae_sport_from_name("Klättring"), "klattring")

  tmp <- withr::local_tempdir()
  .write_hae(tmp, "climb", "2026-04-06 12:00:00 +0200",
             "Klättring", distance_km = 0, duration_s = 3600)
  .write_hae(tmp, "run", "2026-04-07 12:00:00 +0200",
             "Utomhus Kör", distance_km = 8, duration_s = 2400)
  res <- import_hae_workouts(tmp, data.frame(), list())
  expect_equal(res$n_imported, 2L)
  expect_equal(res$n_unmapped_sports, 1L)
  expect_equal(res$unmapped_names, "Klättring")
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

  # Garmin row 306 s off -> beyond the 300 s match window
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

test_that("import_hae_workouts dedups the 2026-08-01 case (107 s apart)", {
  # Apple Watch started ~2 minutes before the Garmin watch. The old
  # ±90 s window let this through and the session showed up twice.
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "run1", "2026-08-01 11:00:49 +0000",
             "Utomhus Kör", distance_km = 5.234, duration_s = 1391)

  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-08-01 11:02:36 +0000",
                              format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC"),
    sport = "running",
    distance = 5292,
    duration = as.difftime(1376, units = "secs"),
    file = "/data/tcx/20260801-110236.tcx",
    source = "tcx",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list())
  expect_equal(res$n_imported, 0)
  expect_equal(res$n_skipped_dup, 1)
})

test_that("import_hae_workouts keeps a different workout inside the window", {
  # Same start minute, but a 3 km walk is not the 12 km run — the
  # distance/duration sanity check must keep both rows.
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "gng1", "2026-04-06 15:44:30 +0200",
             "Utomhus Gång", distance_km = 3.0, duration_s = 1800)

  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-04-06 15:44:06 +0200",
                              format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC"),
    sport = "running",
    distance = 12000,
    duration = as.difftime(3600, units = "secs"),
    file = "20260406-running.tcx",
    source = "tcx",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list())
  expect_equal(res$n_imported, 1)
  expect_equal(res$n_skipped_dup, 0)
})

test_that("import_hae_workouts dedups two HAE files for the same session", {
  # HAE delivers both the Apple Watch recording and the
  # Garmin-Connect-mirrored copy; they land in the same batch.
  tmp <- withr::local_tempdir()
  .write_hae(tmp, "a-native", "2026-04-06 15:44:06 +0200",
             "Utomhus Kör", distance_km = 8.0, duration_s = 2400)
  .write_hae(tmp, "b-mirror", "2026-04-06 15:44:09 +0200",
             "Utomhus Kör", distance_km = 8.02, duration_s = 2398)

  res <- import_hae_workouts(tmp, data.frame(), list())
  expect_equal(res$n_imported, 1)
  expect_equal(res$n_skipped_dup_hae, 1)
  expect_equal(nrow(res$summaries), 1)
  expect_equal(length(res$myruns), 1)
})

# --- .is_same_workout ---------------------------------------------------------

.wk <- function(start, distance = NA_real_, duration = NA_real_,
                end = NA_character_, sport = "running") {
  data.frame(
    sessionStart = as.POSIXct(start, tz = "UTC"),
    sessionEnd = as.POSIXct(end, tz = "UTC"),
    sport = sport,
    distance = distance,
    duration = duration,
    stringsAsFactors = FALSE
  )
}

test_that(".is_same_workout requires a sanity check inside the wide window", {
  a <- .wk("2026-08-01 11:00:49", distance = 5234, duration = 1391)
  expect_true(.is_same_workout(
    a, .wk("2026-08-01 11:02:36", distance = 5292, duration = 1376)))
  # 40 % shorter and 40 % quicker: same clock, different workout
  expect_false(.is_same_workout(
    a, .wk("2026-08-01 11:02:36", distance = 3140, duration = 830)))
  # Distance disagrees but duration matches -> still the same workout
  # (a lost GPS fix shortens distance, not elapsed time)
  expect_true(.is_same_workout(
    a, .wk("2026-08-01 11:02:36", distance = 3140, duration = 1376)))
})

test_that(".is_same_workout falls back to a narrow time-only window", {
  a <- .wk("2026-08-01 11:00:49")
  expect_true(.is_same_workout(a, .wk("2026-08-01 11:02:36")))   # 107 s
  expect_false(.is_same_workout(a, .wk("2026-08-01 11:04:00")))  # 191 s
})

test_that(".is_same_workout is vectorised over the candidate table", {
  a <- .wk("2026-08-01 11:00:49", distance = 5234, duration = 1391)
  cands <- rbind(
    .wk("2026-08-01 09:00:00", distance = 5200, duration = 1380),
    .wk("2026-08-01 11:02:36", distance = 5292, duration = 1376),
    .wk("2026-08-01 11:02:36", distance = 500, duration = 200)
  )
  expect_equal(.is_same_workout(a, cands), c(FALSE, TRUE, FALSE))
})

test_that(".is_same_workout matches a session recorded inside another", {
  # 2026-06-12: the Garmin watch ran 07:50–10:03, the Apple Watch was
  # started 105 minutes in and both were stopped 1 s apart. Starts are
  # far too distant for the start rule; the intervals say it is one
  # session.
  garmin <- .wk("2026-06-12 07:50:00", distance = 24000, duration = 7980,
                end = "2026-06-12 10:03:00")
  watch <- .wk("2026-06-12 09:35:00", distance = 5006, duration = 1679,
               end = "2026-06-12 10:03:01")
  expect_true(.is_same_workout(garmin, watch))

  # Same shape, but the short recording ends half an hour before the
  # long one and covers well under half of itself... it still lies
  # entirely inside, so coverage of the *shorter* session carries it.
  inside <- .wk("2026-06-12 08:30:00", distance = 4196, duration = 1800,
                end = "2026-06-12 09:00:00")
  expect_true(.is_same_workout(garmin, inside))
})

test_that(".is_same_workout matches overlapping sessions with equal distance", {
  # 2023-10-23: the two clocks disagree by more than an hour, so neither
  # the coverage nor the end-gap gate fires — but the recorded distance
  # matches to the metre, which two different runs would not.
  garmin <- .wk("2023-10-23 07:05:00", distance = 12303, duration = 4320,
                end = "2023-10-23 08:17:00")
  watch <- .wk("2023-10-23 08:13:00", distance = 12304, duration = 4020,
               end = "2023-10-23 09:20:00")
  expect_true(.is_same_workout(garmin, watch))

  # The same geometry with genuinely different distances stays two
  # sessions.
  other <- watch
  other$distance <- 4798
  expect_false(.is_same_workout(garmin, other))
})

test_that(".is_same_workout ignores a brief brush between two sessions", {
  # A walk that ends 30 s after the run starts is not the run.
  run <- .wk("2026-06-12 07:50:00", distance = 10000, duration = 3000,
             end = "2026-06-12 08:40:00")
  walk <- .wk("2026-06-12 07:20:00", distance = 2000, duration = 1800,
              sport = "walking", end = "2026-06-12 07:50:30")
  expect_false(.is_same_workout(run, walk))
})

test_that(".is_same_workout exempts strength and unclassified sports from overlap", {
  # A strength session logged on one watch while the other records a run
  # is a genuine pair of sessions.
  run <- .wk("2026-06-12 07:50:00", distance = 24000, duration = 7980,
             end = "2026-06-12 10:03:00")
  gym <- .wk("2026-06-12 09:35:00", distance = NA_real_, duration = 1679,
             sport = "strength", end = "2026-06-12 10:03:01")
  expect_false(.is_same_workout(run, gym))

  misc <- gym
  misc$sport <- "ovrigt"
  expect_false(.is_same_workout(run, misc))

  # An unlabelled session is treated the same way — without a sport we
  # cannot tell a parallel activity from a duplicate.
  unlabelled <- gym
  unlabelled$sport <- NA_character_
  expect_false(.is_same_workout(run, unlabelled))
})

test_that(".is_same_workout falls back to the start rule without sessionEnd", {
  garmin <- .wk("2026-06-12 07:50:00", distance = 24000, duration = 7980)
  watch <- .wk("2026-06-12 09:35:00", distance = 5006, duration = 1679)
  expect_false(.is_same_workout(garmin, watch))

  # Missing end on one side only is equally unusable.
  half <- watch
  half$sessionEnd <- as.POSIXct(NA)
  garmin$sessionEnd <- as.POSIXct("2026-06-12 10:03:00", tz = "UTC")
  expect_false(.is_same_workout(garmin, half))
})

test_that("import_hae_workouts dedups a mid-session Apple Watch recording", {
  tmp <- withr::local_tempdir()
  path <- .write_hae(tmp, "mid", "2026-06-12 09:35:00 +0000",
                     "Utomhus Kör", distance_km = 5.006, duration_s = 1679)
  # .write_hae writes end == start; patch in the real end so the
  # interval has a span.
  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  raw$data$workouts[[1]]$end <- "2026-06-12 10:03:01 +0000"
  jsonlite::write_json(raw, path, auto_unbox = TRUE, null = "null")

  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-06-12 07:50:00", tz = "UTC"),
    sessionEnd = as.POSIXct("2026-06-12 10:03:00", tz = "UTC"),
    sport = "running",
    distance = 24000,
    duration = as.difftime(7980, units = "secs"),
    file = "/data/tcx/20260612-075000.tcx",
    source = "tcx",
    stringsAsFactors = FALSE
  )

  res <- import_hae_workouts(tmp, summaries, list(NULL))
  expect_equal(res$n_imported, 0)
  expect_equal(res$n_skipped_dup, 1)
})

test_that(".is_same_workout handles difftime durations and NA starts", {
  a <- .wk("2026-08-01 11:00:49", distance = NA_real_)
  a$duration <- as.difftime(1391 / 60, units = "mins")
  b <- .wk("2026-08-01 11:02:36", distance = NA_real_)
  b$duration <- as.difftime(1376, units = "secs")
  expect_true(.is_same_workout(a, b))

  na_start <- .wk(NA_character_, distance = 5234, duration = 1391)
  expect_false(.is_same_workout(a, na_start))
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
