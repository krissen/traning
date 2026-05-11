# Tests for the per-pass post-workout prose (R/session_prose.R).
#
# Three concerns are exercised here:
#   A) Readiness verdict must override TSB phrasing on Gul/Röd days.
#   B) Latest pass selection prefers TCX over HAE when triggered by Garmin.
#   C) "Tidigare idag" context line surfaces other passes the user logged.

# ---- Test fixtures ---------------------------------------------------------

.sp_mk_run <- function(date_time, sport = "running", km = 8,
                       min = 45, hr = 140, pace = 5.5,
                       source = "tcx", rpe = NA_real_,
                       z1 = NA_real_, z2 = NA_real_,
                       z3 = NA_real_, z4 = NA_real_, z5 = NA_real_) {
  tibble::tibble(
    sessionStart = as.POSIXct(date_time, tz = "UTC"),
    sport = sport, distance = km * 1000,
    avgPaceMoving = pace, avgHeartRateMoving = hr,
    durationMoving = as.difftime(min, units = "mins"),
    garmin_directWorkoutRpe = rpe,
    garmin_hrTimeInZone_1 = z1, garmin_hrTimeInZone_2 = z2,
    garmin_hrTimeInZone_3 = z3, garmin_hrTimeInZone_4 = z4,
    garmin_hrTimeInZone_5 = z5,
    source = source
  )
}


# ---- Bug A — readiness override ------------------------------------------

test_that("session_prose: Röd readiness overrides Form på topp", {
  # Garmin run today + positive TSB context; Röd should win.
  s <- .sp_mk_run("2026-05-11 09:00", source = "tcx", km = 8,
                   pace = 5.0, hr = 145, rpe = 30)
  red <- list(status = "Röd", score = 40, kvalitet = "full",
              components = list(), components_present = list())
  txt <- session_prose(s, on_date = "2026-05-11", readiness = red,
                       health_daily = data.frame())  # block auto-load
  expect_false(grepl("Form på topp", txt),
               info = paste("Got:", txt))
  expect_match(txt, "Röd 40")
  expect_match(txt, "återhämtningssignaler dominerar")
})

test_that("session_prose: Gul readiness prepends to TSB text", {
  s <- .sp_mk_run("2026-05-11 09:00", source = "tcx", km = 8,
                   pace = 5.0, hr = 145, rpe = 30)
  yellow <- list(status = "Gul", score = 67, kvalitet = "full",
                 components = list(), components_present = list())
  txt <- session_prose(s, on_date = "2026-05-11", readiness = yellow,
                       health_daily = data.frame())
  expect_match(txt, "Gul 67")
})

test_that("session_prose: Grön readiness keeps TSB phrasing", {
  s <- .sp_mk_run("2026-05-11 09:00", source = "tcx", km = 8,
                   pace = 5.0, hr = 145, rpe = 30)
  green <- list(status = "Grön", score = 85, kvalitet = "full",
                components = list(), components_present = list())
  txt <- session_prose(s, on_date = "2026-05-11", readiness = green,
                       health_daily = data.frame())
  expect_false(grepl("Dagsform", txt))
})


# ---- Bug B — latest pass selection ---------------------------------------

test_that("session_prose: picks latest TCX over later HAE segments", {
  # Morning TCX run + 5 HAE walking micro-segments later in the day.
  # The classification should describe the morning run.
  d <- "2026-05-11"
  s <- dplyr::bind_rows(
    .sp_mk_run(paste(d, "09:00"), source = "tcx", km = 8,
                pace = 5.0, hr = 145, rpe = 30, sport = "running"),
    .sp_mk_run(paste(d, "12:00"), source = "hae", km = 0.5,
                min = 7, sport = "walking"),
    .sp_mk_run(paste(d, "14:00"), source = "hae", km = 0.6,
                min = 8, sport = "walking"),
    .sp_mk_run(paste(d, "17:00"), source = "hae", km = 0.7,
                min = 9, sport = "walking")
  )
  txt <- session_prose(s, on_date = d, readiness = NULL,
                       health_daily = data.frame())
  # RPE 30 → endurance type → "Distanspass" label.
  expect_match(txt, "^Distanspass")
})

