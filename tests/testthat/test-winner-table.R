# Decision table for the winner rules where they meet more than one
# Apple Watch copy of a session.
#
# HAE delivers two files per session, the watch's own recording and a
# Garmin-Connect-mirrored copy, and a cache written before the
# HAE-to-HAE dedup existed can hold both — usually with different
# distances, since each captured what it captured. Every decision in the
# import then has to answer the same question twice: which copy is the
# session, and does the Garmin side beat it.
#
# The table enumerates cache content against what arrives next and
# states what should be left. Cells the code cannot reach are named in
# the comments rather than tested.

.SESSION_START <- as.POSIXct("2024-11-18 16:42:05", tz = "UTC")

# A stand-in for a parsed TCX. Defined here rather than borrowed from
# another test file: testthat gives each file its own environment, so a
# helper from elsewhere is simply missing, read_container() fails, and
# every file is skipped — which looks like "the cache was left alone"
# and would let most of the table below pass without testing anything.
.fake_summary <- function(start, distance, file) {
  data.frame(
    session = 1L, sessionStart = start, sessionEnd = start + 3600,
    distance = distance,
    duration = as.difftime(3600, units = "secs"),
    durationMoving = as.difftime(3600, units = "secs"),
    avgSpeed = 2.5, avgSpeedMoving = 2.8, avgPace = 6.5, avgPaceMoving = 5.9,
    avgCadenceRunning = 85, avgCadenceRunningMoving = 87,
    avgHeartRate = 135, avgHeartRateMoving = 140,
    sport = "running", file = file, stringsAsFactors = FALSE
  )
}
summary.winnertable <- function(object, ...) object$the_summary
registerS3method("summary", "winnertable", summary.winnertable,
                 envir = environment())
.fake_parsed <- function(start, distance, file) {
  structure(list(the_summary = .fake_summary(start, distance, file)),
            class = "winnertable")
}

# A cached row, by role. "full" and "short" are the two HAE copies.
.row_for <- function(role) {
  spec <- switch(
    role,
    full  = list(d = 10000, src = "hae", file = "hae:native.json",   off = 0),
    short = list(d = 6000,  src = "hae", file = "hae:connect.json",  off = 3),
    fragment = list(d = 620, src = "tcx", file = "/tcx/fragment.tcx", off = 1),
    covering = list(d = 9500, src = "tcx", file = "/tcx/covering.tcx", off = 1)
  )
  data.frame(
    sessionStart = .SESSION_START + spec$off,
    sessionEnd = .SESSION_START + spec$off + 3600,
    sport = "running",
    distance = spec$d,
    duration = as.difftime(3600, units = "secs"),
    file = spec$file,
    source = spec$src,
    stringsAsFactors = FALSE
  )
}

.cache_of <- function(roles) {
  if (length(roles) == 0) return(data.frame())
  do.call(rbind, lapply(roles, .row_for))
}

# Import a TCX of the given role against a cache holding `roles`.
.after_tcx <- function(roles, incoming) {
  cache <- .cache_of(roles)
  spec <- .row_for(incoming)
  path <- file.path(tempdir(), basename(spec$file))
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      .fake_parsed(spec$sessionStart, spec$distance, file)
    },
    .package = "trackeR"
  )
  res <- get_new_workouts(path, cache,
                          vector("list", nrow(cache)), verbose = FALSE)
  sort(round(as.numeric(res$summaries$distance)))
}

test_that("a Garmin file must beat the best Apple Watch copy, not the worst", {
  # Cache: both copies. A fragment beats neither, and a file that beats
  # only the short copy must not evict the full one along with it —
  # eviction takes every matching row.
  expect_equal(.after_tcx(c("full", "short"), "fragment"), c(6000, 10000))

  # 9500 m covers both copies, so it takes the session and both go.
  expect_equal(.after_tcx(c("full", "short"), "covering"), 9500)
})

test_that("a single Apple Watch copy behaves as it always did", {
  # One copy, full: a fragment loses, a covering file wins.
  expect_equal(.after_tcx("full", "fragment"), 10000)
  expect_equal(.after_tcx("full", "covering"), 9500)

  # One copy, short: 620 m is still under half of 6000.
  expect_equal(.after_tcx("short", "fragment"), 6000)
  expect_equal(.after_tcx("short", "covering"), 9500)
})

test_that("an empty cache takes whatever arrives", {
  expect_equal(.after_tcx(character(0), "fragment"), 620)
  expect_equal(.after_tcx(character(0), "covering"), 9500)
})

# --- the HAE side ------------------------------------------------------------

.write_session_json <- function(dir, name, distance_km, offset = 0) {
  start <- .SESSION_START + offset
  payload <- list(data = list(workouts = list(list(
    id = name, name = "Utomhus Kör",
    start = format(start, "%Y-%m-%d %H:%M:%S +0000", tz = "UTC"),
    end = format(start + 3600, "%Y-%m-%d %H:%M:%S +0000", tz = "UTC"),
    duration = 3600,
    distance = list(qty = distance_km, units = "km"),
    avgHeartRate = list(qty = 140, units = "count/min")
  ))))
  jsonlite::write_json(payload, file.path(dir, paste0(name, ".json")),
                       auto_unbox = TRUE, null = "null")
}

