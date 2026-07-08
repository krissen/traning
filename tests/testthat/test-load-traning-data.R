# Tests for load_traning_data() — the S7 bundle constructor that
# load_session_data() (tRanat Shiny loader) delegates to. See
# R/shiny_helpers.R and R/traning_data.R.

test_that("load_traning_data returns a valid traning_data bundle", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    bundle <- load_traning_data()
  })

  expect_true(S7::S7_inherits(bundle, traning_data))
  expect_s3_class(bundle@summaries, "data.frame")
  expect_equal(nrow(bundle@summaries), 2)
  expect_type(bundle@myruns, "list")
  expect_equal(bundle@sport, "running")
})

test_that("load_traning_data defaults (slots = NULL) load both optional slots", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    bundle <- load_traning_data()
  })

  # Fixture has no health_daily.RData/decoupling.RData on disk, so both
  # loaders hit their cold-path — health returns an empty-but-typed
  # tibble (never NULL), decoupling may fall back to NULL on cold-path
  # failure. The point here is that *loading was attempted*, i.e. the
  # slots are not skipped outright as they are with slots = character(0).
  expect_true(inherits(bundle@health_daily, "data.frame"))
  expect_true(is.null(bundle@decoupling_data) ||
              inherits(bundle@decoupling_data, "data.frame"))
})

test_that("load_traning_data(slots = character(0)) skips optional slots", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    bundle <- load_traning_data(slots = character(0))
  })

  expect_null(bundle@health_daily)
  expect_null(bundle@decoupling_data)
  expect_true(nrow(bundle@summaries) > 0)
})

test_that("load_traning_data(slots = 'health_daily') loads only that slot", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    bundle <- load_traning_data(slots = "health_daily")
  })

  expect_true(inherits(bundle@health_daily, "data.frame"))
  expect_null(bundle@decoupling_data)
})

test_that("load_traning_data rejects unknown slot names", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    expect_error(load_traning_data(slots = "not_a_slot"), "unknown slot")
  })
})

test_that("load_session_data delegates to load_traning_data and returns the bundle", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    bundle <- load_traning_data(td)
    via_session <- load_session_data()
  })

  expect_true(S7::S7_inherits(via_session, traning_data))
  expect_equal(via_session@summaries, bundle@summaries)
  expect_equal(via_session@myruns, bundle@myruns)
  expect_equal(via_session@decoupling_data, bundle@decoupling_data)
  expect_equal(via_session@health_daily, bundle@health_daily)
})
