# Invariant matrix for cross-source deduplication.
#
# The match rule under test (R/health_export_workouts.R) has two
# criteria, ORed together:
#
#   start criterion:   |dstart| <= 300 s AND (distance within 20 % OR
#                      duration within 20 %); when neither quantity is
#                      comparable on both sides, time alone within 120 s.
#   overlap criterion: wall-clock intervals overlap by >= 60 s AND the
#                      overlap covers >= 50 % of the shorter session or
#                      the two end within 60 s; movement sports only.
#
# Garmin (source == "tcx") always wins.
#
# The grid below isolates the *start* criterion: its fixtures carry no
# sessionEnd, which is what the overlap criterion needs, so every cell is
# decided by the start rule alone. Two sessions minutes apart are
# necessarily nested in wall-clock terms, so leaving ends in place would
# make every cell match via overlap and the grid would stop
# discriminating. The overlap criterion gets its own block at the bottom,
# run over the same four directions.
#
# Each direction in which the rule is applied gets a driver returning a
# single logical ("were the two rows collapsed into one?"), and every
# driver is run over the same grid of dstart, sanity-quantity and sport
# combinations. A cell that behaves differently from the others is then a
# difference between the call sites, not between the fixtures.

.TCX_START <- as.POSIXct("2026-08-01 11:02:36", tz = "UTC")
.TCX_DIST <- 5292
.TCX_DUR <- 1376

# --- fixture builders ---------------------------------------------------------

# `end_s` is the wall-clock end offset from `start`, or NULL for a file
# without an end — the shape the start-criterion grid needs.
.write_hae_workout <- function(dir, name, start, name_field, distance_km,
                               duration_s, end_s = NULL) {
  payload <- list(data = list(workouts = list(list(
    id = name,
    name = name_field,
    start = format(start, "%Y-%m-%d %H:%M:%S +0000", tz = "UTC"),
    end = if (is.null(end_s)) NULL else
      format(start + end_s, "%Y-%m-%d %H:%M:%S +0000", tz = "UTC"),
    duration = duration_s,
    distance = list(qty = distance_km, units = "km"),
    avgHeartRate = list(qty = 140, units = "count/min")
  ))))
  path <- file.path(dir, paste0(name, ".json"))
  jsonlite::write_json(payload, path, auto_unbox = TRUE, null = "null")
  path
}

.cache_row <- function(start, sport, distance, duration, file, source,
                       end_s = NULL) {
  row <- data.frame(sessionStart = start, sport = sport,
                    file = file, source = source, stringsAsFactors = FALSE)
  # Columns are added conditionally: a cache row with neither distance nor
  # duration is what drives the time-only fallback, and one without
  # sessionEnd is what keeps the overlap criterion out of the start grid.
  if (!is.null(distance)) row$distance <- distance
  if (!is.null(duration)) row$duration <- as.difftime(duration, units = "secs")
  if (!is.null(end_s)) row$sessionEnd <- start + end_s
  row
}

# A fake trackeR object + summary, so the TCX side can be driven without a
# real container parse.
.fake_tcx_summary <- function(start, distance, duration, sport, file) {
  data.frame(
    session = 1L, sessionStart = start, sessionEnd = start + duration,
    distance = distance,
    duration = as.difftime(duration, units = "secs"),
    durationMoving = as.difftime(duration, units = "secs"),
    avgSpeed = 3.8, avgSpeedMoving = 3.9, avgPace = 4.4, avgPaceMoving = 4.3,
    avgHeartRate = 140, avgHeartRateMoving = 142,
    avgCadenceRunning = 85, avgCadenceRunningMoving = 87,
    sport = sport, file = file, stringsAsFactors = FALSE
  )
}
summary.matrixtrack <- function(object, ...) object$the_summary
registerS3method("summary", "matrixtrack", summary.matrixtrack,
                 envir = environment())

.fake_tcx <- function(start, distance, duration, sport, file) {
  structure(
    list(the_summary = .fake_tcx_summary(start, distance, duration, sport, file)),
    class = "matrixtrack"
  )
}

# --- direction drivers --------------------------------------------------------
#
# All four return a list(collapsed = <logical>, summaries = <df>,
# myruns = <list>) so the caller can assert both the verdict and the
# positional invariant.

