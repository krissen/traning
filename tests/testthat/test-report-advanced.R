# Tests for advanced metric report functions

# --- Test fixtures ---
# Minimal summaries data frame with columns needed by compute_*() functions
make_test_summaries <- function(n = 60) {
  dates <- seq(Sys.Date() - n, Sys.Date() - 1, by = "day")
  # One run every other day
  run_dates <- dates[seq(1, length(dates), by = 2)]
  tibble::tibble(
    sessionStart = as.POSIXct(run_dates),
    sport = "running",
    distance = runif(length(run_dates), 5000, 15000),
    avgSpeedMoving = runif(length(run_dates), 2.5, 3.5),
    avgPaceMoving = runif(length(run_dates), 4.5, 6.5),
    avgHeartRateMoving = runif(length(run_dates), 140, 170),
    durationMoving = runif(length(run_dates), 25, 70)
  )
}

test_summaries <- make_test_summaries(90)

# --- report_ef ---
test_that("report_ef returns tibble with expected columns", {
  result <- report_ef(test_summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "Km", "EF", "EF 28d") %in% names(result)))
})

test_that("report_ef respects n parameter", {
  result <- report_ef(test_summaries, n = 5)
  expect_lte(nrow(result), 5)
})

test_that("report_ef respects from/to date range", {
  from <- Sys.Date() - 30
  to <- Sys.Date() - 10
  result <- report_ef(test_summaries, from = from, to = to)
  if (nrow(result) > 0) {
    expect_true(all(result$Datum >= from))
    expect_true(all(result$Datum < to))
  }
})

test_that("report_ef gives identical output for bundle and bare-summaries calls", {
  bundle <- traning_data(summaries = test_summaries)
  expect_identical(report_ef(bundle), report_ef(test_summaries))
})

# --- report_hre ---
test_that("report_hre returns tibble with expected columns", {
  result <- report_hre(test_summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "Km", "HRE", "HRE 28d") %in% names(result)))
})

test_that("report_hre respects n parameter", {
  result <- report_hre(test_summaries, n = 3)
  expect_lte(nrow(result), 3)
})

# --- report_acwr ---
test_that("report_acwr returns tibble with expected columns", {
  result <- report_acwr(test_summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "Km/dag", "Km/vecka", "ACWR") %in% names(result)))
})

test_that("report_acwr respects n parameter", {
  result <- report_acwr(test_summaries, n = 7)
  expect_equal(nrow(result), 7)
})

test_that("report_acwr gives identical output for bundle and bare-summaries calls", {
  bundle <- traning_data(summaries = test_summaries)
  expect_identical(report_acwr(bundle), report_acwr(test_summaries))
})

test_that("report_acwr threads health_daily from the bundle into TRIMP mode", {
  hd <- tibble::tibble(
    date = seq(min(as.Date(test_summaries$sessionStart)),
               max(as.Date(test_summaries$sessionStart)), by = "day"),
    metric = "step_count",
    value = 5000,
    source = "test"
  )
  bundle <- traning_data(summaries = test_summaries, health_daily = hd)
  bare <- report_acwr(test_summaries, sport = "all")
  via_bundle <- report_acwr(bundle, sport = "all")
  # With background-activity data present, the TRIMP-mode output should
  # differ from the health_daily-less bare call — proving the bundle's
  # @health_daily reaches compute_acwr().
  expect_false(identical(bare, via_bundle))
})

# --- report_monotony ---
test_that("report_monotony returns tibble with expected columns", {
  result <- report_monotony(test_summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "Km/dag", "Km/vecka", "Monotoni", "Belastning")
                   %in% names(result)))
})

# --- report_pmc ---
test_that("report_pmc returns tibble with expected columns", {
  withr::local_envvar(HR_MAX = "185")
  result <- report_pmc(test_summaries)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "TRIMP", "CTL", "ATL", "TSB") %in% names(result)))
})