.after_hae <- function(roles, incoming_km) {
  dir <- withr::local_tempdir()
  .write_session_json(dir, "incoming", incoming_km)
  cache <- .cache_of(roles)
  res <- import_hae_workouts(dir, cache, vector("list", nrow(cache)))
  list(distances = sort(round(as.numeric(res$summaries$distance))),
       sources = sort(res$summaries$source))
}

test_that("an HAE file turned away leaves the Garmin row where it was", {
  # Cache: the short copy plus a Garmin fragment. The incoming full copy
  # matches both. It is turned away as a duplicate of the cached copy —
  # and the fragment it would have replaced must still be there, since
  # nothing was imported to replace it with.
  out <- .after_hae(c("short", "fragment"), incoming_km = 10)
  expect_equal(out$distances, c(620, 6000))
  expect_equal(out$sources, c("hae", "tcx"))
})

test_that("an HAE file that is imported does replace the Garmin fragment", {
  # The same shape without the cached copy: nothing turns the file away,
  # so it lands and the fragment goes.
  out <- .after_hae("fragment", incoming_km = 10)
  expect_equal(out$distances, 10000)
  expect_equal(out$sources, "hae")
})

test_that("an HAE file loses to a Garmin row that covers the session", {
  out <- .after_hae("covering", incoming_km = 10)
  expect_equal(out$distances, 9500)
  expect_equal(out$sources, "tcx")
})

# --- one recording under two names -------------------------------------------
#
# Counting copies of a recording as separate legs is the way a fragment
# gets over the threshold without covering anything: two copies of 40 %
# add up to 80 %. Every path that sums Garmin distances has to collapse
# them first, and every path still removes all the copies afterwards.

.two_copies_cache <- function(aw_distance, copy_distance) {
  start <- .SESSION_START
  data.frame(
    sessionStart = c(start, start + 1, start + 2),
    sessionEnd = c(start + 3600, start + 1700, start + 1701),
    sport = "running",
    distance = c(aw_distance, copy_distance, copy_distance),
    duration = as.difftime(c(3600, 1700, 1700), units = "secs"),
    file = c("hae:native.json", "/tcx/copy-a.tcx", "/tcx/copy-b.tcx"),
    source = c("hae", "tcx", "tcx"),
    stringsAsFactors = FALSE
  )
}

test_that("the cleanup counts two copies of a fragment once", {
  tmp <- withr::local_tempdir()
  summaries <- .two_copies_cache(aw_distance = 10000, copy_distance = 4000)
  db_s <- file.path(tmp, "summaries.RData")
  db_m <- file.path(tmp, "myruns.RData")
  myruns <- list(NULL, "a", "b")
  save(summaries, file = db_s)
  save(myruns, file = db_m)

  dups <- dedup_summaries(db_s, db_m, dry_run = TRUE, verbose = FALSE)
  # 4000 m, not 8000: the Apple Watch row keeps the session.
  expect_equal(dups$winner, "aw")
  # Both copies still go when it is applied.
  expect_equal(length(dups$tcx_drop[[1]]), 2)

  dedup_summaries(db_s, db_m, dry_run = FALSE, verbose = FALSE)
  after <- my_dbs_load(db_s, db_m)
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$distance, 10000)
})

test_that("the import counts two cached copies of a fragment once", {
  # The same cache, met by a third copy arriving as a new file: the
  # cached pair must not add up to a session Garmin never recorded.
  summaries <- .two_copies_cache(aw_distance = 10000, copy_distance = 4000)
  path <- file.path(tempdir(), "copy-c.tcx")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      .fake_parsed(.SESSION_START + 3, 4000, file)
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(path, summaries, list(NULL, "a", "b"),
                          verbose = FALSE)

  # Nothing new imported and the Apple Watch row survives.
  expect_equal(res$n_imported, 0)
  expect_true("hae" %in% res$summaries$source)
  expect_equal(max(res$summaries$distance), 10000)
})

test_that("the HAE import counts two cached copies of a fragment once", {
  dir <- withr::local_tempdir()
  .write_session_json(dir, "incoming", 10)
  cache <- .two_copies_cache(aw_distance = 10000, copy_distance = 4000)
  # Drop the cached Apple Watch row: the incoming file is that session.
  cache <- cache[cache$source == "tcx", ]

  res <- import_hae_workouts(dir, cache, list("a", "b"))

  # 4000 m against 10000 m is a fragment, so the file lands and both
  # copies of the fragment go.
  expect_equal(res$n_imported, 1)
  expect_equal(nrow(res$summaries), 1)
  expect_equal(res$summaries$source, "hae")
})