test_that("session_prose: NA source rows are treated as TCX", {
  # Legacy rows (pre-source-column) must not be filtered out by the
  # Garmin-priority selector.
  s <- .sp_mk_run("2026-05-11 09:00", km = 8, pace = 5.0, hr = 145,
                   rpe = 30)
  s$source <- NA_character_
  txt <- session_prose(s, on_date = "2026-05-11", readiness = NULL,
                       health_daily = data.frame())
  expect_match(txt, "^Distanspass")
})

test_that("session_prose: HAE-only days still produce prose (fallback)", {
  # No TCX available → fall back to "any" source so the user still
  # gets a notification instead of "Ingen data.".
  s <- .sp_mk_run("2026-05-11 09:00", km = 8, pace = 5.0, hr = 145,
                   rpe = 30, source = "hae")
  txt <- session_prose(s, on_date = "2026-05-11", readiness = NULL,
                       health_daily = data.frame())
  expect_false(identical(txt, "Ingen data."))
})


# ---- Context — "Tidigare idag" -------------------------------------------

test_that("session_prose: 'Tidigare idag' line lists other passes today", {
  d <- "2026-05-11"
  s <- dplyr::bind_rows(
    # Morning TCX run.
    .sp_mk_run(paste(d, "07:00"), source = "tcx", km = 8,
                pace = 5.0, hr = 145, rpe = 30),
    # HAE walking session that survives the noise filter (≥1 km).
    .sp_mk_run(paste(d, "12:00"), source = "hae", sport = "walking",
                km = 2.4, min = 25),
    # Afternoon TCX run (this is the "latest" — should NOT be in
    # the context line).
    .sp_mk_run(paste(d, "18:00"), source = "tcx", km = 5,
                pace = 5.5, hr = 140, rpe = 30)
  )
  txt <- session_prose(s, on_date = d, readiness = NULL,
                       health_daily = data.frame())
  expect_match(txt, "Tidigare idag")
  # Morning run is one of "Tidigare idag" — check distance and sport.
  expect_match(txt, "löpning 8.0 km")
  expect_match(txt, "gång 2.4 km")
})

test_that("session_prose: context line drops short HAE noise segments", {
  d <- "2026-05-11"
  s <- dplyr::bind_rows(
    .sp_mk_run(paste(d, "09:00"), source = "tcx", km = 8,
                pace = 5.0, hr = 145, rpe = 30),
    # 5 HAE segments all <1 km AND <10 min → all dropped.
    .sp_mk_run(paste(d, "12:00"), source = "hae", sport = "walking",
                km = 0.3, min = 4),
    .sp_mk_run(paste(d, "13:00"), source = "hae", sport = "walking",
                km = 0.4, min = 5),
    .sp_mk_run(paste(d, "14:00"), source = "hae", sport = "walking",
                km = 0.5, min = 6)
  )
  txt <- session_prose(s, on_date = d, readiness = NULL,
                       health_daily = data.frame())
  # No "Tidigare idag" because nothing meaningful was found.
  expect_false(grepl("Tidigare idag", txt))
})

test_that("session_prose: no context line when latest is the only pass", {
  s <- .sp_mk_run("2026-05-11 09:00", source = "tcx", km = 8,
                   pace = 5.0, hr = 145, rpe = 30)
  txt <- session_prose(s, on_date = "2026-05-11", readiness = NULL,
                       health_daily = data.frame())
  expect_false(grepl("Tidigare idag", txt))
})


# ---- Regression — no readiness, no health_daily --------------------------

test_that("session_prose: empty health_daily falls back to TSB-only text", {
  # When neither readiness nor health_daily can be derived the state
  # line should still produce the bare TSB-band phrasing (or NULL).
  s <- .sp_mk_run("2026-05-11 09:00", source = "tcx", km = 8,
                   pace = 5.0, hr = 145, rpe = 30)
  txt <- session_prose(s, on_date = "2026-05-11", readiness = NULL,
                       health_daily = data.frame())
  expect_type(txt, "character")
  expect_true(nchar(txt) > 0)
  expect_match(txt, "^Distanspass")
})

test_that("session_prose: multi-sport fallback still works (running default)", {
  # Cycling data only → .session_prose_fallback should fire and return
  # a quantitative "Cykling X km" line (test-report-multisport contract).
  d <- "2026-05-11"
  cyk <- .sp_mk_run(paste(d, "10:00"), source = "tcx",
                     sport = "cycling", km = 25, pace = 2.5, hr = 130)
  txt <- session_prose(cyk, sport = "cycling", on_date = d,
                       readiness = NULL, health_daily = data.frame())
  expect_match(txt, "^Cykling")
})
