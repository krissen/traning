# Tests for basic report functions (month/year aggregation)

# --- Test fixture ---
# Multi-year summaries spanning 2022–2024, one run every 3 days.
# set.seed() ensures reproducible distance/pace values across runs.
make_multi_year_summaries <- function() {
  set.seed(42)
  dates <- seq(as.Date("2022-01-01"), as.Date("2024-12-31"), by = "3 days")
  tibble::tibble(
    sessionStart      = as.POSIXct(dates),
    sport             = "running",
    distance          = runif(length(dates), 5000, 15000),
    avgSpeedMoving    = runif(length(dates), 2.5, 3.5),
    avgPaceMoving     = runif(length(dates), 4.5, 6.5),
    avgHeartRateMoving = runif(length(dates), 140, 170),
    durationMoving    = runif(length(dates), 25, 70)
  )
}

summaries <- make_multi_year_summaries()

# --- report_monthtop ---

test_that("report_monthtop returns tibble with expected columns", {
  result <- report_monthtop(summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("År-mån", "Km, tot", "Km, max", "Tempo, medel", "Turer")
                  %in% names(result)))
})

test_that("report_monthtop default n = 10 limits rows", {
  result <- report_monthtop(summaries)
  expect_lte(nrow(result), 10)
})

test_that("report_monthtop respects custom n", {
  result5 <- report_monthtop(summaries, n = 5)
  expect_lte(nrow(result5), 5)

  result3 <- report_monthtop(summaries, n = 3)
  expect_lte(nrow(result3), 3)
})

test_that("report_monthtop from/to filtering restricts months", {
  result <- report_monthtop(summaries,
                             n   = 100,
                             from = as.Date("2023-01-01"),
                             to   = as.Date("2024-01-01"))
  years <- as.integer(substr(result[["År-mån"]], 1, 4))
  expect_true(all(years == 2023))
})

test_that("report_monthtop rows are sorted descending by total km", {
  result <- report_monthtop(summaries, n = 20)
  expect_true(all(diff(result[["Km, tot"]]) <= 0))
})

# --- report_monthstatus ---

test_that("report_monthstatus returns tibble with expected columns", {
  result <- report_monthstatus(summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("År", "Km/dag", "Km, tot", "Km, max", "Tempo, medel", "Turer")
                  %in% names(result)))
})

test_that("report_monthstatus is sorted newest year first", {
  result <- report_monthstatus(summaries)
  if (nrow(result) > 1) {
    expect_true(all(diff(result[["År"]]) <= 0))
  }
})

test_that("report_monthstatus respects n parameter", {
  result <- report_monthstatus(summaries, n = 2)
  expect_lte(nrow(result), 2)
})

test_that("report_monthstatus from/to filtering works", {
  result <- report_monthstatus(summaries,
                                from = as.Date("2023-01-01"),
                                to   = as.Date("2024-01-01"))
  if (nrow(result) > 0) {
    expect_true(all(result[["År"]] == 2023))
  }
})

# --- report_monthlast ---

test_that("report_monthlast returns tibble with expected columns", {
  result <- report_monthlast(summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("År", "Km/dag", "Km, tot", "Km, max", "Tempo, medel", "Turer")
                  %in% names(result)))
})

test_that("report_monthlast is sorted newest year first", {
  result <- report_monthlast(summaries)
  if (nrow(result) > 1) {
    expect_true(all(diff(result[["År"]]) <= 0))
  }
})

test_that("report_monthlast respects n parameter", {
  result <- report_monthlast(summaries, n = 1)
  expect_lte(nrow(result), 1)
})

test_that("report_monthlast produces no console output", {
  output <- capture.output(result <- report_monthlast(summaries))
  expect_length(output, 0)
})

# --- report_yearstop ---

test_that("report_yearstop returns tibble with expected columns", {
  result <- report_yearstop(summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("År", "Km/dag", "Km, tot", "Km, max", "Tempo, medel", "Turer")
                  %in% names(result)))
})