# 1. A new HAE file arrives; the Garmin row is already cached.
.dir_hae_into_cached_tcx <- function(dt, hae_dist_km, hae_dur, sport_name,
                                     tcx_sport = "running",
                                     tcx_distance = .TCX_DIST,
                                     tcx_duration = .TCX_DUR,
                                     hae_end_s = NULL, tcx_end_s = NULL) {
  dir <- withr::local_tempdir()
  .write_hae_workout(dir, "hae-new", .TCX_START + dt, sport_name,
                     hae_dist_km, hae_dur, end_s = hae_end_s)
  cached <- .cache_row(.TCX_START, tcx_sport, tcx_distance, tcx_duration,
                       "/data/tcx/20260801-110236.tcx", "tcx",
                       end_s = tcx_end_s)
  res <- import_hae_workouts(dir, cached, list("garmin-run"))
  list(collapsed = res$n_skipped_dup == 1L,
       summaries = res$summaries, myruns = res$myruns)
}

# 2. A new TCX file arrives; the Apple Watch row is already cached.
.dir_tcx_into_cached_hae <- function(dt, hae_dist_m, hae_dur, sport,
                                     tcx_distance = .TCX_DIST,
                                     tcx_duration = .TCX_DUR,
                                     hae_end_s = NULL) {
  cached <- .cache_row(.TCX_START + dt, sport, hae_dist_m, hae_dur,
                       "hae:Utomhus_Kor-20260801.json", "hae",
                       end_s = hae_end_s)
  file <- "/data/tcx/20260801-110236.tcx"
  res <- testthat::with_mocked_bindings(
    get_new_workouts(file, cached, list(NULL), verbose = FALSE),
    read_container = function(f, ...) {
      .fake_tcx(.TCX_START, tcx_distance, tcx_duration, "running", f)
    },
    .package = "trackeR"
  )
  list(collapsed = res$n_hae_removed == 1L,
       summaries = res$summaries, myruns = res$myruns)
}

# 3. Two HAE files for the same session in one batch (Apple Watch
#    recording + Garmin-Connect-mirrored copy).
.dir_hae_vs_hae_same_batch <- function(dt, hae_dist_km, hae_dur, sport_name,
                                       first_dist_km = .TCX_DIST / 1000,
                                       first_dur = .TCX_DUR,
                                       first_end_s = NULL,
                                       hae_end_s = NULL) {
  dir <- withr::local_tempdir()
  .write_hae_workout(dir, "a-native", .TCX_START, "Utomhus Kör",
                     first_dist_km, first_dur, end_s = first_end_s)
  .write_hae_workout(dir, "b-mirror", .TCX_START + dt, sport_name,
                     hae_dist_km, hae_dur, end_s = hae_end_s)
  res <- import_hae_workouts(dir, data.frame(), list())
  list(collapsed = res$n_skipped_dup_hae == 1L,
       summaries = res$summaries, myruns = res$myruns)
}

# 4. A new HAE file against an HAE row already in the cache.
.dir_hae_vs_cached_hae <- function(dt, hae_dist_km, hae_dur, sport_name,
                                   cached_dist = .TCX_DIST,
                                   cached_dur = .TCX_DUR,
                                   cached_end_s = NULL,
                                   hae_end_s = NULL) {
  dir <- withr::local_tempdir()
  .write_hae_workout(dir, "b-mirror", .TCX_START + dt, sport_name,
                     hae_dist_km, hae_dur, end_s = hae_end_s)
  cached <- .cache_row(.TCX_START, "running", cached_dist, cached_dur,
                       "hae:a-native.json", "hae", end_s = cached_end_s)
  res <- import_hae_workouts(dir, cached, list(NULL))
  list(collapsed = res$n_skipped_dup_hae == 1L,
       summaries = res$summaries, myruns = res$myruns)
}

# --- the grid -----------------------------------------------------------------

# Sanity variants, expressed relative to the Garmin reference session
# (5292 m / 1376 s).
.SANITY <- list(
  equal = list(dist_km = 5.234, dur = 1391, expect = TRUE,
               label = "distance and duration both within 20 %"),
  dist_off = list(dist_km = 3.140, dur = 1376, expect = TRUE,
                  label = "distance 40 % off, duration matches"),
  both_off = list(dist_km = 3.140, dur = 830, expect = FALSE,
                  label = "distance and duration both > 20 % off")
)

