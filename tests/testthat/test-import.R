# Tests for R/import.R: get_new_workouts(), repair_myruns(),
# repair_myruns_hr(), and the .onLoad trackeR unit-conversion workaround.

# --- helpers -----------------------------------------------------------------

fixture_path <- function(name) {
  testthat::test_path("fixtures", name)
}

# Minimal fake trackeRdata-like object + summary method, used to drive
# get_new_workouts() with full control over sessionStart without needing
# real TCX parsing for every scenario (real-file parsing is covered
# separately below).
make_fake_summary <- function(session_start, distance = 1000,
                              avg_hr_moving = 140, file = NA_character_) {
  tibble::tibble(
    session = 1L,
    sessionStart = session_start,
    sessionEnd = session_start + 600,
    distance = distance,
    duration = as.difftime(10, units = "mins"),
    durationMoving = as.difftime(10, units = "mins"),
    avgSpeed = 2.5,
    avgSpeedMoving = 2.8,
    avgPace = 6.5,
    avgPaceMoving = 5.9,
    avgCadenceRunning = 85,
    avgCadenceRunningMoving = 87,
    avgHeartRate = avg_hr_moving - 5,
    avgHeartRateMoving = avg_hr_moving,
    sport = "running",
    file = file
  )
}

summary.faketrack <- function(object, ...) {
  object$the_summary
}
# get_new_workouts() calls trackeR::summary() on the object returned by the
# (mocked) trackeR::read_container() from inside the package's own
# namespace; S3 dispatch for a method defined in a test file only resolves
# there if explicitly registered.
registerS3method("summary", "faketrack", summary.faketrack, envir = environment())

make_fake_parsed <- function(session_start, tag = NA_character_, ...) {
  structure(
    list(the_summary = make_fake_summary(session_start, file = tag, ...),
        tag = tag),
    class = "faketrack"
  )
}

# --- get_new_workouts(): myruns/summaries alignment (real TCX parse) --------

test_that("get_new_workouts keeps myruns[[k]] aligned with summaries row k", {
  files <- c(fixture_path("sample1.tcx"), fixture_path("sample2.tcx"))
  summaries <- data.frame()
  myruns <- list()

  res <- get_new_workouts(files, summaries, myruns, verbose = FALSE)

  expect_equal(nrow(res$summaries), 2)
  expect_length(res$myruns, 2)

  # Each myruns[[k]] must correspond to the file recorded in
  # summaries$file[k] — not to the k-th element of `files`. Re-derive
  # sessionStart from the actual parsed trackeRdata object and confirm
  # it matches the summaries row it's paired with.
  for (k in seq_len(nrow(res$summaries))) {
    expect_false(is.null(res$myruns[[k]]))
    parsed_summary <- summary(res$myruns[[k]])
    class(parsed_summary) <- "data.frame"
    expect_equal(parsed_summary$sessionStart, res$summaries$sessionStart[k])
  }
  expect_setequal(basename(res$summaries$file), basename(files))
})

test_that("get_new_workouts myruns index survives multiple skipped files mid-batch", {
  # Regression for the aliasing bug: when files earlier in `files` are
  # skipped (basename dup), the myruns index must track nrow(summaries),
  # not the loop index over `files`. Two skips ahead of the new file
  # means loop index (3) and nrow(summaries) (2) genuinely diverge —
  # indexing by loop position would silently misalign or clobber.
  f1 <- fixture_path("sample1.tcx")
  f2 <- fixture_path("sample2.tcx")

  # Pre-seed summaries/myruns as if f1 and f2 were already imported.
  seeded <- get_new_workouts(c(f1, f2), data.frame(), list(), verbose = FALSE)
  summaries <- seeded$summaries
  myruns <- seeded$myruns
  expect_length(myruns, 2)

  f3 <- file.path(tempdir(), "mid_batch_new.tcx")
  base_time <- as.POSIXct("2024-04-01 06:00:00", tz = "UTC")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) make_fake_parsed(base_time, tag = file),
    .package = "trackeR"
  )

  # files[1]=f1 (dup, skip), files[2]=f2 (dup, skip), files[3]=f3 (new).
  # Loop index for f3 is 3; nrow(summaries) after appending it is 3 too
  # in THIS batch only because 2 rows pre-existed — the real test is
  # that myruns[[3]] is the f3 parse, not left NULL/wrong from a
  # loop-index vs. row-count mismatch within the loop itself.
  second <- get_new_workouts(c(f1, f2, f3), summaries, myruns,
                             verbose = FALSE)

  expect_equal(nrow(second$summaries), 3)
  expect_length(second$myruns, 3)
  expect_equal(basename(second$summaries$file[3]), basename(f3))
  parsed_summary <- summary(second$myruns[[3]])
  expect_equal(parsed_summary$sessionStart, base_time)
})