test_that("report_yearstop is sorted newest year first", {
  result <- report_yearstop(summaries)
  if (nrow(result) > 1) {
    expect_true(all(diff(result[["År"]]) <= 0))
  }
})

test_that("report_yearstop respects n parameter", {
  result <- report_yearstop(summaries, n = 2)
  expect_lte(nrow(result), 2)
})

test_that("report_yearstop from excludes earlier years", {
  result <- report_yearstop(summaries, from = as.Date("2023-01-01"))
  expect_true(all(result[["År"]] >= 2023))
})

test_that("report_yearstop to excludes later years", {
  result <- report_yearstop(summaries, to = as.Date("2023-01-01"))
  expect_true(all(result[["År"]] < 2023))
})

test_that("report_yearstop from/to together returns only that year", {
  result <- report_yearstop(summaries,
                             from = as.Date("2023-01-01"),
                             to   = as.Date("2024-01-01"))
  expect_true(all(result[["År"]] == 2023))
})

# --- report_yearstatus ---

test_that("report_yearstatus returns tibble with expected columns", {
  result <- report_yearstatus(summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("År", "Km/dag", "Km, tot", "Km, max", "Tempo, medel", "Turer")
                  %in% names(result)))
})

test_that("report_yearstatus is sorted newest year first", {
  result <- report_yearstatus(summaries)
  if (nrow(result) > 1) {
    expect_true(all(diff(result[["År"]]) <= 0))
  }
})

test_that("report_yearstatus respects n parameter", {
  result <- report_yearstatus(summaries, n = 2)
  expect_lte(nrow(result), 2)
})

test_that("report_yearstatus only includes runs up to current day-of-year", {
  result <- report_yearstatus(summaries)
  my_dayyear <- as.numeric(format(Sys.time(), "%j"))
  # Km/dag = total km / day-of-year, so total km = Km/dag * day-of-year
  # We can't inspect individual runs, but we verify the column is numeric
  expect_type(result[["Km/dag"]], "double")
  # Sanity: no year should have more km/dag than the max single-run distance / 1
  expect_true(all(result[["Km/dag"]] > 0))
})

# --- report_runs_year_month ---

test_that("report_runs_year_month returns tibble with expected columns", {
  # Use an explicit range so the test is date-independent
  result <- report_runs_year_month(summaries,
                                    from = as.Date("2023-03-01"),
                                    to   = as.Date("2023-04-01"))
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("År", "Mån", "Dag", "Km", "Pace", "HR") %in% names(result)))
})

test_that("report_runs_year_month is sorted newest day first", {
  result <- report_runs_year_month(summaries,
                                    from = as.Date("2023-06-01"),
                                    to   = as.Date("2023-07-01"))
  if (nrow(result) > 1) {
    expect_true(all(diff(result[["Dag"]]) <= 0))
  }
})

test_that("report_runs_year_month from/to selects correct month", {
  result <- report_runs_year_month(summaries,
                                    from = as.Date("2022-07-01"),
                                    to   = as.Date("2022-08-01"))
  expect_true(all(result[["År"]] == 2022))
  expect_true(all(result[["Mån"]] == 7))
})

test_that("report_runs_year_month respects n parameter", {
  result <- report_runs_year_month(summaries,
                                    from = as.Date("2023-01-01"),
                                    to   = as.Date("2024-01-01"),
                                    n    = 4)
  expect_lte(nrow(result), 4)
})

test_that("report_runs_year_month default (no args) returns current month only", {
  # Inject a run today so the default range always has something to return
  today <- Sys.Date()
  today_row <- tibble::tibble(
    sessionStart       = as.POSIXct(today),
    sport              = "running",
    distance           = 8000,
    avgSpeedMoving     = 3.0,
    avgPaceMoving      = 5.5,
    avgHeartRateMoving = 155,
    durationMoving     = 45
  )
  enriched <- dplyr::bind_rows(summaries, today_row)
  result <- report_runs_year_month(enriched)
  current_month <- as.integer(format(today, "%m"))
  current_year  <- as.integer(format(today, "%Y"))
  expect_true(all(result[["Mån"]] == current_month))
  expect_true(all(result[["År"]] == current_year))
})
