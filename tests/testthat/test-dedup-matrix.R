# Invariant matrix for cross-source deduplication.
#
# The match rule under test (R/health_export_workouts.R) has two
# criteria, ORed together:
#
#   start criterion:   |dstart| <= 300 s AND (distance within 20 % OR
#                      duration within 20 %); when neither quantity is
#                      comparable on both sides, time alone within 120 s.
#   overlap criterion: wall-clock intervals overlap by >= 60 s, both
#                      intervals are believable (a session over 6 h must
#                      imply >= 1 m/s), and one of three corroborations
#                      holds: the overlap covers >= 50 % of the shorter
#                      session, the two stop within 60 s of each other,
#                      or the distances agree within 20 %. Movement
#                      sports with a recorded distance only.
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
    # A session without a distance omits the block entirely, the way HAE
    # writes a strength workout. Passing NA through would be written as
    # the string "NA" and re-read as a coercion warning.
    distance = if (is.na(distance_km)) NULL else
      list(qty = distance_km, units = "km"),
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

# Nested but stopping half an hour before the longer session ends.
.NESTED_DT <- 2400
.NESTED_DUR <- 1800

# Barely overlapping: 90 s of shared wall clock, past the 60 s floor but
# with nothing to corroborate it — 5 % coverage, stopping half an hour
# later, distances far apart. Two sessions, not one.
.THIN_DT <- .LONG_DUR - 90
.THIN_DUR <- 1800

# The same 90 s, but the short session stops when the long one does.
.TAIL_DT <- .LONG_DUR - 90
.TAIL_DUR <- 90

# Two sessions that merely touch: 30 s of overlap, below the 60 s floor.
.BRUSH_DT <- .LONG_DUR - 30
.BRUSH_DUR <- 1800

