# Tests for R/health_export.R

test_that(".parse_metric handles standard qty format", {
  metric_obj <- list(
    name = "step_count",
    units = "count",
    data = list(
      list(date = "2026-01-05 00:00:00 +0100", qty = 10000, source = "AW"),
      list(date = "2026-01-06 00:00:00 +0100", qty = 8000, source = "AW")
    )
  )
  result <- traning:::.parse_metric(metric_obj)
  expect_equal(nrow(result), 2)
  expect_equal(result$metric, c("step_count", "step_count"))
  expect_equal(result$value, c(10000, 8000))
  expect_s3_class(result$date, "Date")
})

test_that(".parse_metric handles heart_rate Min/Avg/Max format", {
  metric_obj <- list(
    name = "heart_rate",
    units = "count/min",
    data = list(
      list(date = "2026-01-05 00:00:00 +0100", Min = 40, Avg = 60, Max = 150,
           source = "AW")
    )
  )
  result <- traning:::.parse_metric(metric_obj)
  expect_equal(nrow(result), 3)
  expect_setequal(result$metric,
                  c("heart_rate_min", "heart_rate_avg", "heart_rate_max"))
  expect_equal(result$value[result$metric == "heart_rate_min"], 40)
  expect_equal(result$value[result$metric == "heart_rate_avg"], 60)
  expect_equal(result$value[result$metric == "heart_rate_max"], 150)
})

test_that(".parse_metric handles sleep_analysis nested format", {
  metric_obj <- list(
    name = "sleep_analysis",
    units = "hr",
    data = list(
      list(date = "2026-01-05 00:00:00 +0100", totalSleep = 7.0,
           core = 4.3, deep = 0.5, rem = 2.2, awake = 0.1, inBed = 0,
           asleep = 0, sleepStart = "2026-01-04 23:30:00 +0100",
           sleepEnd = "2026-01-05 06:30:00 +0100",
           inBedStart = "2026-01-04 23:30:00 +0100",
           inBedEnd = "2026-01-05 06:30:00 +0100",
           source = "AW")
    )
  )
  result <- traning:::.parse_metric(metric_obj)
  expect_true(nrow(result) > 0)
  expect_true("sleep_totalSleep" %in% result$metric)
  expect_true("sleep_deep" %in% result$metric)
  expect_true("sleep_sleepStart" %in% result$metric)
  expect_equal(result$value[result$metric == "sleep_totalSleep"], 7.0)
})

test_that(".clean_sources drops Connect when pure AW exists for same date", {
  df <- tibble::tibble(
    date   = as.Date(c("2026-01-05", "2026-01-05", "2026-01-05")),
    metric = c("resting_heart_rate", "resting_heart_rate", "step_count"),
    value  = c(77, 50, 10000),
    source = c("AW | Connect", "AW", "AW | Connect")
  )
  result <- suppressMessages(traning:::.clean_sources(df))
  expect_equal(nrow(result), 2)
  # Connect-contaminated RHR dropped because pure AW exists for same date
  expect_equal(result$value[result$metric == "resting_heart_rate"], 50)
  # step_count with Connect source kept (not in contaminated list)
  expect_equal(result$value[result$metric == "step_count"], 10000)
})

test_that(".clean_sources keeps Connect as fallback when no pure AW exists", {
  df <- tibble::tibble(
    date   = as.Date(c("2026-01-05", "2026-01-06")),
    metric = c("resting_heart_rate", "resting_heart_rate"),
    value  = c(77, 51),
    source = c("AW | Connect", "AW")
  )
  result <- suppressMessages(traning:::.clean_sources(df))
  # Jan 5: only Connect → kept as fallback. Jan 6: pure AW → kept.
  expect_equal(nrow(result), 2)
  expect_equal(result$value[result$date == as.Date("2026-01-05")], 77)
  expect_equal(result$value[result$date == as.Date("2026-01-06")], 51)
})

test_that(".parse_metric returns empty tibble for empty data", {
  metric_obj <- list(name = "empty_metric", units = "?", data = list())
  result <- traning:::.parse_metric(metric_obj)
  expect_equal(nrow(result), 0)
})

test_that("pivot_health_wide produces one row per date", {
  df <- tibble::tibble(
    date   = as.Date(rep("2026-01-05", 3)),
    metric = c("step_count", "vo2_max", "resting_heart_rate"),
    value  = c(10000, 57, 52),
    source = rep("AW", 3)
  )
  wide <- pivot_health_wide(df)
  expect_equal(nrow(wide), 1)
  expect_true("step_count" %in% names(wide))
  expect_true("vo2_max" %in% names(wide))
})

