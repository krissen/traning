# Tests for the isolated test-data runner (#91). The runner lives
# outside the package (scripts/run_testthat.R) because it wraps
# devtools::test() itself, so the helpers are sourced directly.
runner <- file.path(
  testthat::test_path("..", ".."),
  "scripts",
  "run_testthat.R"
)
runner_available <- file.exists(runner)
if (runner_available) source(runner)

skip_without_runner <- function() {
  testthat::skip_if_not(
    runner_available,
    "scripts/run_testthat.R is only present in a source checkout"
  )
}

test_that("with_isolated_data is a no-op when TRANING_DATA is unset", {
  skip_without_runner()
  withr::local_envvar(TRANING_DATA = NA)
  expect_identical(with_isolated_data("ran"), "ran")
  expect_identical(Sys.getenv("TRANING_DATA", unset = NA), NA_character_)
})

test_that("with_isolated_data is a no-op when TRANING_DATA is empty", {
  skip_without_runner()
  withr::local_envvar(TRANING_DATA = "")
  expect_identical(with_isolated_data("ran"), "ran")
  expect_identical(Sys.getenv("TRANING_DATA"), "")
})

test_that("with_isolated_data is a no-op when the data dir does not exist", {
  skip_without_runner()
  withr::local_envvar(TRANING_DATA = file.path(tempdir(), "does-not-exist"))
  expect_identical(with_isolated_data("ran"), "ran")
})

test_that("with_isolated_data points TRANING_DATA at a populated copy", {
  skip_without_runner()
  live <- withr::local_tempdir()
  dir.create(file.path(live, "cache"))
  writeLines("old", file.path(live, "cache", "a.RData"))
  dir.create(file.path(live, "cache", "nested"))
  writeLines("keep", file.path(live, "cache", "nested", "b.RData"))
  dir.create(file.path(live, "other"))
  writeLines("source", file.path(live, "other", "file.txt"))
  withr::local_envvar(TRANING_DATA = live)

  seen <- new.env()
  result <- with_isolated_data({
    seen$sandbox <- Sys.getenv("TRANING_DATA")
    sandbox <- seen$sandbox
    testthat::expect_false(identical(normalizePath(sandbox), normalizePath(live)))
    testthat::expect_identical(readLines(file.path(sandbox, "cache", "a.RData")), "old")
    testthat::expect_identical(
      readLines(file.path(sandbox, "cache", "nested", "b.RData")),
      "keep"
    )
    testthat::expect_true(file.exists(file.path(sandbox, "other", "file.txt")))
    writeLines("new", file.path(sandbox, "cache", "a.RData"))
    writeLines("added", file.path(sandbox, "cache", "c.RData"))
    "wrote"
  })

  expect_identical(result, "wrote")
  expect_identical(Sys.getenv("TRANING_DATA"), live)
  expect_identical(readLines(file.path(live, "cache", "a.RData")), "old")
  expect_false(file.exists(file.path(live, "cache", "c.RData")))
  expect_true(file.exists(file.path(live, "other", "file.txt")))
  expect_false(dir.exists(seen$sandbox))
})

test_that("with_isolated_data restores the env and removes the sandbox on error", {
  skip_without_runner()
  live <- withr::local_tempdir()
  dir.create(file.path(live, "cache"))
  writeLines("old", file.path(live, "cache", "a.RData"))
  withr::local_envvar(TRANING_DATA = live)

  seen <- new.env()
  expect_error(
    with_isolated_data({
      seen$sandbox <- Sys.getenv("TRANING_DATA")
      writeLines("new", file.path(seen$sandbox, "cache", "a.RData"))
      stop("boom")
    }),
    "boom"
  )

  expect_identical(Sys.getenv("TRANING_DATA"), live)
  expect_identical(readLines(file.path(live, "cache", "a.RData")), "old")
  expect_false(dir.exists(seen$sandbox))
})

test_that("with_isolated_data keeps a cache deleted inside the run", {
  skip_without_runner()
  live <- withr::local_tempdir()
  dir.create(file.path(live, "cache"))
  writeLines("old", file.path(live, "cache", "a.RData"))
  withr::local_envvar(TRANING_DATA = live)

  with_isolated_data(unlink(file.path(Sys.getenv("TRANING_DATA"), "cache"), recursive = TRUE))

  expect_identical(readLines(file.path(live, "cache", "a.RData")), "old")
})

test_that("with_isolated_data handles a live data dir with no cache", {
  skip_without_runner()
  live <- withr::local_tempdir()
  dir.create(file.path(live, "other"))
  withr::local_envvar(TRANING_DATA = live)

  seen <- new.env()
  expect_identical(with_isolated_data({
    seen$sandbox <- Sys.getenv("TRANING_DATA")
    testthat::expect_false(dir.exists(file.path(seen$sandbox, "cache")))
    "ran"
  }), "ran")
  expect_false(dir.exists(seen$sandbox))
})
