# Tests for R/dedup.R and the summaries/myruns alignment in R/import.R

.dedup_summaries_fixture <- function() {
  data.frame(
    sessionStart = as.POSIXct(
      c("2026-08-01 11:00:49", "2026-08-01 11:02:36", "2026-07-20 06:00:00"),
      tz = "UTC"),
    sport = c("running", "running", "cycling"),
    distance = c(5234, 5292, 20000),
    duration = as.difftime(c(1391, 1376, 3600), units = "secs"),
    file = c("hae:Utomhus_Kor-20260801_130049.json",
             "/data/tcx/20260801-110236.tcx",
             "hae:Cykling-20260720.json"),
    source = c("hae", "tcx", "hae"),
    stringsAsFactors = FALSE
  )
}

.write_fixture_cache <- function(dir, summaries, myruns) {
  db_s <- file.path(dir, "summaries.RData")
  db_m <- file.path(dir, "myruns.RData")
  save(summaries, file = db_s)
  save(myruns, file = db_m)
  list(summaries = db_s, myruns = db_m)
}

test_that("dedup_summaries dry-run reports without touching the cache", {
  tmp <- withr::local_tempdir()
  s <- .dedup_summaries_fixture()
  paths <- .write_fixture_cache(tmp, s, list(NULL, "run-object", NULL))
  before <- file.mtime(paths$summaries)

  dups <- dedup_summaries(paths$summaries, paths$myruns,
                          dry_run = TRUE, verbose = FALSE)

  expect_equal(nrow(dups), 1)
  expect_equal(dups$idx, 1L)
  expect_equal(dups$dt_seconds, 107)
  expect_identical(file.mtime(paths$summaries), before)
})

test_that("dedup_summaries removes the HAE row and its myruns slot", {
  tmp <- withr::local_tempdir()
  s <- .dedup_summaries_fixture()
  paths <- .write_fixture_cache(tmp, s, list(NULL, "run-object", NULL))

  dedup_summaries(paths$summaries, paths$myruns,
                  dry_run = FALSE, verbose = FALSE)

  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 2)
  expect_equal(length(after$myruns), 2)
  # Sorted by sessionStart: the July cycling row first, then the Garmin
  # row that replaced its Apple Watch twin.
  expect_equal(after$summaries$source, c("hae", "tcx"))
  # The trackeR object must still sit on the Garmin row after the
  # removal and the re-sort inside my_dbs_save().
  expect_null(after$myruns[[1]])
  expect_equal(after$myruns[[2]], "run-object")
})

test_that("dedup_summaries leaves genuine Apple-Watch-only sessions alone", {
  tmp <- withr::local_tempdir()
  s <- .dedup_summaries_fixture()[c(1, 3), ]
  paths <- .write_fixture_cache(tmp, s, list(NULL, NULL))

  dups <- dedup_summaries(paths$summaries, paths$myruns,
                          dry_run = TRUE, verbose = FALSE)
  expect_equal(nrow(dups), 0)
})

test_that("my_dbs_save keeps myruns aligned with the sorted summaries", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = as.POSIXct(c("2026-03-03", "2026-01-01", "2026-02-02"),
                              tz = "UTC"),
    sport = "running",
    file = c("c.tcx", "a.tcx", "b.tcx"),
    source = "tcx",
    stringsAsFactors = FALSE
  )
  myruns <- list("c", "a", "b")
  db_s <- file.path(tmp, "summaries.RData")
  db_m <- file.path(tmp, "myruns.RData")

  my_dbs_save(db_s, db_m, summaries, myruns)

  after <- my_dbs_load(db_s, db_m)
  expect_equal(after$summaries$file, c("a.tcx", "b.tcx", "c.tcx"))
  expect_equal(unlist(after$myruns), c("a", "b", "c"))
})

