# Tests for the load-time summaries type invariant (#81): my_dbs_load()
# is the single path every consumer goes through, so it must hand out
# character identifiers and numeric measures regardless of how the cache
# was written.

write_cache <- function(summaries) {
  path <- tempfile(fileext = ".RData")
  save(summaries, file = path)
  path
}

load_cache <- function(summaries) {
  my_dbs_load(
    write_cache(summaries),
    tempfile(fileext = ".RData"),
    load_myruns = FALSE
  )$summaries
}

test_that("my_dbs_load normalises factor identifiers and character measures", {
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-07-21 06:00:00", tz = "UTC"),
    sport = factor("running", levels = c("running", "cycling")),
    file = factor("run.tcx"),
    source = factor("tcx"),
    distance = "10274",
    avgHeartRateMoving = "148",
    durationMoving = as.difftime(60, units = "mins"),
    garmin_matched = TRUE,
    stringsAsFactors = FALSE
  )

  out <- load_cache(summaries)

  expect_type(out$sport, "character")
  expect_identical(out$sport, "running")
  expect_type(out$file, "character")
  expect_identical(out$file, "run.tcx")
  expect_type(out$source, "character")
  expect_type(out$distance, "double")
  expect_identical(out$distance, 10274)
  expect_type(out$avgHeartRateMoving, "double")
  expect_identical(out$avgHeartRateMoving, 148)
  expect_s3_class(out$durationMoving, "difftime")
  expect_identical(as.numeric(out$durationMoving, units = "mins"), 60)
  expect_type(out$garmin_matched, "logical")
})

test_that("my_dbs_load turns logical NA cells into typed NA", {
  summaries <- data.frame(
    sport = NA,
    distance = NA,
    stringsAsFactors = FALSE
  )

  out <- load_cache(summaries)

  expect_type(out$sport, "character")
  expect_true(is.na(out$sport))
  expect_type(out$distance, "double")
  expect_true(is.na(out$distance))
})

test_that("numeric factors are converted by value, not by level code", {
  summaries <- data.frame(
    sport = "running",
    distance = factor(c("9000", "10274")),
    stringsAsFactors = FALSE
  )

  out <- load_cache(summaries)

  expect_identical(out$distance, c(9000, 10274))
})

test_that("unparseable numeric cells become NA instead of erroring", {
  summaries <- data.frame(
    sport = "running",
    distance = "not-a-number",
    stringsAsFactors = FALSE
  )

  expect_warning(out <- load_cache(summaries), "distance")

  expect_type(out$distance, "double")
  expect_true(is.na(out$distance))
})

test_that("zero-row caches are normalised too", {
  summaries <- data.frame(
    sport = factor(character(), levels = c("running")),
    distance = character(),
    stringsAsFactors = FALSE
  )

  out <- suppressWarnings(load_cache(summaries))

  expect_type(out$sport, "character")
  expect_type(out$distance, "double")
  expect_identical(nrow(out), 0L)
})

test_that("non-canonical columns keep their type", {
  summaries <- data.frame(
    sport = "running",
    custom_flag = factor("x"),
    stringsAsFactors = FALSE
  )

  out <- load_cache(summaries)

  expect_s3_class(out$custom_flag, "factor")
})