# dstart values, in seconds, and whether they are inside the wide window.
.DT_CASES <- list(
  list(dt = 5, inside = TRUE),
  list(dt = 107, inside = TRUE),   # the 2026-08-01 session
  list(dt = 290, inside = TRUE),
  list(dt = 300, inside = TRUE),   # the boundary is inclusive
  list(dt = 301, inside = FALSE),
  list(dt = 400, inside = FALSE)
)

.SPORTS <- list(
  list(hae_name = "Utomhus Kör", cached_sport = "running"),
  # Apple Watch labels a slow jog "Utomhus Gång" while Garmin records the
  # same session as running: the sport must not gate the match.
  list(hae_name = "Utomhus Gång", cached_sport = "walking")
)

test_that("cross-source dedup collapses the same session in every direction", {
  for (sp in .SPORTS) {
    for (dtc in .DT_CASES) {
      for (nm in names(.SANITY)) {
        san <- .SANITY[[nm]]
        expected <- dtc$inside && san$expect
        cell <- sprintf("dt=%ds, %s, %s", dtc$dt, san$label, sp$hae_name)

        r1 <- .dir_hae_into_cached_tcx(dtc$dt, san$dist_km, san$dur,
                                       sp$hae_name)
        expect_equal(r1$collapsed, expected, info = paste("HAE->TCX:", cell))
        # Garmin always survives, whichever side arrived last.
        expect_equal(nrow(r1$summaries), if (expected) 1L else 2L,
                     info = paste("HAE->TCX rows:", cell))
        expect_true("tcx" %in% r1$summaries$source,
                    info = paste("HAE->TCX winner:", cell))
        expect_equal(length(r1$myruns), nrow(r1$summaries),
                     info = paste("HAE->TCX myruns:", cell))

        r2 <- .dir_tcx_into_cached_hae(dtc$dt, san$dist_km * 1000, san$dur,
                                       sp$cached_sport)
        expect_equal(r2$collapsed, expected, info = paste("TCX->HAE:", cell))
        expect_equal(nrow(r2$summaries), if (expected) 1L else 2L,
                     info = paste("TCX->HAE rows:", cell))
        expect_true("tcx" %in% r2$summaries$source,
                    info = paste("TCX->HAE winner:", cell))
        expect_equal(length(r2$myruns), nrow(r2$summaries),
                     info = paste("TCX->HAE myruns:", cell))

        r3 <- .dir_hae_vs_hae_same_batch(dtc$dt, san$dist_km, san$dur,
                                         sp$hae_name)
        expect_equal(r3$collapsed, expected, info = paste("HAE<->HAE batch:", cell))
        expect_equal(length(r3$myruns), nrow(r3$summaries),
                     info = paste("HAE<->HAE batch myruns:", cell))

        r4 <- .dir_hae_vs_cached_hae(dtc$dt, san$dist_km, san$dur, sp$hae_name)
        expect_equal(r4$collapsed, expected, info = paste("HAE<->HAE cached:", cell))
        expect_equal(length(r4$myruns), nrow(r4$summaries),
                     info = paste("HAE<->HAE cached myruns:", cell))
      }
    }
  }
})

# --- overlap criterion --------------------------------------------------------
#
# The reference session is long (2 h 13 min); the second recording starts
# 105 minutes in and both stop within a second of each other — the
# "second watch started midway" shape that the start criterion cannot
# see (dstart is 6300 s, twenty times the window).

.LONG_DUR <- 7980           # 07:50 -> 10:03
.MID_DT <- 6300             # second watch started 1 h 45 m in
.MID_DUR <- 1681            # ... and stopped 1 s after the first

# Nested but stopping early: covers 100 % of the shorter session while
# ending half an hour before the longer one.
.NESTED_DT <- 2400
.NESTED_DUR <- 1800

# Two sessions that merely touch: 30 s of overlap, below the 60 s floor.
.BRUSH_DT <- .LONG_DUR - 30
.BRUSH_DUR <- 1800

