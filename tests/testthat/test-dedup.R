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