test_that(".aggregate_daily sums step_count and takes min resting HR", {
  df <- tibble::tibble(
    date   = as.Date(c("2026-04-01", "2026-04-01", "2026-04-01",
                        "2026-04-01")),
    metric = c("step_count", "step_count", "resting_heart_rate",
               "resting_heart_rate"),
    value  = c(3000, 7000, 48, 52),
    source = c("kankad", "anandavani", "kankad", "AW")
  )
  result <- traning:::.aggregate_daily(df)
  expect_equal(result$value[result$metric == "step_count"], 10000)
  expect_equal(result$value[result$metric == "resting_heart_rate"], 48)
})

test_that("read_health_export filters Connect and aggregates raw data", {
  raw_json <- list(data = list(metrics = list(
    list(name = "resting_heart_rate", units = "count/min", data = list(
      list(date = "2026-04-01 00:00:00 +0200", qty = 110, source = "Connect"),
      list(date = "2026-04-01 06:30:00 +0200", qty = 50, source = "kankad")
    ))
  )))
  tmp <- tempfile(fileext = ".json")
  jsonlite::write_json(raw_json, tmp, auto_unbox = TRUE)
  result <- suppressMessages(read_health_export(tmp))
  expect_equal(nrow(result), 1)
  expect_equal(result$value, 50)
  expect_equal(result$source, "kankad")
})

test_that("get_readiness adds ln_rmssd column", {
  df <- tibble::tibble(
    date   = as.Date(rep("2026-01-05", 3)),
    metric = c("resting_heart_rate", "heart_rate_variability",
               "sleep_totalSleep"),
    value  = c(52, 60, 7.5),
    source = rep("AW", 3)
  )
  result <- get_readiness(df)
  expect_true("ln_rmssd" %in% names(result))
  expect_equal(result$ln_rmssd, log(60), tolerance = 1e-6)
})

# --- Manifest tests ---

test_that(".filter_changed_files detects new files", {
  tmp <- tempfile(fileext = ".json")
  writeLines("{}", tmp)
  manifest <- list()  # empty = first run
  result <- traning:::.filter_changed_files(tmp, manifest)
  expect_equal(result, tmp)
})

test_that(".filter_changed_files skips unchanged files", {
  tmp <- tempfile(fileext = ".json")
  writeLines("{}", tmp)
  manifest <- list()
  manifest[[basename(tmp)]] <- list(
    md5 = unname(tools::md5sum(tmp))
  )
  result <- traning:::.filter_changed_files(tmp, manifest)
  expect_length(result, 0)
})

test_that(".filter_changed_files detects modified files", {
  tmp <- tempfile(fileext = ".json")
  writeLines("{}", tmp)
  manifest <- list()
  manifest[[basename(tmp)]] <- list(
    md5 = "0000000000000000000000000000dead"
  )
  result <- traning:::.filter_changed_files(tmp, manifest)
  expect_equal(result, tmp)
})

test_that(".build_manifest_entries captures md5", {
  tmp <- tempfile(fileext = ".json")
  writeLines('{"key": "value"}', tmp)
  entries <- traning:::.build_manifest_entries(tmp)
  expect_true(basename(tmp) %in% names(entries))
  entry <- entries[[basename(tmp)]]
  expect_true(!is.null(entry$md5))
  expect_equal(entry$md5, unname(tools::md5sum(tmp)))
})

test_that(".load_manifest returns empty list for missing file", {
  result <- traning:::.load_manifest("/nonexistent/path/manifest.json")
  expect_equal(result, list())
})

test_that(".save_manifest and .load_manifest roundtrip", {
  tmp <- tempfile(fileext = ".json")
  manifest <- list(
    "file1.json" = list(mtime = 1000, size = 500),
    "file2.json" = list(mtime = 2000, size = 1500)
  )
  traning:::.save_manifest(manifest, tmp)
  loaded <- traning:::.load_manifest(tmp)
  expect_equal(loaded[["file1.json"]]$mtime, 1000)
  expect_equal(loaded[["file1.json"]]$size, 500)
  expect_equal(loaded[["file2.json"]]$mtime, 2000)
  expect_equal(loaded[["file2.json"]]$size, 1500)
})

# --- health_insight_delta tests ---