.overlap_cases <- list(
  list(label = "second watch started midway, stopped together",
       dt = .MID_DT, dur = .MID_DUR, dist_km = 5.006, expect = TRUE),
  list(label = "short recording nested inside the long one",
       dt = .NESTED_DT, dur = .NESTED_DUR, dist_km = 4.196, expect = TRUE),
  list(label = "sessions brushing at the edge",
       dt = .BRUSH_DT, dur = .BRUSH_DUR, dist_km = 6.0, expect = FALSE)
)

test_that("the overlap criterion behaves the same in every direction", {
  for (oc in .overlap_cases) {
    cell <- oc$label

    r1 <- .dir_hae_into_cached_tcx(
      oc$dt, oc$dist_km, oc$dur, "Utomhus Kör",
      tcx_distance = 24000, tcx_duration = .LONG_DUR,
      hae_end_s = oc$dur, tcx_end_s = .LONG_DUR)
    expect_equal(r1$collapsed, oc$expect, info = paste("HAE->TCX:", cell))
    expect_true("tcx" %in% r1$summaries$source,
                info = paste("HAE->TCX winner:", cell))
    expect_equal(length(r1$myruns), nrow(r1$summaries),
                 info = paste("HAE->TCX myruns:", cell))

    r2 <- .dir_tcx_into_cached_hae(
      oc$dt, oc$dist_km * 1000, oc$dur, "running",
      tcx_distance = 24000, tcx_duration = .LONG_DUR,
      hae_end_s = oc$dur)
    expect_equal(r2$collapsed, oc$expect, info = paste("TCX->HAE:", cell))
    expect_true("tcx" %in% r2$summaries$source,
                info = paste("TCX->HAE winner:", cell))
    expect_equal(length(r2$myruns), nrow(r2$summaries),
                 info = paste("TCX->HAE myruns:", cell))

    r3 <- .dir_hae_vs_hae_same_batch(
      oc$dt, oc$dist_km, oc$dur, "Utomhus Kör",
      first_dist_km = 24, first_dur = .LONG_DUR,
      first_end_s = .LONG_DUR, hae_end_s = oc$dur)
    expect_equal(r3$collapsed, oc$expect, info = paste("HAE<->HAE batch:", cell))
    expect_equal(length(r3$myruns), nrow(r3$summaries),
                 info = paste("HAE<->HAE batch myruns:", cell))

    r4 <- .dir_hae_vs_cached_hae(
      oc$dt, oc$dist_km, oc$dur, "Utomhus Kör",
      cached_dist = 24000, cached_dur = .LONG_DUR,
      cached_end_s = .LONG_DUR, hae_end_s = oc$dur)
    expect_equal(r4$collapsed, oc$expect, info = paste("HAE<->HAE cached:", cell))
    expect_equal(length(r4$myruns), nrow(r4$summaries),
                 info = paste("HAE<->HAE cached myruns:", cell))
  }
})

test_that("the overlap criterion spares strength and unclassified sports", {
  # A strength session logged on the watch while the Garmin records a
  # long run is a real second session, not a duplicate recording.
  for (sport in c("Funktionell Styrketräning", "Övrigt")) {
    r <- .dir_hae_into_cached_tcx(
      .MID_DT, 0, .MID_DUR, sport,
      tcx_distance = 24000, tcx_duration = .LONG_DUR,
      hae_end_s = .MID_DUR, tcx_end_s = .LONG_DUR)
    expect_false(r$collapsed, info = sport)
    expect_equal(nrow(r$summaries), 2L, info = sport)
  }

  # ... while a movement sport in the same position is collapsed, so the
  # difference is the exemption and not the fixture.
  r <- .dir_hae_into_cached_tcx(
    .MID_DT, 5.006, .MID_DUR, "Utomhus Gång",
    tcx_distance = 24000, tcx_duration = .LONG_DUR,
    hae_end_s = .MID_DUR, tcx_end_s = .LONG_DUR)
  expect_true(r$collapsed)
})