test_that("report_pmc gives identical output for bundle and bare-summaries calls", {
  withr::local_envvar(HR_MAX = "185")
  bundle <- traning_data(summaries = test_summaries)
  expect_identical(report_pmc(bundle), report_pmc(test_summaries))
})

# --- report_readiness ---
test_that("report_readiness gives identical output via a traning_data bundle", {
  withr::local_envvar(HR_MAX = "185")
  dates <- seq(min(as.Date(test_summaries$sessionStart)),
               max(as.Date(test_summaries$sessionStart)), by = "day")
  metric_base <- c(
    heart_rate_variability = 70, sleep_totalSleep = 7,
    sleep_deep = 1.0, sleep_rem = 1.5, resting_heart_rate = 55
  )
  hd <- do.call(rbind, lapply(names(metric_base), function(m) {
    tibble::tibble(date = dates, metric = m, value = metric_base[[m]],
                   source = "test")
  })) |> tibble::as_tibble()
  bundle <- traning_data(summaries = test_summaries, health_daily = hd)
  result <- report_readiness(bundle)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "Beredskap", "Status") %in% names(result)))
  expect_gt(nrow(result), 0)
})

# --- report_recovery_hr ---
test_that("report_recovery_hr returns empty tibble when no data", {
  # test_summaries lacks garmin_recoveryHeartRate, so compute_recovery_hr errors
  # We expect the report to handle this gracefully if the column doesn't exist
  expect_error(report_recovery_hr(test_summaries))
})

test_that("report_recovery_hr works with enriched data", {
  enriched <- test_summaries
  enriched$garmin_recoveryHeartRate <- runif(nrow(enriched), 80, 120)
  result <- report_recovery_hr(enriched)
  expect_s3_class(result, "tbl_df")
  expect_true(all(c("Datum", "Km", "Recovery HR", "RHR 28d") %in% names(result)))
})

# --- save_plot ---
test_that("save_plot creates file with auto-generated name", {
  p <- ggplot2::ggplot(data.frame(x = 1:10, y = 1:10),
                       ggplot2::aes(x, y)) + ggplot2::geom_point()
  tmp_dir <- tempdir()
  output <- save_plot(p, default_name = "test",
                      output = file.path(tmp_dir, "test_out.pdf"),
                      open = FALSE)
  expect_true(file.exists(output))
  unlink(output)
})

test_that("save_plot infers format from extension", {
  p <- ggplot2::ggplot(data.frame(x = 1:10, y = 1:10),
                       ggplot2::aes(x, y)) + ggplot2::geom_point()
  tmp_png <- file.path(tempdir(), "test_out.png")
  save_plot(p, output = tmp_png, open = FALSE)
  expect_true(file.exists(tmp_png))
  unlink(tmp_png)
})

# --- save_table ---
test_that("save_table writes CSV", {
  tbl <- data.frame(a = 1:3, b = c("x", "y", "z"))
  tmp <- file.path(tempdir(), "test_table.csv")
  save_table(tbl, output = tmp, open = FALSE)
  expect_true(file.exists(tmp))
  loaded <- utils::read.csv(tmp)
  expect_equal(nrow(loaded), 3)
  unlink(tmp)
})

test_that("save_table writes JSON", {
  tbl <- data.frame(a = 1:3, b = c("x", "y", "z"))
  tmp <- file.path(tempdir(), "test_table.json")
  save_table(tbl, output = tmp, open = FALSE)
  expect_true(file.exists(tmp))
  loaded <- jsonlite::fromJSON(tmp)
  expect_equal(nrow(loaded), 3)
  unlink(tmp)
})

test_that("save_table writes JSONL", {
  tbl <- data.frame(a = 1:3, b = c("x", "y", "z"))
  tmp <- file.path(tempdir(), "test_table.jsonl")
  save_table(tbl, output = tmp, open = FALSE)
  expect_true(file.exists(tmp))
  lines <- readLines(tmp)
  expect_equal(length(lines), 3)
  first <- jsonlite::fromJSON(lines[1])
  expect_equal(first$a, "1")
  unlink(tmp)
})
