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
  # An empty Garmin JSON directory is enough for the augmentation block
  # to run and stamp garmin_matched, which is what the swap has to
  # trigger.
  dir.create(file.path(dir, "kristian", "filer", "gconnect"),
             recursive = TRUE)
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

test_that("--import augments the row a swap brought in", {
  # The re-augment block is gated on the same quantities as the save, so
  # a one-for-one swap used to skip it and the new row was written with
  # garmin_* = NA until some later run backfilled it. A combined
  # invocation such as `--import --pmc` then read the stale values.
  tmp <- withr::local_tempdir()
  cache_dir <- setup_swap_cache(tmp)

  run_cli_import(tmp)

  after <- my_dbs_load(file.path(cache_dir, "summaries.RData"),
                       file.path(cache_dir, "myruns.RData"))
  expect_true("garmin_matched" %in% names(after$summaries))
  expect_false(is.na(after$summaries$garmin_matched[1]))
})

test_that("--import reports the session a swap brought in", {
  # The report is gated on the row count too, so a swap imported a
  # session and said nothing about it.
  tmp <- withr::local_tempdir()
  setup_swap_cache(tmp)
  out <- run_cli_import(tmp)
  # report_mostrecent()'s wording: "Import: 1 pass (...), N km totalt."
  expect_match(out, "Import: 1 pass", info = out)
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

# --- --dedup flag precedence -------------------------------------------------

run_cli_dedup <- function(traning_data, extra = character(0)) {
  cli <- file.path(testthat::test_path("..", ".."), "inst", "cli.R")
  out <- suppressWarnings(withr::with_envvar(
    c(TRANING_DATA = traning_data),
    system2("Rscript", args = c(cli, "--dedup", extra),
            stdout = TRUE, stderr = TRUE)))
  paste(out, collapse = "\n")
}

# A cache holding one Apple Watch row and the Garmin row for the same
# session, i.e. exactly one thing for --dedup to remove.
setup_dedup_cache <- function(dir) {
  cache_dir <- file.path(dir, "cache")
  dir.create(cache_dir, recursive = TRUE)
  start <- as.POSIXct("2026-08-01 11:00:49", tz = "UTC")
  summaries <- data.frame(
    sessionStart = c(start, start + 107),
    sessionEnd = c(start + 1391, start + 1483),
    sport = "running",
    distance = c(5234, 5292),
    duration = as.difftime(c(1391, 1376), units = "secs"),
    file = c("hae:Utomhus_Kor-20260801.json", "/data/tcx/20260801.tcx"),
    source = c("hae", "tcx"),
    stringsAsFactors = FALSE
  )
  myruns <- list(NULL, "garmin-run")
  save(summaries, file = file.path(cache_dir, "summaries.RData"))
  save(myruns, file = file.path(cache_dir, "myruns.RData"))
  cache_dir
}

test_that("--dedup reports without writing unless --apply is given", {
  tmp <- withr::local_tempdir()
  cache_dir <- setup_dedup_cache(tmp)
  db <- file.path(cache_dir, "summaries.RData")
  before <- file.mtime(db)
  Sys.sleep(1.1)

  out <- run_cli_dedup(tmp)
  expect_match(out, "Torrk", info = out)
  expect_identical(file.mtime(db), before)

  out <- run_cli_dedup(tmp, "--apply")
  after <- my_dbs_load(db, file.path(cache_dir, "myruns.RData"))
  expect_equal(nrow(after$summaries), 1)
  expect_equal(after$summaries$source, "tcx")
})

test_that("--dry-run wins over --apply", {
  # Two flags that contradict each other resolve to the harmless one, the
  # same way the Python layer resolves them. A command with no undo must
  # not be talked into writing by an ambiguous invocation.
  tmp <- withr::local_tempdir()
  cache_dir <- setup_dedup_cache(tmp)
  db <- file.path(cache_dir, "summaries.RData")
  before <- file.mtime(db)
  Sys.sleep(1.1)

  out <- run_cli_dedup(tmp, c("--apply", "--dry-run"))

  expect_match(out, "Torrk", info = out)
  expect_identical(file.mtime(db), before)
  after <- my_dbs_load(db, file.path(cache_dir, "myruns.RData"))
  expect_equal(nrow(after$summaries), 2)
})

# --- what the closing report counts ------------------------------------------

write_hae_json <- function(dir, name, start, distance_km, duration_s) {
  payload <- list(data = list(workouts = list(list(
    id = name, name = "Utomhus Kör",
    start = format(start, "%Y-%m-%d %H:%M:%S +0000", tz = "UTC"),
    end = format(start + duration_s, "%Y-%m-%d %H:%M:%S +0000", tz = "UTC"),
    duration = duration_s,
    distance = list(qty = distance_km, units = "km"),
    avgHeartRate = list(qty = 140, units = "count/min")
  ))))
  jsonlite::write_json(payload, file.path(dir, paste0(name, ".json")),
                       auto_unbox = TRUE, null = "null")
}

# An empty cache plus whichever sources the caller asks for.
setup_sources <- function(dir, tcx = FALSE, hae = FALSE) {
  cache_dir <- file.path(dir, "cache")
  dir.create(cache_dir, recursive = TRUE)
  dir.create(file.path(dir, "kristian", "filer", "tcx"), recursive = TRUE)
  if (tcx) {
    file.copy(testthat::test_path("fixtures", "sample1.tcx"),
              file.path(dir, "kristian", "filer", "tcx", "sample1.tcx"))
  }
  hae_dir <- file.path(dir, "kristian", "health_export", "workouts")
  dir.create(hae_dir, recursive = TRUE)
  if (hae) {
    write_hae_json(hae_dir, "aw_session",
                   as.POSIXct("2026-07-04 08:00:00", tz = "UTC"),
                   distance_km = 7.5, duration_s = 2400)
  }
  summaries <- data.frame()
  myruns <- list()
  save(summaries, file = file.path(cache_dir, "summaries.RData"))
  save(myruns, file = file.path(cache_dir, "myruns.RData"))
  cache_dir
}

test_that("--import reports an Apple-Watch-only import", {
  # The report used to count Garmin rows only, so an import that brought
  # in nothing but HAE workouts saved the cache and then said nothing.
  tmp <- withr::local_tempdir()
  setup_sources(tmp, tcx = FALSE, hae = TRUE)

  out <- run_cli_import(tmp)

  expect_match(out, "Import: 1 pass", info = out)
})

test_that("--import reports every session of a mixed import", {
  # Both importers append, the HAE rows landing after the Garmin ones, so
  # counting Garmin rows and taking that many from the end named the
  # wrong sessions. The count and the total distance together pin which
  # rows were selected.
  tmp <- withr::local_tempdir()
  cache_dir <- setup_sources(tmp, tcx = TRUE, hae = TRUE)

  out <- run_cli_import(tmp)

  expect_match(out, "Import: 2 pass", info = out)

  after <- my_dbs_load(file.path(cache_dir, "summaries.RData"),
                       file.path(cache_dir, "myruns.RData"))
  expect_equal(nrow(after$summaries), 2)
  expect_setequal(after$summaries$source, c("tcx", "hae"))

  # The reported total is both sessions, not one of them twice.
  total_km <- fmt_dec_sv(sum(after$summaries$distance, na.rm = TRUE) / 1000,
                         trim_zero = TRUE)
  expect_match(out, paste0(total_km, " km totalt"), fixed = TRUE, info = out)
})