.overlap_cases <- list(
  list(label = "second watch started midway, stopped together",
       dt = .MID_DT, dur = .MID_DUR, dist_km = 5.006, expect = TRUE),
  list(label = "short recording nested inside the long one",
       dt = .NESTED_DT, dur = .NESTED_DUR, dist_km = 4.196, expect = TRUE),
  list(label = "90 s of overlap with nothing to corroborate it",
       dt = .THIN_DT, dur = .THIN_DUR, dist_km = 6.0, expect = FALSE),
  list(label = "90 s of overlap, stopping together",
       dt = .TAIL_DT, dur = .TAIL_DUR, dist_km = 0.2, expect = TRUE),
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

test_that("the overlap criterion spares sessions without a distance", {
  # The physical argument only holds for sessions that moved the person
  # somewhere; without a distance there is nothing to stand on.
  r <- .dir_hae_into_cached_tcx(
    .MID_DT, NA_real_, .MID_DUR, "Utomhus Kör",
    tcx_distance = 24000, tcx_duration = .LONG_DUR,
    hae_end_s = .MID_DUR, tcx_end_s = .LONG_DUR)
  expect_false(r$collapsed)
  expect_equal(nrow(r$summaries), 2L)
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

# A pair of records with explicit wall-clock spans, for asserting the
# overlap criterion directly rather than through an importer. The starts
# are always far enough apart that the start criterion cannot fire, so a
# TRUE here is the overlap criterion and nothing else.
.span <- function(offset, span, distance = 8000, sport = "running",
                  end = TRUE) {
  start <- .TCX_START + offset
  row <- data.frame(sessionStart = start,
                    duration = as.difftime(span, units = "secs"),
                    distance = distance, sport = sport,
                    stringsAsFactors = FALSE)
  row$sessionEnd <- if (end) start + span else as.POSIXct(NA)
  row
}

test_that("the overlap floor is one minute", {
  long <- .span(0, 7980, distance = 24000)
  # A short session ending exactly when the long one does, so the
  # stop-time evidence holds and the floor is the only thing left to
  # decide. Its span is the overlap.
  tail_of <- function(ov) .span(7980 - ov, ov, distance = 200)

  expect_false(.is_same_workout(long, tail_of(30)))
  expect_false(.is_same_workout(long, tail_of(59)))
  expect_true(.is_same_workout(long, tail_of(60)))
  expect_true(.is_same_workout(long, tail_of(61)))
})

test_that("a thin overlap needs corroboration to count", {
  # Above the floor but with no evidence: 90 s shared, the short session
  # covering 5 % of itself, stopping half an hour later, over a distance
  # 75 % apart. This is the shape of the one verified false positive.
  long <- .span(0, 7980, distance = 24000)
  thin <- .span(7890, 1800, distance = 6000)
  expect_false(.is_same_workout(long, thin))

  # Each piece of evidence rescues it on its own.
  expect_true(.is_same_workout(long, .span(7890, 90, distance = 6000)))
  expect_true(.is_same_workout(long, .span(7890, 1800, distance = 23000)))
  expect_true(.is_same_workout(long, .span(6180, 1800, distance = 6000)))
})

test_that("a half-day interval is trusted only if it went somewhere", {
  # A corrupt sessionEnd swallows everything inside it; a backyard ultra
  # legitimately spans half a day. Pace, not length, separates them.
  broken <- .span(0, 52180, distance = 13948, sport = "cycling")  # 0.27 m/s
  ultra <- .span(0, 45000, distance = 84000)                      # 1.87 m/s
  inside <- .span(13337, 2056, distance = 6506, sport = "cycling")

  expect_false(.is_same_workout(broken, inside))
  expect_true(.is_same_workout(ultra, inside))
  # Symmetric: the implausible side may be either one.
  expect_false(.is_same_workout(inside, broken))
})

test_that("each corroboration threshold is pinned at its edge", {
  long <- .span(0, 7980, distance = 24000)

  # Coverage, with the other two pieces of evidence held out: the ends are
  # far apart and the distances 79 % apart, so only the fraction decides.
  coverage <- function(frac) {
    span <- 3000
    .span(-span + round(frac * span), span, distance = 4000)
  }
  expect_false(.is_same_workout(long, coverage(0.49)))
  expect_true(.is_same_workout(long, coverage(0.50)))
  expect_true(.is_same_workout(long, coverage(0.51)))

  # Distance, with coverage below half and the ends far apart.
  by_distance <- function(frac) .span(-9000 + 1200, 9000, distance = 24000 * frac)
  expect_false(.is_same_workout(long, by_distance(0.79)))
  expect_true(.is_same_workout(long, by_distance(0.80)))
  expect_true(.is_same_workout(long, by_distance(0.81)))
})

test_that("stopping together implies the coverage evidence as well", {
  # Two sessions that stop within the window of each other overlap along
  # the whole of the later-starting one, so the coverage fraction is
  # necessarily high too: the stop-time evidence is not an independent
  # third route into a match, it is a restatement of the second for every
  # session longer than twice the stop window. Recorded here because a
  # future simplification of the rule may drop it, and this says what
  # would and would not be lost.
  for (span_a in c(600, 1800, 3600, 7200)) {
    for (span_b in c(600, 1800, 3600, 7200)) {
      for (gap in c(0, 30, 60)) {
        start_b <- span_a + gap - span_b
        overlap <- min(span_a, start_b + span_b) - max(0, start_b)
        if (overlap < 60) next
        coverage <- overlap / min(span_a, span_b)
        expect_gte(coverage, 0.50)
      }
    }
  }

  # The shape itself still matches, which is what the data actually
  # contains: both watches stopped within seconds of one another.
  expect_true(.is_same_workout(.span(0, 7980, distance = 24000),
                               .span(6300, 1681, distance = 5006)))
})

test_that("the believability floor applies from either side of the pair", {
  # The pace test guards the interval, so it has to reject an implausible
  # one whichever argument it arrives in, and the cycling floor has to
  # follow the cycling row rather than the position.
  slow_ride <- .span(0, 12 * 3600, distance = 0.49 * 12 * 3600, sport = "cycling")
  inside <- .span(600, 2700, distance = 4000, sport = "cycling")
  expect_false(.is_same_workout(slow_ride, inside))
  expect_false(.is_same_workout(inside, slow_ride))

  # A cycling row is held to 0.50 even when it is the short side and the
  # long side is a believable run.
  long_run <- .span(0, 12 * 3600, distance = 1.30 * 12 * 3600)
  expect_false(.is_same_workout(
    long_run, .span(600, 2700, distance = 0.49 * 2700, sport = "cycling")))
  expect_true(.is_same_workout(
    long_run, .span(600, 2700, distance = 0.50 * 2700, sport = "cycling")))

  # The Swedish label reaches the same floor: a cache written from HAE
  # names must not fall through to the 0.10 default.
  expect_false(.is_same_workout(
    .span(0, 12 * 3600, distance = 0.49 * 12 * 3600, sport = "cykling"), inside))

  # The comparison is >=, so a row exactly on its floor is believed and
  # the row just beneath it is not. The nearest real case is a 2019-07-05
  # cycling row at 0.4996 m/s, which sits on the excluded side.
  span <- 12 * 3600
  on_floor <- .span(0, span, distance = 0.50 * span, sport = "cycling")
  just_under <- .span(0, span, distance = 0.4999 * span, sport = "cycling")
  expect_true(.is_same_workout(on_floor, inside))
  expect_false(.is_same_workout(just_under, inside))
  expect_true(.is_same_workout(inside, on_floor))
  expect_false(.is_same_workout(inside, just_under))
})

test_that("rename detection does not rewrite an Apple Watch file key", {
  # The detector matches any row starting within two seconds, and used to
  # accept an HAE row as the renamed predecessor of an incoming TCX. That
  # overwrote `hae:...` with the TCX path — losing the key that marks the
  # row's source — and returned early, so the fragment rule never ran.
  base_time <- as.POSIXct("2023-04-10 15:41:42", tz = "UTC")
  existing <- data.frame(
    sessionStart = base_time - 1, sessionEnd = base_time + 3179,
    sport = "running", distance = 10274,
    duration = as.difftime(3180, units = "secs"),
    file = "hae:Utomhus_Kor-20230410.json", source = "hae",
    stringsAsFactors = FALSE
  )

  res <- testthat::with_mocked_bindings(
    get_new_workouts(file.path(tempdir(), "20230410-154142.tcx"), existing,
                     list(NULL), verbose = FALSE),
    read_container = function(f, ...) {
      .fake_tcx(base_time, 460, 180, "running", f)
    },
    .package = "trackeR"
  )

  expect_equal(nrow(res$summaries), 1)
  expect_equal(res$summaries$source, "hae")
  expect_equal(res$summaries$file, "hae:Utomhus_Kor-20230410.json")
  expect_equal(res$n_updated, 0)
})

test_that("the believability floor is a pace, per sport, at any length", {
  # There is no span threshold: a session is judged on the pace its
  # interval implies, so a half-day ultra and a 20-minute run are held to
  # the same standard and only the sport changes it.
  ride <- function(speed, span = 12 * 3600) {
    .span(0, span, distance = speed * span, sport = "cycling")
  }
  run <- function(speed, span = 12 * 3600) .span(0, span, distance = speed * span)
  inside_ride <- .span(600, 2700, distance = 4000, sport = "cycling")
  inside_run <- .span(600, 2700, distance = 4000)

  # Cycling floor: 0.50 m/s.
  expect_false(.is_same_workout(ride(0.49), inside_ride))
  expect_true(.is_same_workout(ride(0.50), inside_ride))
  # Running floor: 0.10 m/s. A twelve-hour backyard ultra at any
  # believable pace is matchable, which a span cap would have prevented.
  expect_false(.is_same_workout(run(0.09), inside_run))
  expect_true(.is_same_workout(run(0.10), inside_run))
  expect_true(.is_same_workout(run(0.96), inside_run))
  expect_true(.is_same_workout(run(1.30, span = 15 * 3600),
                               .span(600, 2700, distance = 4000)))
})

test_that("a bike ride stopped late is not the run that followed it", {
  # 2022-05-07 in the real cache, and the one candidate the corroboration
  # gates removed: the Apple Watch kept recording a 2.5 km ride for seven
  # minutes after the Garmin run had started. Overlapping, but 35 %
  # coverage, stops 13 minutes apart and distances 47 % apart — every
  # piece of evidence says two sessions, and removing the ride would have
  # deleted a session Garmin never recorded.
  ride <- .span(0, 1601, distance = 2554, sport = "cycling")
  run <- .span(1169, 1223, distance = 4798, sport = "running")
  expect_false(.is_same_workout(ride, run))
  expect_false(.is_same_workout(run, ride))
})

test_that("the overlap criterion needs an end and a distance on both sides", {
  long <- .span(0, 7980, distance = 24000)
  nested <- .span(2400, 1800, distance = 4196)
  expect_true(.is_same_workout(long, nested))

  # Without an end there is no interval to intersect, and the pair falls
  # back to the start criterion — which these starts are far outside.
  expect_false(.is_same_workout(long, .span(2400, 1800, distance = 4196,
                                            end = FALSE)))
  expect_false(.is_same_workout(.span(0, 7980, distance = 24000, end = FALSE),
                                nested))

  # Without a distance the session may not be a distance-bearing one, and
  # the physical argument behind the criterion no longer applies.
  expect_false(.is_same_workout(long, .span(2400, 1800, distance = NA_real_)))
  expect_false(.is_same_workout(.span(0, 7980, distance = NA_real_), nested))
})

test_that("the overlap exemption applies from either side of the pair", {
  nested <- .span(2400, 1800, distance = 4196)
  for (sport in c("strength", "karntraning", "ovrigt", "unknown", "")) {
    expect_false(
      .is_same_workout(.span(0, 7980, distance = 24000, sport = sport), nested),
      info = paste("exempt on the long side:", sport))
    expect_false(
      .is_same_workout(.span(0, 7980, distance = 24000),
                       .span(2400, 1800, distance = 4196, sport = sport)),
      info = paste("exempt on the short side:", sport))
  }
  # The label is matched case- and whitespace-insensitively.
  expect_false(.is_same_workout(
    .span(0, 7980, distance = 24000, sport = " Strength "), nested))
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

test_that("Garmin keeps the session when it is split across two files", {
  # The watch stopped and restarted mid-run, so neither Garmin row is
  # half the Apple Watch distance on its own while together they are the
  # whole session. Deferring to the Apple Watch row here would leave the
  # run counted twice: once on the wrist, once as the two Garmin pieces.
  # 2024-01-06 in the cache, and the shape behind four more days.
  aw <- 7815
  expect_false(.garmin_wins(aw, 2573))            # the first piece alone
  expect_true(.garmin_wins(aw, 5190))             # the second piece alone
  # ... so the session stays with Garmin, which is what the importer and
  # dedup_summaries() both act on.

  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2024-01-06 11:39:15", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 30, start + 1344),
    sessionEnd = c(start + 2969, start + 864, start + 2853),
    sport = "running", distance = c(aw, 2573, 5190),
    duration = as.difftime(c(2969, 834, 1509), units = "secs"),
    file = c("hae:Utomhus_Kor-20240106.json", "20240106-113950.tcx",
             "20240106-120144.tcx"),
    source = c("hae", "tcx", "tcx"), stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, list(NULL, "r1", "r2"))
  dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE, verbose = FALSE)

  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 2)
  expect_true(all(after$summaries$source == "tcx"))

  # Where every Garmin row really is a fragment, the Apple Watch row is
  # the one that survives and both fragments are recorded on it.
  #
  # Note the loop: a single call clears only one fragment per Apple Watch
  # row, so a session split into two sub-half pieces needs a second pass
  # to settle. Two days in the cache are of that shape (2019-12-23 and
  # 2024-11-18), where one pass leaves an orphan Garmin fragment behind
  # and the session still counted twice. The assertions below are on the
  # converged state, which holds whether the cleanup gets there in one
  # pass or two.
  tmp2 <- withr::local_tempdir()
  summaries$distance <- c(aw, 900, 1000)
  paths2 <- .matrix_cache(tmp2, summaries, list(NULL, "r1", "r2"))
  for (pass in 1:2) {
    dedup_summaries(paths2$summaries, paths2$myruns, dry_run = FALSE,
                    verbose = FALSE)
  }

  after2 <- my_dbs_load(paths2$summaries, paths2$myruns)
  expect_equal(nrow(after2$summaries), 1)
  expect_equal(after2$summaries$source, "hae")
  expect_equal(length(after2$myruns), 1)
  expect_equal(as.numeric(after2$summaries$distance), aw)

  # ... and the cleanup is a fixed point once it has settled.
  dedup_summaries(paths2$summaries, paths2$myruns, dry_run = FALSE,
                  verbose = FALSE)
  settled <- my_dbs_load(paths2$summaries, paths2$myruns)
  expect_equal(nrow(settled$summaries), 1)
  expect_equal(settled$summaries$source, "hae")
})

test_that("clearing a fragment survives the file being re-imported", {
  # The cleanup unlists the Garmin fragment but leaves the .tcx on disk,
  # so the next fetch reads it again. Nothing records that it lost, so
  # the protection has to come from the import path judging it a fragment
  # a second time — otherwise the 460 m row is handed the session back
  # and the real one is deleted.
  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2023-04-10 15:41:41", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 1),
    sessionEnd = c(start + 3180, start + 180),
    sport = "running", distance = c(10274, 460),
    duration = as.difftime(c(3180, 180), units = "secs"),
    file = c("hae:Utomhus_Kor-20230410.json", "20230410-154142.tcx"),
    source = c("hae", "tcx"), stringsAsFactors = FALSE
  )
  paths <- .matrix_cache(tmp, summaries, list(NULL, "fragment-run"))

  dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE,
                  verbose = FALSE)

  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "hae")
  expect_equal(length(after$myruns), 1)
  # The cleanup leaves no trace on the row, so the cache gains no column.
  expect_false("superseded_file" %in% names(after$summaries))

  # Now the fetch that reads the unlisted file again — three times over,
  # since it is re-read on every import for as long as it sits on disk.
  tcx_path <- file.path(tmp, "20230410-154142.tcx")
  writeLines("placeholder", tcx_path)
  cur <- after$summaries
  runs <- after$myruns
  for (pass in 1:3) {
    res <- testthat::with_mocked_bindings(
      get_new_workouts(tcx_path, cur, runs, verbose = FALSE),
      read_container = function(f, ...) {
        .fake_tcx(start + 1, 460, 180, "running", f)
      },
      .package = "trackeR"
    )
    cur <- res$summaries
    runs <- res$myruns
    expect_equal(nrow(cur), 1, info = paste("pass", pass))
    expect_equal(cur$source, "hae", info = paste("pass", pass))
    expect_equal(as.numeric(cur$distance), 10274, info = paste("pass", pass))
    expect_equal(res$n_garmin_fragments, 1, info = paste("pass", pass))
    expect_equal(length(runs), nrow(cur), info = paste("pass", pass))
  }
})

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

