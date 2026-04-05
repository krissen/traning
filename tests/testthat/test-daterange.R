test_that("parse_date_expr handles absolute year", {
  expect_equal(parse_date_expr("2023"), as.Date("2023-01-01"))
  expect_equal(parse_date_expr("2020"), as.Date("2020-01-01"))
})

test_that("parse_date_expr handles absolute year-month", {
  expect_equal(parse_date_expr("2023-03"), as.Date("2023-03-01"))
  expect_equal(parse_date_expr("2023-12"), as.Date("2023-12-01"))
})

test_that("parse_date_expr handles absolute year-month-day", {
  expect_equal(parse_date_expr("2023-03-15"), as.Date("2023-03-15"))
})

test_that("parse_date_expr handles relative expressions", {
  ref <- as.Date("2025-06-15")
  expect_equal(parse_date_expr("-3w", reference = ref), ref - lubridate::weeks(3))
  expect_equal(parse_date_expr("-1y", reference = ref), ref - lubridate::years(1))
  expect_equal(parse_date_expr("-6m", reference = ref), ref - lubridate::period(6, "month"))
  expect_equal(parse_date_expr("-10d", reference = ref), ref - lubridate::days(10))
})

test_that("parse_date_expr handles positive span expressions", {
  ref <- as.Date("2024-01-01")
  expect_equal(parse_date_expr("3m", reference = ref), ref + lubridate::period(3, "month"))
  expect_equal(parse_date_expr("1y", reference = ref), ref + lubridate::years(1))
  expect_equal(parse_date_expr("6w", reference = ref), ref + lubridate::weeks(6))
  expect_equal(parse_date_expr("30d", reference = ref), ref + lubridate::days(30))
})

test_that("parse_date_expr rejects invalid input", {
  expect_error(parse_date_expr("abc"))
  expect_error(parse_date_expr(""))
})

test_that("build_date_range returns NULLs when no arguments", {
  result <- build_date_range()
  expect_null(result$from)
  expect_null(result$to)
})

test_that("build_date_range handles after only", {
  result <- build_date_range(after = "2023")
  expect_equal(result$from, as.Date("2023-01-01"))
  expect_null(result$to)
})

test_that("build_date_range handles before only", {
  result <- build_date_range(before = "2024-06")
  expect_null(result$from)
  expect_equal(result$to, as.Date("2024-06-01"))
})

test_that("build_date_range handles after + before", {
  result <- build_date_range(after = "2023", before = "2024")
  expect_equal(result$from, as.Date("2023-01-01"))
  expect_equal(result$to, as.Date("2024-01-01"))
})

test_that("build_date_range handles after + span", {
  result <- build_date_range(after = "2023-01", span = "3m")
  expect_equal(result$from, as.Date("2023-01-01"))
  expect_equal(result$to, as.Date("2023-04-01"))
})

test_that("build_date_range rejects span + before", {
  expect_error(build_date_range(before = "2024", span = "3m"))
})

test_that("build_date_range rejects span without after", {
  expect_error(build_date_range(span = "3m"))
})

test_that("filter_by_daterange returns unchanged data when no range", {
  df <- tibble::tibble(sessionStart = as.POSIXct(c("2023-01-01", "2024-01-01", "2025-01-01")))
  result <- filter_by_daterange(df, list(from = NULL, to = NULL))
  expect_equal(nrow(result), 3)
})

test_that("filter_by_daterange filters by from date", {
  df <- tibble::tibble(sessionStart = as.POSIXct(c("2023-01-01", "2024-01-01", "2025-01-01")))
  result <- filter_by_daterange(df, list(from = as.Date("2024-01-01"), to = NULL))
  expect_equal(nrow(result), 2)
})

test_that("filter_by_daterange filters by to date (exclusive)", {
  df <- tibble::tibble(sessionStart = as.POSIXct(c("2023-01-01", "2024-01-01", "2025-01-01")))
  result <- filter_by_daterange(df, list(from = NULL, to = as.Date("2025-01-01")))
  expect_equal(nrow(result), 2)
})

test_that("filter_by_daterange filters by both from and to", {
  df <- tibble::tibble(sessionStart = as.POSIXct(c("2023-01-01", "2024-01-01", "2025-01-01")))
  result <- filter_by_daterange(df, list(from = as.Date("2023-06-01"), to = as.Date("2024-06-01")))
  expect_equal(nrow(result), 1)
})