test_that("my_dbs_save drops myruns entries for deduplicated rows", {
  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2026-01-01 10:00:00", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start, start + 3600),
    sport = "running",
    file = c("dup-first.tcx", "dup-second.tcx", "later.tcx"),
    source = "tcx",
    stringsAsFactors = FALSE
  )
  db_s <- file.path(tmp, "summaries.RData")
  db_m <- file.path(tmp, "myruns.RData")

  my_dbs_save(db_s, db_m, summaries, list("first", "second", "later"))

  after <- my_dbs_load(db_s, db_m)
  expect_equal(after$summaries$file, c("dup-first.tcx", "later.tcx"))
  expect_equal(unlist(after$myruns), c("first", "later"))
})

test_that("my_dbs_save repairs a myruns list that is too short", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = as.POSIXct(c("2026-01-01", "2026-01-02"), tz = "UTC"),
    sport = "running",
    file = c("a.tcx", "b.tcx"),
    source = "tcx",
    stringsAsFactors = FALSE
  )
  db_s <- file.path(tmp, "summaries.RData")
  db_m <- file.path(tmp, "myruns.RData")

  expect_message(my_dbs_save(db_s, db_m, summaries, list("a")),
                 "ur synk")

  after <- my_dbs_load(db_s, db_m)
  expect_equal(nrow(after$summaries), length(after$myruns))
})

test_that("my_dbs_save preserves the garmin augmentation stamp", {
  tmp <- withr::local_tempdir()
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-01-01", tz = "UTC"),
    sport = "running", file = "a.tcx", source = "tcx",
    stringsAsFactors = FALSE
  )
  stamp <- as.POSIXct("2026-05-01 12:00:00", tz = "UTC")
  attr(summaries, "garmin_augmented_at") <- stamp
  db_s <- file.path(tmp, "summaries.RData")
  db_m <- file.path(tmp, "myruns.RData")

  my_dbs_save(db_s, db_m, summaries, list(NULL))

  after <- my_dbs_load(db_s, db_m)
  expect_equal(attr(after$summaries, "garmin_augmented_at"), stamp)
})

# --- fragment rule ------------------------------------------------------------

test_that(".garmin_wins defers only when Garmin caught a fragment", {
  # The ordinary GPS-versus-wrist disagreement stays with Garmin.
  expect_true(.garmin_wins(10000, 9000))
  expect_true(.garmin_wins(10000, 8300))   # ratio 1.2
  expect_true(.garmin_wins(10000, 5000))   # ratio 2.0, the boundary
  # Below half the Apple Watch distance, Garmin is only a fragment.
  expect_false(.garmin_wins(10000, 4999))
  expect_false(.garmin_wins(10274, 460))   # 2023-04-10
  # A missing distance leaves the default in place.
  expect_true(.garmin_wins(NA_real_, 460))
  expect_true(.garmin_wins(10274, NA_real_))
})

test_that("dedup_summaries keeps the Apple Watch row when Garmin has a fragment", {
  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2023-04-10 15:41:41", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 1),
    sessionEnd = c(start + 3180, start + 180),
    sport = "running",
    distance = c(10274, 460),
    duration = as.difftime(c(3180, 180), units = "secs"),
    file = c("hae:Utomhus_Kor-20230410.json", "/data/tcx/20230410-154142.tcx"),
    source = c("hae", "tcx"),
    stringsAsFactors = FALSE
  )
  paths <- .write_fixture_cache(tmp, summaries, list(NULL, "garmin-run"))

  dups <- dedup_summaries(paths$summaries, paths$myruns,
                          dry_run = TRUE, verbose = FALSE)
  expect_equal(dups$winner, "aw")

  dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE, verbose = FALSE)
  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "hae")
  expect_equal(after$summaries$distance, 10274)
  expect_equal(length(after$myruns), 1)
})