test_that("a row sitting exactly on its speed floor is believed", {
  # Documented as >=: the floors are set at impossible rather than
  # merely unusual paces, so the boundary carries no evidence and the
  # permissive side is the one that cannot delete real data.
  ride <- function(speed) .span(0, 3600, distance = speed * 3600,
                                sport = "cycling")
  inside <- .span(600, 2700, distance = 5000, sport = "cycling")
  expect_true(.is_same_workout(ride(0.50), inside))
  expect_false(.is_same_workout(ride(0.4999), inside))
})

# --- batch composition --------------------------------------------------------
#
# The winner rules run over sets — every wrist row a file matches, every
# Garmin leg already held for that session, every leg still parked in the
# batch — and the sets are built at different moments from different
# populations. These cases vary what a single batch contains and the
# order it arrives in, since arrival order is an accident of the file
# system and must never change the cache it produces.

.batch_registry <- new.env(parent = emptyenv())

.batch_file <- function(name, start, distance, duration) {
  path <- file.path(tempdir(), name)
  assign(path, list(start = start, distance = distance, duration = duration),
         envir = .batch_registry)
  path
}

.batch_reader <- function(f, ...) {
  spec <- get(f, envir = .batch_registry)
  .fake_tcx(spec$start, spec$distance, spec$duration, "running", f)
}