test_that("get_new_workouts does not misalign myruns when a parse failure precedes a new file", {
  # A parse failure calls `next` without touching summaries or myruns,
  # so the loop index (2) and nrow(summaries) (1) diverge after it.
  # Indexing myruns by loop position would place the valid file's
  # parsed data at myruns[[2]] instead of myruns[[1]].
  corrupt <- file.path(tempdir(), "corrupt_align.tcx")
  good <- file.path(tempdir(), "good_align.tcx")
  base_time <- as.POSIXct("2024-04-05 06:00:00", tz = "UTC")

  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      if (grepl("corrupt", file)) stop("bad xml")
      make_fake_parsed(base_time, tag = file)
    },
    .package = "trackeR"
  )

  expect_warning(
    res <- get_new_workouts(c(corrupt, good), data.frame(), list(),
                            verbose = FALSE),
    "Kunde inte läsa"
  )

  expect_equal(nrow(res$summaries), 1)
  expect_length(res$myruns, 1)
  expect_false(is.null(res$myruns[[1]]))
  expect_equal(summary(res$myruns[[1]])$sessionStart, base_time)
})

# --- get_new_workouts(): duplicate-by-basename ------------------------------

test_that("get_new_workouts skips a file whose basename already exists", {
  existing <- data.frame(
    file = fixture_path("sample1.tcx"),
    sessionStart = as.POSIXct("2023-01-15 07:00:00", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  n_calls <- 0
  testthat::local_mocked_bindings(
    read_container = function(...) {
      n_calls <<- n_calls + 1
      NULL
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(c(fixture_path("sample1.tcx")), existing, list(),
                          verbose = FALSE)

  expect_equal(n_calls, 0) # never even attempted to parse
  expect_equal(nrow(res$summaries), 1) # unchanged
})

# --- get_new_workouts(): within-2s sessionStart dedup -----------------------

test_that("get_new_workouts skips a file within 2s of an existing sessionStart, old file missing", {
  base_time <- as.POSIXct("2024-03-01 06:00:00", tz = "UTC")
  old_file <- file.path(tempdir(), "old_missing_file.tcx") # does not exist
  existing <- make_fake_summary(base_time)
  existing$file <- old_file

  new_file <- file.path(tempdir(), "renamed_file.tcx")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      # 1.5s later — within the 2s dedup window
      make_fake_parsed(base_time + 1.5, tag = file)
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(c(new_file), existing, list(), verbose = FALSE)

  expect_equal(nrow(res$summaries), 1) # not appended, filename swapped instead
  expect_equal(res$summaries$file[1], new_file)
  expect_equal(res$n_updated, 1)
  expect_length(res$myruns, 0) # nothing added to myruns
})

test_that("get_new_workouts skips a file within 2s of an existing sessionStart, old file present", {
  base_time <- as.POSIXct("2024-03-01 06:00:00", tz = "UTC")
  old_file <- fixture_path("sample1.tcx") # exists on disk
  existing <- make_fake_summary(base_time)
  existing$file <- old_file

  new_file <- file.path(tempdir(), "another_dup.tcx")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      make_fake_parsed(base_time - 1.9, tag = file) # within 2s, other direction
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(c(new_file), existing, list(), verbose = FALSE)

  expect_equal(nrow(res$summaries), 1)
  expect_equal(res$summaries$file[1], old_file) # unchanged, old file still on disk
  expect_equal(res$n_updated, 0)
})

test_that("get_new_workouts does not dedup files >= 2s apart", {
  base_time <- as.POSIXct("2024-03-01 06:00:00", tz = "UTC")
  old_file <- file.path(tempdir(), "old_missing_file2.tcx")
  existing <- make_fake_summary(base_time)
  existing$file <- old_file

  new_file <- file.path(tempdir(), "distinct_session.tcx")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      make_fake_parsed(base_time + 2.5, tag = file) # >= 2s away
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(c(new_file), existing, list(), verbose = FALSE)

  expect_equal(nrow(res$summaries), 2) # appended as a new row
  expect_length(res$myruns, 2)
  expect_equal(res$summaries$file[2], new_file)
})

# --- get_new_workouts(): reverse cross-source dedup -------------------------

test_that("get_new_workouts evicts the Apple Watch row for the same session", {
  # The HAE push normally beats the Garmin fetch, so the duplicate has to
  # be resolved when the TCX arrives — not only the other way round.
  base_time <- as.POSIXct("2026-08-01 11:02:36", tz = "UTC")
  existing <- data.frame(
    sessionStart = base_time - 107,
    sport = "running",
    distance = 5234,
    duration = as.difftime(1391, units = "secs"),
    file = "hae:Utomhus_Kor-20260801_130049.json",
    source = "hae",
    stringsAsFactors = FALSE
  )

  new_file <- file.path(tempdir(), "20260801-110236.tcx")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      make_fake_parsed(base_time, tag = file, distance = 5292)
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(new_file, existing, list(NULL), verbose = FALSE)

  expect_equal(nrow(res$summaries), 1)
  expect_equal(res$summaries$source, "tcx")
  expect_equal(res$n_hae_removed, 1)
  expect_length(res$myruns, 1)
  expect_false(is.null(res$myruns[[1]]))
})

test_that("get_new_workouts keeps an Apple-Watch-only session", {
  # Same day, different workout: the HAE row has no Garmin twin and must
  # survive the import untouched.
  base_time <- as.POSIXct("2026-08-01 11:02:36", tz = "UTC")
  existing <- data.frame(
    sessionStart = base_time - 7200,
    sport = "walking",
    distance = 2000,
    duration = as.difftime(1800, units = "secs"),
    file = "hae:Utomhus_Gang-20260801.json",
    source = "hae",
    stringsAsFactors = FALSE
  )

  new_file <- file.path(tempdir(), "20260801-110236b.tcx")
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      make_fake_parsed(base_time, tag = file, distance = 5292)
    },
    .package = "trackeR"
  )

  res <- get_new_workouts(new_file, existing, list(NULL), verbose = FALSE)

  expect_equal(nrow(res$summaries), 2)
  expect_equal(res$n_hae_removed, 0)
  expect_setequal(res$summaries$source, c("hae", "tcx"))
})

# --- get_new_workouts(): batch checkpointing --------------------------------

test_that("get_new_workouts checkpoints every batch_size imports", {
  base_time <- as.POSIXct("2024-06-01 06:00:00", tz = "UTC")
  files <- file.path(tempdir(), paste0("batch_", 1:5, ".tcx"))

  call_log <- list()
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      idx <- which(files == file)
      make_fake_parsed(base_time + idx * 100, tag = file)
    },
    .package = "trackeR"
  )
  testthat::local_mocked_bindings(
    my_dbs_save = function(db_summaries, db_myruns, summaries, myruns) {
      call_log[[length(call_log) + 1]] <<- nrow(summaries)
    },
    .package = "traning"
  )

  res <- get_new_workouts(files, data.frame(), list(), verbose = FALSE,
                          batch_size = 2,
                          db_summaries = "dummy_summaries.RData",
                          db_myruns = "dummy_myruns.RData")

  expect_equal(nrow(res$summaries), 5)
  # 5 imports at batch_size=2 -> checkpoints after the 2nd and 4th import.
  expect_equal(unlist(call_log), c(2, 4))
})

