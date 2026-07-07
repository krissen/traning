# Tests for R/metrics.R: add_my_columns()

test_that("add_my_columns computes avgStrideMoving and avgStride correctly", {
  # avgStride formulas: (60 * speed) / (cadence * 2). Using round numbers
  # so the expected values are easy to hand-verify.
  summarydata <- tibble::tibble(
    avgSpeedMoving = 3.0,       # m/s
    avgCadenceRunningMoving = 90, # steps/min
    avgSpeed = 2.4,
    avgCadenceRunning = 80
  )

  res <- add_my_columns(summarydata)

  expect_true(all(c("avgStrideMoving", "avgStride") %in% names(res)))
  expect_equal(res$avgStrideMoving, (60 * 3.0) / (90 * 2))
  expect_equal(res$avgStride, (60 * 2.4) / (80 * 2))
})

test_that("add_my_columns preserves existing columns and row count", {
  summarydata <- tibble::tibble(
    sessionStart = as.POSIXct("2024-01-01 07:00:00", tz = "UTC"),
    distance = 5000,
    avgSpeedMoving = 3.0,
    avgCadenceRunningMoving = 90,
    avgSpeed = 2.5,
    avgCadenceRunning = 85
  )

  res <- add_my_columns(summarydata)

  expect_equal(nrow(res), 1)
  expect_equal(res$distance, 5000)
  expect_equal(res$sessionStart, summarydata$sessionStart)
})

test_that("add_my_columns vectorizes over multiple rows independently", {
  summarydata <- tibble::tibble(
    avgSpeedMoving = c(3.0, 4.0),
    avgCadenceRunningMoving = c(90, 100),
    avgSpeed = c(2.5, 3.5),
    avgCadenceRunning = c(85, 95)
  )

  res <- add_my_columns(summarydata)

  expect_equal(res$avgStrideMoving,
              (60 * summarydata$avgSpeedMoving) /
                (summarydata$avgCadenceRunningMoving * 2))
  expect_equal(res$avgStride,
              (60 * summarydata$avgSpeed) /
                (summarydata$avgCadenceRunning * 2))
})

test_that("add_my_columns produces NaN/Inf, not an error, for zero cadence", {
  # Real-world edge case: a session with avgCadenceRunning == 0 (e.g. a
  # cadence sensor dropout). The current implementation divides straight
  # through, so this documents actual behavior rather than asserting a
  # guard that doesn't exist.
  summarydata <- tibble::tibble(
    avgSpeedMoving = 3.0,
    avgCadenceRunningMoving = 0,
    avgSpeed = 0,
    avgCadenceRunning = 0
  )

  res <- add_my_columns(summarydata)

  expect_true(is.infinite(res$avgStrideMoving))
  expect_true(is.nan(res$avgStride)) # 0/0
})