.batch_wrist <- function(start, distance, duration, file) {
  data.frame(sessionStart = start, sessionEnd = start + duration,
             sport = "running", distance = distance,
             duration = as.difftime(duration, units = "secs"),
             file = file, source = "hae", stringsAsFactors = FALSE)
}

.import_batch <- function(files, cache) {
  testthat::with_mocked_bindings(
    get_new_workouts(files, cache, vector("list", nrow(cache)), verbose = FALSE),
    read_container = .batch_reader, .package = "trackeR")
}

.B0 <- as.POSIXct("2026-03-01 08:00:00", tz = "UTC")

test_that("arrival order does not change what a batch imports", {
  # Three legs of one session. Individually each is a fragment of the
  # 10 km the wrist holds; together they are 5300 m, over the half that
  # keeps the session with Garmin.
  wrist <- .batch_wrist(.B0, 10000, 5400, "hae:session.json")
  legs <- c(.batch_file("perm-a.tcx", .B0 + 60, 2000, 1200),
            .batch_file("perm-b.tcx", .B0 + 2000, 2400, 1200),
            .batch_file("perm-c.tcx", .B0 + 4000, 900, 1000))

  for (order in list(c(1, 2, 3), c(3, 2, 1), c(2, 1, 3),
                     c(2, 3, 1), c(3, 1, 2), c(1, 3, 2))) {
    res <- .import_batch(legs[order], wrist)
    label <- paste(order, collapse = ">")
    expect_equal(nrow(res$summaries), 3, info = label)
    expect_true(all(res$summaries$source == "tcx"), info = label)
    expect_equal(sum(as.numeric(res$summaries$distance)), 5300, info = label)
    expect_equal(res$n_hae_removed, 1, info = label)
    expect_equal(length(res$myruns), nrow(res$summaries), info = label)
  }
})