test_that("get_new_workouts does not checkpoint when db paths are NULL", {
  base_time <- as.POSIXct("2024-06-02 06:00:00", tz = "UTC")
  files <- file.path(tempdir(), paste0("nocheckpoint_", 1:3, ".tcx"))

  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      idx <- which(files == file)
      make_fake_parsed(base_time + idx * 100, tag = file)
    },
    .package = "trackeR"
  )
  n_save_calls <- 0
  testthat::local_mocked_bindings(
    my_dbs_save = function(...) n_save_calls <<- n_save_calls + 1,
    .package = "traning"
  )

  res <- get_new_workouts(files, data.frame(), list(), verbose = FALSE,
                          batch_size = 1)

  expect_equal(n_save_calls, 0)
  expect_equal(nrow(res$summaries), 3)
})

# --- get_new_workouts(): parse failure is skipped, not fatal ---------------

test_that("get_new_workouts warns and continues past a file that fails to parse", {
  files <- c(file.path(tempdir(), "corrupt.tcx"),
            fixture_path("sample1.tcx"))
  # Real parsing for the valid file, forced failure for the "corrupt" one.
  real_read_container <- getNamespace("trackeR")$read_container
  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      if (grepl("corrupt", file)) stop("bad xml")
      real_read_container(file, ...)
    },
    .package = "trackeR"
  )

  expect_warning(
    res <- get_new_workouts(files, data.frame(), list(), verbose = FALSE),
    "Kunde inte läsa"
  )

  expect_equal(nrow(res$summaries), 1) # only the valid file imported
  expect_equal(basename(res$summaries$file[1]), "sample1.tcx")
})