test_that("the Garmin row is the one that survives, with its own numbers", {
  # Not just "one row left" — the surviving row must carry the Garmin
  # distance and filename, since the reports read those columns.
  r1 <- .dir_hae_into_cached_tcx(107, 5.234, 1391, "Utomhus Kör")
  expect_equal(nrow(r1$summaries), 1L)
  expect_equal(r1$summaries$distance, .TCX_DIST)
  expect_equal(r1$summaries$file, "/data/tcx/20260801-110236.tcx")
  expect_equal(r1$myruns[[1]], "garmin-run")

  r2 <- .dir_tcx_into_cached_hae(-107, 5234, 1391, "running")
  expect_equal(nrow(r2$summaries), 1L)
  expect_equal(r2$summaries$distance, .TCX_DIST)
  expect_equal(r2$summaries$source, "tcx")
  expect_false(is.null(r2$myruns[[1]]))
})

test_that("the Apple Watch clock may run ahead of or behind Garmin", {
  # The 2026-08-01 case was AW-first; the sign of dstart must not matter.
  expect_true(.dir_hae_into_cached_tcx(-107, 5.234, 1391, "Utomhus Kör")$collapsed)
  expect_true(.dir_hae_into_cached_tcx(107, 5.234, 1391, "Utomhus Kör")$collapsed)
  expect_true(.dir_tcx_into_cached_hae(-107, 5234, 1391, "running")$collapsed)
  expect_true(.dir_tcx_into_cached_hae(107, 5234, 1391, "running")$collapsed)
})

test_that("with no comparable quantity the window narrows to two minutes", {
  # A cache row predating the distance/duration columns leaves nothing but
  # the clock to go on.
  for (dt in c(-119, 119)) {
    r <- .dir_hae_into_cached_tcx(dt, 5.234, 1391, "Utomhus Kör",
                                  tcx_distance = NULL, tcx_duration = NULL)
    expect_true(r$collapsed, info = paste("dt =", dt))
  }
  for (dt in c(121, 200, 299)) {
    r <- .dir_hae_into_cached_tcx(dt, 5.234, 1391, "Utomhus Kör",
                                  tcx_distance = NULL, tcx_duration = NULL)
    expect_false(r$collapsed, info = paste("dt =", dt))
  }

  expect_true(.dir_tcx_into_cached_hae(119, NULL, NULL, "running")$collapsed)
  expect_false(.dir_tcx_into_cached_hae(121, NULL, NULL, "running")$collapsed)
})

test_that("one comparable quantity is enough to open the wide window", {
  # Distance missing on the Garmin side, durations comparable: still the
  # wide window, not the time-only fallback.
  r <- .dir_hae_into_cached_tcx(250, 5.234, 1391, "Utomhus Kör",
                                tcx_distance = NULL)
  expect_true(r$collapsed)
  r <- .dir_hae_into_cached_tcx(301, 5.234, 1391, "Utomhus Kör",
                                tcx_distance = NULL)
  expect_false(r$collapsed)
})

# --- myruns positional invariant ----------------------------------------------

test_that("one Garmin import evicts every Apple Watch copy of the session", {
  # HAE delivers two JSON files per session; if both landed before the
  # Garmin fetch, both have to go.
  cached <- data.frame(
    sessionStart = c(.TCX_START - 107, .TCX_START - 104, .TCX_START - 7200),
    sport = c("running", "walking", "walking"),
    distance = c(5234, 5240, 2000),
    duration = as.difftime(c(1391, 1390, 1800), units = "secs"),
    file = c("hae:native.json", "hae:mirror.json", "hae:morning-walk.json"),
    source = "hae", stringsAsFactors = FALSE
  )

  res <- testthat::with_mocked_bindings(
    get_new_workouts("/data/tcx/new.tcx", cached, list(NULL, NULL, NULL),
                     verbose = FALSE),
    read_container = function(f, ...) {
      .fake_tcx(.TCX_START, .TCX_DIST, .TCX_DUR, "running", f)
    },
    .package = "trackeR"
  )

  expect_equal(res$n_hae_removed, 2)
  expect_equal(nrow(res$summaries), 2)
  expect_equal(length(res$myruns), 2)
  # The unrelated morning walk keeps its (empty) slot; the trackeR object
  # sits on the Garmin row.
  expect_equal(res$summaries$file,
               c("hae:morning-walk.json", "/data/tcx/new.tcx"))
  expect_null(res$myruns[[1]])
  expect_false(is.null(res$myruns[[2]]))
})

