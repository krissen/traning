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

test_that(".clean_sources removes Connect-contaminated resting HR", {
  df <- tibble::tibble(
    date   = as.Date(c("2026-01-05", "2026-01-06", "2026-01-05")),
    metric = c("resting_heart_rate", "resting_heart_rate", "step_count"),
    value  = c(77, 51, 10000),
    source = c("AW | Connect", "AW", "AW | Connect")
  )
  result <- suppressMessages(traning:::.clean_sources(df))
  expect_equal(nrow(result), 2)
  # The Connect-contaminated resting HR (77 bpm) should be removed
  expect_equal(result$value[result$metric == "resting_heart_rate"], 51)
  # step_count with Connect source should be kept (not in contaminated list)
  expect_equal(result$value[result$metric == "step_count"], 10000)
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
  info <- file.info(tmp)
  manifest <- list()
  manifest[[basename(tmp)]] <- list(
    mtime = as.integer(as.numeric(info$mtime)),
    size  = info$size
  )
  result <- traning:::.filter_changed_files(tmp, manifest)
  expect_length(result, 0)
})

test_that(".filter_changed_files detects modified files (size change)", {
  tmp <- tempfile(fileext = ".json")
  writeLines("{}", tmp)
  info <- file.info(tmp)
  manifest <- list()
  manifest[[basename(tmp)]] <- list(
    mtime = as.integer(as.numeric(info$mtime)),
    size  = info$size + 100  # mismatch
  )
  result <- traning:::.filter_changed_files(tmp, manifest)
  expect_equal(result, tmp)
})

test_that(".build_manifest_entries captures size", {
  tmp <- tempfile(fileext = ".json")
  writeLines('{"key": "value"}', tmp)
  entries <- traning:::.build_manifest_entries(tmp)
  expect_true(basename(tmp) %in% names(entries))
  entry <- entries[[basename(tmp)]]
  expect_true(!is.null(entry$size))
  expect_equal(entry$size, file.size(tmp))
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