test_that("legs that stay under the bar leave the wrist row alone, in any order", {
  wrist <- .batch_wrist(.B0, 10000, 5400, "hae:session.json")
  legs <- c(.batch_file("under-a.tcx", .B0 + 60, 1500, 1200),
            .batch_file("under-b.tcx", .B0 + 2000, 1500, 1200),
            .batch_file("under-c.tcx", .B0 + 4000, 1500, 1000))

  for (order in list(c(1, 2, 3), c(3, 2, 1), c(2, 1, 3))) {
    res <- .import_batch(legs[order], wrist)
    label <- paste(order, collapse = ">")
    # 4500 m against 10 km: Garmin caught less than half, so none of the
    # legs is written and the wrist keeps the session.
    expect_equal(nrow(res$summaries), 1, info = label)
    expect_equal(res$summaries$source, "hae", info = label)
    expect_equal(as.numeric(res$summaries$distance), 10000, info = label)
    expect_equal(res$n_garmin_fragments, 3, info = label)
  }
})

test_that("two copies of one leg in a batch are weighed as one recording", {
  # The same recording under two names must not be summed into a session
  # Garmin only caught half of.
  wrist <- .batch_wrist(.B0, 10000, 5400, "hae:session.json")
  copies <- c(.batch_file("copy-first.tcx", .B0 + 60, 4000, 1800),
              .batch_file("copy-second.tcx", .B0 + 61, 4000, 1800))

  res <- .import_batch(copies, wrist)
  expect_equal(nrow(res$summaries), 1)
  expect_equal(res$summaries$source, "hae")
  expect_equal(res$n_garmin_fragments, 1)

  # 4000 + 4000 would clear the bar; one recording of 4000 does not.
  expect_false(.garmin_wins(10000, 4000))
  expect_true(.garmin_wins(10000, 8000))
})