# Helper: build a health tibble with 7 days of stable data
.make_stable_history <- function(metric, value, n_days = 7,
                                  start = as.Date("2026-04-01")) {
  tibble::tibble(
    date   = start + seq_len(n_days) - 1,
    metric = metric,
    value  = value,
    source = "AW"
  )
}

test_that("health_insight_delta reports HRV change above threshold", {
  before <- .make_stable_history("heart_rate_variability", 60)
  after  <- dplyr::bind_rows(
    before,
    tibble::tibble(date = as.Date("2026-04-08"),
                   metric = "heart_rate_variability", value = 72, source = "AW")
  )
  result <- health_insight_delta(before, after)
  expect_match(result, "HRV")
  expect_match(result, "72")
  expect_match(result, "\\+12")
})

test_that("health_insight_delta ignores HRV change below threshold", {
  before <- .make_stable_history("heart_rate_variability", 60)
  after  <- dplyr::bind_rows(
    before,
    tibble::tibble(date = as.Date("2026-04-08"),
                   metric = "heart_rate_variability", value = 62, source = "AW")
  )
  result <- health_insight_delta(before, after)
  expect_equal(result, "")
})

test_that("health_insight_delta always reports tier 1 metrics", {
  before <- .make_stable_history("vo2_max", 57.0)
  after  <- dplyr::bind_rows(
    before,
    tibble::tibble(date = as.Date("2026-04-08"),
                   metric = "vo2_max", value = 57.5, source = "AW")
  )
  result <- health_insight_delta(before, after)
  expect_match(result, "VO2max")
  expect_match(result, "57.5")
})

test_that("health_insight_delta ignores tier 3 metrics", {
  before <- .make_stable_history("step_count", 10000)
  after  <- dplyr::bind_rows(
    before,
    tibble::tibble(date = as.Date("2026-04-08"),
                   metric = "step_count", value = 15000, source = "AW")
  )
  result <- health_insight_delta(before, after)
  expect_equal(result, "")
})

test_that("health_insight_delta handles empty before (first import)", {
  before <- tibble::tibble(
    date = as.Date(character()), metric = character(),
    value = numeric(), source = character()
  )
  after <- tibble::tibble(
    date   = as.Date("2026-04-08"),
    metric = c("resting_heart_rate", "heart_rate_variability"),
    value  = c(52, 65),
    source = c("AW", "AW")
  )
  result <- health_insight_delta(before, after)
  expect_match(result, "vila")
  expect_match(result, "HRV")
})

test_that("health_insight_delta flags short sleep", {
  before <- .make_stable_history("sleep_totalSleep", 7.0)
  after  <- dplyr::bind_rows(
    before,
    tibble::tibble(date = as.Date("2026-04-08"),
                   metric = "sleep_totalSleep", value = 4.8, source = "AW")
  )
  result <- health_insight_delta(before, after)
  expect_match(result, "kort natt")
})

test_that("health_insight_delta treats unknown metrics as tier 1", {
  before <- tibble::tibble(
    date = as.Date(character()), metric = character(),
    value = numeric(), source = character()
  )
  after <- tibble::tibble(
    date = as.Date("2026-04-08"),
    metric = "some_future_metric", value = 42, source = "AW"
  )
  result <- health_insight_delta(before, after)
  expect_match(result, "some_future_metric")
  expect_match(result, "42")
})

test_that("health_insight_delta returns empty when nothing changed", {
  data <- .make_stable_history("resting_heart_rate", 52)
  result <- health_insight_delta(data, data)
  expect_equal(result, "")
})

test_that("import_health_export with force bypasses manifest", {
  # Create a minimal JSON file
  raw_json <- list(data = list(metrics = list(
    list(name = "step_count", units = "count", data = list(
      list(date = "2026-04-01 00:00:00 +0200", qty = 5000, source = "AW")
    ))
  )))
  tmp_dir <- tempdir()
  tmp_file <- file.path(tmp_dir, "test_force.json")
  jsonlite::write_json(raw_json, tmp_file, auto_unbox = TRUE)
  cache <- tempfile(fileext = ".RData")

  # First import
  result1 <- suppressMessages(
    import_health_export(path = tmp_file, cache_path = cache, verbose = FALSE)
  )
  expect_equal(nrow(result1), 1)

  # Second import with force — should still parse
  result2 <- suppressMessages(
    import_health_export(path = tmp_file, cache_path = cache,
                          force = TRUE, verbose = FALSE)
  )
  expect_equal(nrow(result2), 1)
})
