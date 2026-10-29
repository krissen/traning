# Tests for the cache-protecting testthat runner (#91). The runner lives
# outside the package (scripts/run_testthat.R) because it wraps
# devtools::test() itself, so the helpers are sourced directly.
source(file.path(
  testthat::test_path("..", ".."),
  "scripts",
  "run_testthat.R"
))

test_that("with_protected_cache is a no-op when TRANING_DATA is unset", {
  withr::local_envvar(TRANING_DATA = NA)
  expect_identical(with_protected_cache("ran"), "ran")
})

test_that("with_protected_cache is a no-op when TRANING_DATA is empty", {
  withr::local_envvar(TRANING_DATA = "")
  expect_identical(with_protected_cache("ran"), "ran")
})

test_that("with_protected_cache is a no-op when there is no cache dir", {
  td <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = td)

  expect_identical(with_protected_cache({
    dir.create(file.path(td, "cache"))
    "ran"
  }), "ran")
  # The expression's own filesystem changes are not rolled back.
  expect_true(dir.exists(file.path(td, "cache")))
})

test_that("with_protected_cache restores the cache after a run", {
  td <- withr::local_tempdir()
  cache <- file.path(td, "cache")
  dir.create(cache)
  writeLines("old", file.path(cache, "a.RData"))
  dir.create(file.path(cache, "nested"))
  writeLines("keep", file.path(cache, "nested", "b.RData"))
  withr::local_envvar(TRANING_DATA = td)

  result <- with_protected_cache({
    writeLines("new", file.path(cache, "a.RData"))
    writeLines("added", file.path(cache, "c.RData"))
    unlink(file.path(cache, "nested"), recursive = TRUE)
    dir.create(file.path(cache, "tmpdir"))
    writeLines("x", file.path(cache, "tmpdir", "d.RData"))
    "done"
  })

  expect_identical(result, "done")
  expect_identical(readLines(file.path(cache, "a.RData")), "old")
  expect_false(file.exists(file.path(cache, "c.RData")))
  expect_identical(readLines(file.path(cache, "nested", "b.RData")), "keep")
  expect_false(dir.exists(file.path(cache, "tmpdir")))
})

test_that("with_protected_cache restores the cache after an error", {
  td <- withr::local_tempdir()
  cache <- file.path(td, "cache")
  dir.create(cache)
  writeLines("old", file.path(cache, "a.RData"))
  withr::local_envvar(TRANING_DATA = td)

  expect_error(
    with_protected_cache({
      writeLines("new", file.path(cache, "a.RData"))
      stop("boom")
    }),
    "boom"
  )
  expect_identical(readLines(file.path(cache, "a.RData")), "old")
})

test_that("with_protected_cache keeps a cache that was deleted by a test", {
  td <- withr::local_tempdir()
  cache <- file.path(td, "cache")
  dir.create(cache)
  writeLines("old", file.path(cache, "a.RData"))
  withr::local_envvar(TRANING_DATA = td)

  with_protected_cache(unlink(cache, recursive = TRUE))

  expect_identical(readLines(file.path(cache, "a.RData")), "old")
})