# --- repair_myruns() ---------------------------------------------------------

test_that("repair_myruns fills only NULL myruns gaps, re-parsing the matching file", {
  files <- c(fixture_path("sample1.tcx"), fixture_path("sample2.tcx"))
  summaries <- data.frame(
    file = basename(files),
    source = c("tcx", "tcx"),
    stringsAsFactors = FALSE
  )
  myruns <- list("already_present", NULL)

  testthat::local_mocked_bindings(
    read_container = function(file, ...) {
      structure(list(marker = "repaired", path = file), class = "faketrack2")
    },
    .package = "trackeR"
  )

  res <- repair_myruns(files, summaries, myruns, verbose = FALSE)

  expect_equal(res$myruns[[1]], "already_present") # untouched
  expect_false(is.null(res$myruns[[2]]))
  expect_equal(res$myruns[[2]]$marker, "repaired")
  expect_true(grepl("sample2.tcx", res$myruns[[2]]$path))
})

test_that("repair_myruns skips hae rows silently and leaves them NULL", {
  summaries <- data.frame(
    file = NA_character_,
    source = "hae",
    stringsAsFactors = FALSE
  )
  myruns <- list(NULL)

  n_calls <- 0
  testthat::local_mocked_bindings(
    read_container = function(...) {
      n_calls <<- n_calls + 1
      NULL
    },
    .package = "trackeR"
  )

  res <- repair_myruns(character(0), summaries, myruns, verbose = FALSE)

  expect_equal(n_calls, 0)
  expect_null(res$myruns[[1]])
})

test_that("repair_myruns reports 'inga saknade poster' when nothing is NULL", {
  summaries <- data.frame(file = "a.tcx", source = "tcx",
                          stringsAsFactors = FALSE)
  myruns <- list("present")

  expect_message(
    res <- repair_myruns(character(0), summaries, myruns, verbose = FALSE),
    "inga saknade poster"
  )
  expect_equal(res$myruns, myruns)
})