test_that("dedup_summaries keeps Garmin when a second row covers the session", {
  # A Garmin watch stopped and restarted writes two files. Each is short
  # against the Apple Watch total, but together they are the session, so
  # Garmin still wins and both Garmin rows survive.
  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2025-07-07 14:31:44", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 5, start + 2600),
    sessionEnd = c(start + 5400, start + 2500, start + 5400),
    sport = "running",
    distance = c(11124, 4292, 6961),
    duration = as.difftime(c(5400, 2495, 2800), units = "secs"),
    file = c("hae:Utomhus_Kor-20250707.json",
             "/data/tcx/20250707-a.tcx", "/data/tcx/20250707-b.tcx"),
    source = c("hae", "tcx", "tcx"),
    stringsAsFactors = FALSE
  )
  paths <- .write_fixture_cache(tmp, summaries, list(NULL, "a", "b"))

  dups <- dedup_summaries(paths$summaries, paths$myruns,
                          dry_run = TRUE, verbose = FALSE)
  expect_equal(dups$winner, "garmin")

  dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE, verbose = FALSE)
  after <- my_dbs_load(paths$summaries, paths$myruns)
  expect_equal(nrow(after$summaries), 2)
  expect_setequal(after$summaries$source, "tcx")
})

test_that("dedup_summaries removes every fragment of a session in one pass", {
  # 2019-12-23 in the real cache: the Garmin watch was stopped and
  # restarted, leaving two short rows against one 6.4 km Apple Watch
  # session. Removing only the nearest leaves the other orphaned and
  # 3 km double-counted until someone runs the cleanup again.
  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2019-12-23 10:18:27", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 5, start + 1560),
    sessionEnd = c(start + 2700, start + 1500, start + 2700),
    sport = "running",
    distance = c(6387, 2286, 3031),
    duration = as.difftime(c(2700, 1495, 1140), units = "secs"),
    file = c("hae:Utomhus_Kor-20191223.json",
             "/data/tcx/20191223-091822.tcx",
             "/data/tcx/20191223-094423.tcx"),
    source = c("hae", "tcx", "tcx"),
    stringsAsFactors = FALSE
  )
  paths <- .write_fixture_cache(tmp, summaries, list(NULL, "frag-a", "frag-b"))

  dups <- dedup_summaries(paths$summaries, paths$myruns,
                          dry_run = TRUE, verbose = FALSE)
  expect_equal(dups$winner, "aw")
  expect_equal(length(dups$tcx_drop[[1]]), 2)

  dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE,
                  verbose = FALSE)
  after <- my_dbs_load(paths$summaries, paths$myruns)

  # One pass, one row left, and the total is the session — not the
  # session plus a leftover fragment.
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "hae")
  expect_equal(sum(after$summaries$distance), 6387)
  expect_equal(length(after$myruns), 1)

  # A second pass has nothing left to do.
  again <- dedup_summaries(paths$summaries, paths$myruns,
                           dry_run = TRUE, verbose = FALSE)
  expect_equal(nrow(again), 0)
})

test_that("dedup_summaries keeps one Apple Watch copy when a fragment loses to two", {
  # Caches written before the HAE-to-HAE dedup existed can hold both
  # copies HAE delivers for a session. When a Garmin fragment loses to
  # the pair, removing only the fragment leaves two rows for one
  # session — the very double count this cleanup exists to remove.
  tmp <- withr::local_tempdir()
  start <- as.POSIXct("2023-04-10 15:41:41", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 3, start + 1),
    sessionEnd = c(start + 3180, start + 3179, start + 180),
    sport = "running",
    # The mirrored copy caught slightly less; the richer one survives.
    distance = c(10274, 10101, 460),
    duration = as.difftime(c(3180, 3176, 180), units = "secs"),
    file = c("hae:Utomhus_Kor-20230410.json",
             "hae:Utomhus_Kor-20230410-connect.json",
             "/data/tcx/20230410-154142.tcx"),
    source = c("hae", "hae", "tcx"),
    stringsAsFactors = FALSE
  )
  paths <- .write_fixture_cache(tmp, summaries, list(NULL, NULL, "garmin-run"))

  dedup_summaries(paths$summaries, paths$myruns, dry_run = FALSE,
                  verbose = FALSE)
  after <- my_dbs_load(paths$summaries, paths$myruns)

  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "hae")
  expect_equal(after$summaries$distance, 10274)
  expect_equal(length(after$myruns), 1)
})