test_that("get_new_workouts realigns a myruns list that arrived skewed", {
  # A myruns list longer than summaries used to have a real run object
  # overwritten by the slot assignment for the newly imported session.
  cached <- data.frame(
    sessionStart = .TCX_START - 7200, sport = "running", distance = 2000,
    duration = as.difftime(1800, units = "secs"),
    file = "old.tcx", source = "tcx", stringsAsFactors = FALSE
  )

  res <- NULL
  testthat::with_mocked_bindings(
    expect_message(
      res <- get_new_workouts("/data/tcx/new.tcx", cached,
                              list("keep", "stray-1", "stray-2"),
                              verbose = FALSE),
      "ur synk"
    ),
    read_container = function(f, ...) {
      .fake_tcx(.TCX_START, .TCX_DIST, .TCX_DUR, "running", f)
    },
    .package = "trackeR"
  )

  expect_equal(nrow(res$summaries), 2)
  expect_equal(length(res$myruns), 2)
  expect_equal(res$myruns[[1]], "keep")
  expect_false(is.null(res$myruns[[2]]))
})

test_that("import_hae_workouts realigns myruns before adding placeholders", {
  dir <- withr::local_tempdir()
  .write_hae_workout(dir, "new", .TCX_START + 86400, "Utomhus Kör", 5.0, 1500)
  cached <- data.frame(
    sessionStart = .TCX_START + c(0, 3600, 7200), sport = "running",
    distance = c(5292, 3000, 4000),
    duration = as.difftime(c(1376, 900, 1200), units = "secs"),
    file = c("a.tcx", "b.tcx", "c.tcx"), source = "tcx",
    stringsAsFactors = FALSE
  )

  short <- NULL
  expect_message(short <- import_hae_workouts(dir, cached, list("a", "b")),
                 "ur synk")
  expect_equal(short$n_imported, 1)
  expect_equal(length(short$myruns), nrow(short$summaries))
  expect_equal(short$myruns[[1]], "a")

  long <- NULL
  expect_message(
    long <- import_hae_workouts(dir, cached, list("a", "b", "c", "stray")),
    "ur synk")
  expect_equal(length(long$myruns), nrow(long$summaries))
  expect_equal(long$myruns[[3]], "c")
  expect_null(long$myruns[[4]])
})

test_that("import_hae_workouts leaves an aligned pair alone and silent", {
  dir <- withr::local_tempdir()
  .write_hae_workout(dir, "new", .TCX_START + 86400, "Utomhus Kör", 5.0, 1500)
  cached <- .cache_row(.TCX_START, "running", .TCX_DIST, .TCX_DUR,
                       "a.tcx", "tcx")

  expect_silent(res <- import_hae_workouts(dir, cached, list("a")))
  expect_equal(nrow(res$summaries), 2)
  expect_equal(length(res$myruns), 2)
})

# --- dedup_summaries ----------------------------------------------------------

.matrix_cache <- function(dir, summaries, myruns) {
  db_s <- file.path(dir, "summaries.RData")
  db_m <- file.path(dir, "myruns.RData")
  save(summaries, file = db_s)
  save(myruns, file = db_m)
  list(summaries = db_s, myruns = db_m)
}

test_that("dedup_summaries dry run writes to neither cache file", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = c(.TCX_START - 107, .TCX_START),
    sport = "running", distance = c(5234, .TCX_DIST),
    duration = as.difftime(c(1391, .TCX_DUR), units = "secs"),
    file = c("hae:x.json", "/data/tcx/y.tcx"), source = c("hae", "tcx"),
    stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, list(NULL, "run"))
  before <- file.mtime(unlist(paths))
  before_bytes <- lapply(unlist(paths), readBin, what = "raw", n = 1e6)

  dups <- dedup_summaries(paths$summaries, paths$myruns, dry_run = TRUE,
                          verbose = FALSE)

  expect_equal(nrow(dups), 1)
  expect_identical(file.mtime(unlist(paths)), before)
  expect_identical(lapply(unlist(paths), readBin, what = "raw", n = 1e6),
                   before_bytes)
})

