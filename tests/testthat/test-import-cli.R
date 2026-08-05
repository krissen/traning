# Regression tests for the save decision in inst/cli.R's --import path.
#
# The import can change the cache without changing its row count: a
# Garmin file that evicts the Apple Watch row for the same session
# swaps one row for another. Keying the save on the row count alone
# left those edits in memory, so the duplicate came back on the next
# run. These tests drive the real script, because the predicate lives
# there and nowhere else.

`%||%` <- function(a, b) if (is.null(a)) b else a

run_cli_import <- function(traning_data, verbose = FALSE) {
  cli <- file.path(testthat::test_path("..", ".."), "inst", "cli.R")
  args <- c(cli, "--import")
  if (verbose) args <- c(args, "-v")
  out <- suppressWarnings(withr::with_envvar(
    c(TRANING_DATA = traning_data),
    system2("Rscript", args = args, stdout = TRUE, stderr = TRUE)))
  paste(out, collapse = "\n")
}

# Build a TRANING_DATA tree holding one Apple Watch row that is the same
# session as the TCX fixture placed alongside it.
setup_swap_cache <- function(dir) {
  tcx_dir <- file.path(dir, "kristian", "filer", "tcx")
  cache_dir <- file.path(dir, "cache")
  dir.create(tcx_dir, recursive = TRUE)
  dir.create(cache_dir, recursive = TRUE)
  fixture <- testthat::test_path("fixtures", "sample1.tcx")
  file.copy(fixture, file.path(tcx_dir, "sample1.tcx"))

  # Take the session's real numbers from the fixture so the Apple Watch
  # row genuinely matches it under the dedup rule.
  parsed <- trackeR::read_container(fixture)
  s <- summary(parsed)
  class(s) <- "data.frame"

  summaries <- data.frame(
    sessionStart = s$sessionStart,
    sessionEnd = s$sessionEnd,
    sport = "running",
    distance = as.numeric(s$distance),
    duration = s$duration,
    file = "hae:Utomhus_Kor-fixture.json",
    source = "hae",
    stringsAsFactors = FALSE
  )
  myruns <- list(NULL)
  save(summaries, file = file.path(cache_dir, "summaries.RData"))
  save(myruns, file = file.path(cache_dir, "myruns.RData"))
  cache_dir
}

test_that("--import persists a one-for-one Garmin/Apple Watch swap", {
  tmp <- withr::local_tempdir()
  cache_dir <- setup_swap_cache(tmp)

  out <- run_cli_import(tmp)
  expect_match(out, "Apple Watch", info = out)

  after <- my_dbs_load(file.path(cache_dir, "summaries.RData"),
                       file.path(cache_dir, "myruns.RData"))

  # One row in, one row out: the count is unchanged, which is exactly
  # why the row count could not be the save trigger.
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "tcx")
  expect_equal(basename(after$summaries$file), "sample1.tcx")
})

test_that("--import leaves the cache alone when nothing changed", {
  tmp <- withr::local_tempdir()
  cache_dir <- setup_swap_cache(tmp)
  run_cli_import(tmp)

  db <- file.path(cache_dir, "summaries.RData")
  before <- file.mtime(db)
  Sys.sleep(1.1)
  run_cli_import(tmp)

  # The second pass has nothing to do, so it must not rewrite the cache
  # — the myruns half of which is ~90 MB in production.
  expect_identical(file.mtime(db), before)
})

test_that("--import does not rewrite the cache for a declined fragment", {
  # The Garmin file is a fragment of the Apple Watch session, so the
  # import declines to add it and nothing changes. It declines again on
  # every subsequent run, since nothing on disk records the decision —
  # which is why the fragment counter must stay out of the save
  # predicate. Keying the save on it would rewrite the whole cache,
  # myruns included, on every import for as long as the file exists.
  tmp <- withr::local_tempdir()
  tcx_dir <- file.path(tmp, "kristian", "filer", "tcx")
  cache_dir <- file.path(tmp, "cache")
  dir.create(tcx_dir, recursive = TRUE)
  dir.create(cache_dir, recursive = TRUE)
  fixture <- testthat::test_path("fixtures", "sample1.tcx")
  file.copy(fixture, file.path(tcx_dir, "sample1.tcx"))

  parsed <- trackeR::read_container(fixture)
  s <- summary(parsed)
  class(s) <- "data.frame"

  summaries <- data.frame(
    sessionStart = s$sessionStart,
    sessionEnd = s$sessionEnd,
    sport = "running",
    # Five times the Garmin distance: the TCX is a fragment and loses.
    distance = as.numeric(s$distance) * 5,
    duration = s$duration,
    file = "hae:Utomhus_Kor-fragment.json",
    source = "hae",
    stringsAsFactors = FALSE
  )
  myruns <- list(NULL)
  db <- file.path(cache_dir, "summaries.RData")
  save(summaries, file = db)
  save(myruns, file = file.path(cache_dir, "myruns.RData"))

  # -v so the decision shows up in the log: the file is read on every
  # import, and saying so is the point of the wording.
  out <- run_cli_import(tmp, verbose = TRUE)
  expect_match(out, "fragment", info = out)

  before <- file.mtime(db)
  Sys.sleep(1.1)
  run_cli_import(tmp)
  expect_identical(file.mtime(db), before)

  after <- my_dbs_load(db, file.path(cache_dir, "myruns.RData"))
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "hae")
})