# --- repair_myruns_hr() -------------------------------------------------------

test_that("repair_myruns_hr re-parses sessions with summary HR but no per-second HR", {
  files <- c(fixture_path("sample1.tcx"))
  summaries <- data.frame(
    file = basename(files),
    source = "tcx",
    avgHeartRateMoving = 140,
    stringsAsFactors = FALSE
  )
  # myruns[[1]] has no usable HR (all zero) -> should be flagged for repair.
  myruns <- list(data.frame(heart_rate = c(0, 0, NA)))

  new_data <- data.frame(heart_rate = c(120, 130, 140))
  testthat::local_mocked_bindings(
    read_container = function(file, ...) new_data,
    .package = "trackeR"
  )

  res <- repair_myruns_hr(files, summaries, myruns, verbose = FALSE)

  expect_identical(res$myruns[[1]], new_data)
})

test_that("repair_myruns_hr leaves sessions with usable HR untouched", {
  files <- c(fixture_path("sample1.tcx"))
  summaries <- data.frame(
    file = basename(files),
    source = "tcx",
    avgHeartRateMoving = 140,
    stringsAsFactors = FALSE
  )
  myruns <- list(data.frame(heart_rate = c(120, 130, 140)))

  n_calls <- 0
  testthat::local_mocked_bindings(
    read_container = function(...) {
      n_calls <<- n_calls + 1
      NULL
    },
    .package = "trackeR"
  )

  res <- repair_myruns_hr(files, summaries, myruns, verbose = FALSE)

  expect_equal(n_calls, 0)
  expect_identical(res$myruns[[1]], myruns[[1]])
})

test_that("repair_myruns_hr does not re-parse a session with no summary HR", {
  files <- c(fixture_path("sample1.tcx"))
  summaries <- data.frame(
    file = basename(files),
    source = "tcx",
    avgHeartRateMoving = NA_real_,
    stringsAsFactors = FALSE
  )
  myruns <- list(data.frame(heart_rate = c(0, 0, 0)))

  n_calls <- 0
  testthat::local_mocked_bindings(
    read_container = function(...) {
      n_calls <<- n_calls + 1
      NULL
    },
    .package = "trackeR"
  )

  res <- repair_myruns_hr(files, summaries, myruns, verbose = FALSE)
  expect_equal(n_calls, 0)
})

# --- .onLoad trackeR unit-conversion workaround ------------------------------

test_that(".onLoad copies trackeR's unit-conversion helpers into the package namespace", {
  # trackeR::change_units() looks up conversion functions like km2mi()
  # via get() in the calling environment, but they are not exported from
  # trackeR. .onLoad copies every function matching pattern '2' from the
  # trackeR namespace into this package's namespace so get() can find
  # them at call time. This test guards against a silent breakage if a
  # future trackeR release renames/removes these helpers.
  pkg_ns <- asNamespace("traning")
  trackeR_ns <- asNamespace("trackeR")

  source_fns <- ls(trackeR_ns, pattern = "2")
  source_fns <- source_fns[vapply(source_fns, function(f) {
    is.function(get(f, envir = trackeR_ns))
  }, logical(1))]

  expect_gt(length(source_fns), 0)

  # Spot-check a handful of well-known conversion helpers actually used
  # elsewhere in the running-pace pipeline.
  for (fn in c("km2mi", "m2km", "min2s", "s2min")) {
    expect_true(fn %in% source_fns, info = fn)
    expect_true(exists(fn, envir = pkg_ns, inherits = FALSE), info = fn)
    expect_true(is.function(get(fn, envir = pkg_ns)), info = fn)
  }

  # Copied functions are callable and behave like the trackeR originals.
  expect_equal(get("km2mi", envir = pkg_ns)(1),
              get("km2mi", envir = trackeR_ns)(1))
})