test_that("both wrist copies of a session go when Garmin takes it", {
  wrist <- rbind(
    .batch_wrist(.B0, 10000, 5400, "hae:full.json"),
    .batch_wrist(.B0 + 3, 8000, 5200, "hae:mirror.json"))
  legs <- c(.batch_file("pair-a.tcx", .B0 + 60, 3000, 1500),
            .batch_file("pair-b.tcx", .B0 + 3000, 2600, 1500))

  for (order in list(c(1, 2), c(2, 1))) {
    res <- .import_batch(legs[order], wrist)
    label <- paste(order, collapse = ">")
    expect_equal(nrow(res$summaries), 2, info = label)
    expect_true(all(res$summaries$source == "tcx"), info = label)
    expect_equal(res$n_hae_removed, 2, info = label)
    expect_equal(length(res$myruns), nrow(res$summaries), info = label)
  }
})

test_that("a fragment of one session is not weighed into another", {
  # Two wrist sessions hours apart. A big leg takes the first; a fragment
  # of the second must still lose to the second, rather than ride in on
  # the first one's total.
  wrist <- rbind(
    .batch_wrist(.B0, 10000, 5400, "hae:morning.json"),
    .batch_wrist(.B0 + 7000, 3000, 1800, "hae:evening.json"))
  big <- .batch_file("sep-big.tcx", .B0 + 60, 6000, 5000)
  small <- .batch_file("sep-small.tcx", .B0 + 7100, 200, 1500)

  for (order in list(c(big, small), c(small, big))) {
    res <- .import_batch(order, wrist)
    label <- basename(order[1])
    expect_equal(nrow(res$summaries), 2, info = label)
    expect_setequal(res$summaries$source, c("hae", "tcx"))
    # The evening wrist row survives with its own distance.
    evening <- res$summaries[res$summaries$source == "hae", ]
    expect_equal(as.numeric(evening$distance), 3000, info = label)
    expect_equal(res$n_garmin_fragments, 1, info = label)
    expect_equal(res$n_hae_removed, 1, info = label)
  }
})