test_that("dedup_summaries cleans every sport, not just running", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = rep(.TCX_START, 6) + c(-107, 0, 3500, 3600, 7100, 7200),
    sport = c("running", "running", "cycling", "cycling", "walking", "walking"),
    distance = c(5234, 5292, 20100, 20000, 3010, 3000),
    duration = as.difftime(c(1391, 1376, 3600, 3590, 1800, 1790),
                           units = "secs"),
    file = c("hae:run.json", "run.tcx", "hae:bike.json", "bike.tcx",
             "hae:walk.json", "walk.tcx"),
    source = c("hae", "tcx", "hae", "tcx", "hae", "tcx"),
    stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, as.list(paste0("r", 1:6)))

  dups <- dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE,
                          verbose = FALSE)

  expect_setequal(dups$sport, c("running", "cycling", "walking"))
  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 3)
  expect_true(all(after$summaries$source == "tcx"))
  expect_equal(unlist(after$myruns), c("r2", "r4", "r6"))
})

test_that("dedup_summaries removes both Apple Watch copies of one session", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = .TCX_START + c(-107, -104, 0),
    sport = "running", distance = c(5234, 5240, .TCX_DIST),
    duration = as.difftime(c(1391, 1390, .TCX_DUR), units = "secs"),
    file = c("hae:native.json", "hae:mirror.json", "/data/tcx/y.tcx"),
    source = c("hae", "hae", "tcx"), stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, list(NULL, NULL, "run"))

  dups <- dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE,
                          verbose = FALSE)

  expect_equal(nrow(dups), 2)
  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$myruns[[1]], "run")
})

test_that("dedup_summaries keeps sessions Garmin never recorded", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    # 301 s from the Garmin session, a different distance at the same
    # instant, and a row with no timestamp at all: none may be removed.
    sessionStart = c(.TCX_START - 301, .TCX_START - 60,
                     as.POSIXct(NA, tz = "UTC"), .TCX_START),
    sport = c("running", "walking", "running", "running"),
    distance = c(5234, 1200, 5234, .TCX_DIST),
    duration = as.difftime(c(1391, 900, 1391, .TCX_DUR), units = "secs"),
    file = c("hae:late.json", "hae:walk.json", "hae:nostart.json",
             "/data/tcx/y.tcx"),
    source = c("hae", "hae", "hae", "tcx"), stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, list(NULL, NULL, NULL, "run"))

  dups <- dedup_summaries(paths$summaries, paths$myruns, dry_run = TRUE,
                          verbose = FALSE)
  expect_equal(nrow(dups), 0)
})

test_that("dedup_summaries repairs a skewed myruns before removing rows", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = .TCX_START + c(-107, 0, 7200),
    sport = "running", distance = c(5234, .TCX_DIST, 3000),
    duration = as.difftime(c(1391, .TCX_DUR, 900), units = "secs"),
    file = c("hae:x.json", "/data/tcx/y.tcx", "/data/tcx/z.tcx"),
    source = c("hae", "tcx", "tcx"), stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, list(NULL, "run-y"))

  # Two messages, in order: my_dbs_load() reports the skew it refuses to
  # repair, then .align_myruns() repairs it.
  msgs <- testthat::capture_messages(
    dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE,
                    verbose = FALSE)
  )
  expect_match(paste(msgs, collapse = "\n"), "olika längd")
  expect_match(paste(msgs, collapse = "\n"), "ur synk")

  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 2)
  expect_equal(length(after$myruns), 2)
  expect_equal(after$myruns[[1]], "run-y")
})

test_that("dedup_summaries is a no-op on an empty or single-source cache", {
  tmp <- withr::local_tempdir()
  empty <- .matrix_cache(file.path(tmp), data.frame(), list())
  expect_equal(nrow(dedup_summaries(empty$summaries, empty$myruns,
                                    dry_run = FALSE, verbose = FALSE)), 0)

  tmp2 <- withr::local_tempdir()
  hae_only <- data.frame(
    sessionStart = .TCX_START, sport = "running", distance = 5234,
    duration = as.difftime(1391, units = "secs"),
    file = "hae:x.json", source = "hae", stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp2, hae_only, list(NULL))
  before <- file.mtime(paths$summaries)
  expect_equal(nrow(dedup_summaries(paths$summaries, paths$myruns,
                                    dry_run = FALSE, verbose = FALSE)), 0)
  expect_identical(file.mtime(paths$summaries), before)
})

test_that("dedup_summaries needs either paths or TRANING_DATA", {
  withr::local_envvar(TRANING_DATA = "")
  expect_error(dedup_summaries(), "TRANING_DATA")
})
