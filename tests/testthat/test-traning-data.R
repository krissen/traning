minimal_summaries <- function(n = 1) {
  tibble::tibble(
    sessionStart = as.POSIXct("2024-01-01 08:00:00", tz = "UTC") + (seq_len(n) - 1) * 86400
  )
}

test_that("constructor builds a valid bundle from a minimal summaries tibble", {
  summ <- minimal_summaries()
  td <- traning_data(summaries = summ)

  expect_true(S7::S7_inherits(td, traning_data))
  expect_identical(td@summaries, summ)
})

test_that("optional slots default correctly", {
  td <- traning_data(summaries = minimal_summaries())

  expect_equal(td@myruns, list())
  expect_null(td@health_daily)
  expect_null(td@decoupling_data)
  expect_null(td@zone_data)
  expect_equal(td@sport, "running")
  expect_false(td@augmented)
})

test_that("all slots are accessible and settable via constructor args", {
  summ <- minimal_summaries(2)
  runs <- list(1, 2)
  health <- tibble::tibble(date = as.Date("2024-01-01"), hrv = 55)
  decoupling <- tibble::tibble(sessionId = 1, decoupling_pct = 3.2)
  zones <- list(z1 = 0.5, z2 = 0.3, z3 = 0.2)

  td <- traning_data(
    summaries = summ,
    myruns = runs,
    health_daily = health,
    decoupling_data = decoupling,
    zone_data = zones,
    sport = "cycling",
    augmented = TRUE
  )

  expect_identical(td@myruns, runs)
  expect_identical(td@health_daily, health)
  expect_identical(td@decoupling_data, decoupling)
  expect_identical(td@zone_data, zones)
  expect_equal(td@sport, "cycling")
  expect_true(td@augmented)
})

test_that("validator rejects summaries missing sessionStart", {
  expect_error(
    traning_data(summaries = data.frame(x = 1)),
    "sessionStart"
  )
})

test_that("non-list myruns is rejected (S7 property type)", {
  expect_error(
    traning_data(summaries = minimal_summaries(), myruns = "not a list"),
    "myruns"
  )
})

test_that("validator rejects non-NULL zone_data with empty sport", {
  expect_error(
    traning_data(
      summaries = minimal_summaries(),
      zone_data = list(z1 = 1),
      sport = ""
    ),
    "sport"
  )
})

test_that("validator rejects non-NULL decoupling_data with empty sport", {
  expect_error(
    traning_data(
      summaries = minimal_summaries(),
      decoupling_data = tibble::tibble(x = 1),
      sport = ""
    ),
    "sport"
  )
})

test_that("validator rejects empty sport even with no derived caches", {
  # @sport is always meaningful and drives the one-line print contract, so an
  # empty string is invalid regardless of whether a sport-keyed cache is set.
  expect_error(
    traning_data(summaries = minimal_summaries(), sport = ""),
    "sport"
  )
})

test_that("validator rejects a multi-element sport", {
  # A length != 1 @sport would break the compact format()/print() one-liner.
  expect_error(
    traning_data(summaries = minimal_summaries(), sport = c("running", "cycling")),
    "sport"
  )
})

test_that(".as_traning_data() returns a bundle unchanged when given one", {
  td <- traning_data(summaries = minimal_summaries())
  result <- .as_traning_data(td)
  expect_identical(result, td)
})

test_that(".as_traning_data() wraps a bare data.frame into a bundle", {
  summ <- minimal_summaries()
  result <- .as_traning_data(summ)

  expect_true(S7::S7_inherits(result, traning_data))
  expect_identical(result@summaries, summ)
  expect_equal(result@myruns, list())
})

test_that(".as_traning_data() folds a positional myruns via ...", {
  summ <- minimal_summaries()
  runs <- list("run1", "run2")
  result <- .as_traning_data(summ, myruns = runs)

  expect_identical(result@myruns, runs)
})

test_that(".as_traning_data() folds multiple legacy data args via ...", {
  summ <- minimal_summaries()
  runs <- list("run1")
  zones <- list(z1 = 1)
  result <- .as_traning_data(summ, myruns = runs, zone_data = zones, sport = "cycling")

  expect_identical(result@myruns, runs)
  expect_identical(result@zone_data, zones)
  expect_equal(result@sport, "cycling")
})

test_that(".as_traning_data() errors on non-data.frame, non-bundle input", {
  expect_error(
    .as_traning_data(list(a = 1)),
    "traning_data"
  )
})

test_that(".as_traning_data() errors on unrecognised extra args", {
  expect_error(
    .as_traning_data(minimal_summaries(), bogus_arg = 1),
    "unrecognised"
  )
})

test_that("format.traning_data produces a compact one-line summary", {
  td <- traning_data(summaries = minimal_summaries(3))
  txt <- format(td)

  expect_type(txt, "character")
  expect_length(txt, 1)
  expect_match(txt, "traning_data")
  expect_match(txt, "3 sessions")
  expect_match(txt, "sport=running")
})

test_that("print.traning_data runs without error and prints the summary", {
  td <- traning_data(summaries = minimal_summaries())
  expect_output(print(td), "traning_data")
})
