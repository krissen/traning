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
  # Isolate TRANING_DATA so .hae_manifest_path() points at a tempdir.
  # Without this the test would write to the production manifest under
  # the developer's real $TRANING_DATA — which is exactly how this
  # test's "test_force.json" entry leaked into prod manifests before.
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)

  raw_json <- list(data = list(metrics = list(
    list(name = "step_count", units = "count", data = list(
      list(date = "2026-04-01 00:00:00 +0200", qty = 5000, source = "AW")
    ))
  )))
  tmp_file <- file.path(tmp_data, "test_force.json")
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

# --- Regression tests for manifest overwrite bug (fixed) -------------------
#
# Before the fix, a single-file run of import_health_export(path = X) would
# load a *fresh* empty manifest at the top, then write {X: md5} to disk —
# wiping every other entry. Receiver flushes call this code path on every
# HAE push, so the production manifest was effectively reset multiple times
# a day, and supposedly-incremental imports kept doing full re-parses of
# 60k+ files. These tests pin the merge-not-overwrite behaviour.

test_that("single-file import preserves entries it didn't touch", {
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  cache <- tempfile(fileext = ".RData")

  # Seed manifest as if a previous full import wrote entries for many files.
  seed <- list(
    "step_count/2024-01-01.json"         = list(md5 = "aaaa"),
    "step_count/2024-01-02.json"         = list(md5 = "bbbb"),
    "resting_heart_rate/2024-01-01.json" = list(md5 = "cccc")
  )
  traning:::.save_manifest(seed)

  raw_json <- list(data = list(metrics = list(
    list(name = "step_count", units = "count", data = list(
      list(date = "2026-04-01 00:00:00 +0200", qty = 5000, source = "AW")
    ))
  )))
  tmp_file <- file.path(tmp_data, "touched.json")
  jsonlite::write_json(raw_json, tmp_file, auto_unbox = TRUE)

  suppressMessages(import_health_export(path = tmp_file, cache_path = cache,
                                         verbose = FALSE))

  after <- traning:::.load_manifest()
  expect_true("step_count/2024-01-01.json" %in% names(after))
  expect_true("step_count/2024-01-02.json" %in% names(after))
  expect_true("resting_heart_rate/2024-01-01.json" %in% names(after))
  expect_true("touched.json" %in% names(after))
  expect_equal(after[["step_count/2024-01-01.json"]]$md5, "aaaa")
})

test_that("forced single-file import also preserves untouched entries", {
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  cache <- tempfile(fileext = ".RData")

  traning:::.save_manifest(list(
    "step_count/2024-01-01.json" = list(md5 = "keep-me")
  ))

  raw_json <- list(data = list(metrics = list(
    list(name = "step_count", units = "count", data = list(
      list(date = "2026-04-01 00:00:00 +0200", qty = 5000, source = "AW")
    ))
  )))
  tmp_file <- file.path(tmp_data, "force_me.json")
  jsonlite::write_json(raw_json, tmp_file, auto_unbox = TRUE)

  suppressMessages(import_health_export(path = tmp_file, cache_path = cache,
                                         force = TRUE, verbose = FALSE))

  after <- traning:::.load_manifest()
  expect_equal(after[["step_count/2024-01-01.json"]]$md5, "keep-me")
  expect_true("force_me.json" %in% names(after))
})

test_that(".filter_changed_files tolerates corrupt manifest entries", {
  tmp <- tempfile(fileext = ".json")
  writeLines("{}", tmp)
  key <- basename(tmp)

  # NULL entry.
  m1 <- setNames(list(NULL), key)
  expect_equal(traning:::.filter_changed_files(tmp, m1), tmp)

  # Wrong type for the entry (e.g. someone wrote a bare string).
  m2 <- setNames(list("not-a-list"), key)
  expect_equal(traning:::.filter_changed_files(tmp, m2), tmp)

  # Entry is a list but $md5 missing.
  m3 <- setNames(list(list(other = "x")), key)
  expect_equal(traning:::.filter_changed_files(tmp, m3), tmp)

  # Entry is a list and $md5 is the wrong type / length.
  m4 <- setNames(list(list(md5 = 42)), key)
  expect_equal(traning:::.filter_changed_files(tmp, m4), tmp)
  m5 <- setNames(list(list(md5 = c("a", "b"))), key)
  expect_equal(traning:::.filter_changed_files(tmp, m5), tmp)

  # $md5 is NA_character_ — earlier the != comparison returned NA which
  # poisoned the result vector. Treat as "new" instead.
  m6 <- setNames(list(list(md5 = NA_character_)), key)
  result <- traning:::.filter_changed_files(tmp, m6)
  expect_equal(result, tmp)
  expect_false(anyNA(result))
})

test_that(".load_manifest tolerates wrong-shape JSON (scalar / unnamed)", {
  tmp <- tempfile(fileext = ".json")
  # Valid JSON but not the named-list shape we expect.
  writeLines("42", tmp)
  expect_warning(loaded <- traning:::.load_manifest(tmp),
                 "wrong shape")
  expect_equal(loaded, list())

  # Unnamed array.
  writeLines('["a", "b"]', tmp)
  expect_warning(loaded <- traning:::.load_manifest(tmp),
                 "wrong shape")
  expect_equal(loaded, list())

  # JSON with at least one empty key — also rejected.
  writeLines('{"a": {"md5": "x"}, "": {"md5": "y"}}', tmp)
  expect_warning(loaded <- traning:::.load_manifest(tmp),
                 "wrong shape")
  expect_equal(loaded, list())

  # Unparseable JSON.
  writeLines("{ not json", tmp)
  expect_warning(loaded <- traning:::.load_manifest(tmp),
                 "unreadable")
  expect_equal(loaded, list())
})

test_that(".save_manifest writes atomically and survives stale temp files", {
  tmp_dir <- withr::local_tempdir()
  manifest_path <- file.path(tmp_dir, "manifest.json")

  # Seed a valid existing manifest.
  traning:::.save_manifest(list(a = list(md5 = "111")), manifest_path)
  expect_equal(traning:::.load_manifest(manifest_path)[["a"]]$md5, "111")

  # Leave a stale .tmp file as if a previous writer crashed mid-write.
  # The next .save_manifest must still produce a valid file and not pick
  # up the stale temp content as its output.
  writeLines("{ this is not json",
             file.path(tmp_dir, "manifest.json.tmp.9999"))
  traning:::.save_manifest(list(a = list(md5 = "222")), manifest_path)
  expect_equal(traning:::.load_manifest(manifest_path)[["a"]]$md5, "222")
})

test_that("import refreshes manifest when .import_metrics filters out all changes", {
  # Copilot's review caught this: if every candidate file is a metric we
  # skip, files_to_parse goes to length 0, the early-return on "no new
  # data" fires, and the manifest is never updated — so the same files
  # show up as "changed" on every subsequent run.
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  canonical_dir <- file.path(tmp_data, "kristian", "health_export", "canonical")
  dir.create(file.path(canonical_dir, "ignored_metric"), recursive = TRUE)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  cache <- file.path(tmp_data, "cache", "health_daily.RData")

  # Pick a metric name that is *not* in .import_metrics so the filter
  # strips it after the manifest check.
  testthat::skip_if(
    "ignored_metric" %in% traning:::.import_metrics,
    "ignored_metric is unexpectedly in .import_metrics"
  )

  f <- file.path(canonical_dir, "ignored_metric", "2024-01-01.json")
  jsonlite::write_json(
    list(metric = "ignored_metric", date = "2024-01-01",
         units = "count", samples = list(list(qty = 1))),
    f, auto_unbox = TRUE
  )
  expected_md5 <- unname(tools::md5sum(f))

  # No seed manifest → all files are "changed" against the manifest.
  suppressMessages(import_health_export(cache_path = cache, verbose = FALSE))

  manifest <- traning:::.load_manifest()
  key <- "ignored_metric/2024-01-01.json"
  expect_true(key %in% names(manifest),
              info = "filter-emptied run must still record the file in manifest")
  expect_equal(manifest[[key]]$md5, expected_md5)
})

test_that("import recovers when on-disk manifest is corrupt", {
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  cache <- file.path(tmp_data, "cache", "health_daily.RData")

  # Write garbage where the manifest should be.
  writeLines("{ not valid json",
             file.path(tmp_data, "cache", "health_import_manifest.json"))

  raw_json <- list(data = list(metrics = list(
    list(name = "step_count", units = "count", data = list(
      list(date = "2026-04-01 00:00:00 +0200", qty = 5000, source = "AW")
    ))
  )))
  tmp_file <- file.path(tmp_data, "f.json")
  jsonlite::write_json(raw_json, tmp_file, auto_unbox = TRUE)

  expect_no_error(
    suppressMessages(suppressWarnings(
      import_health_export(path = tmp_file, cache_path = cache, verbose = FALSE)
    ))
  )

  # After the run the manifest should be valid JSON again with the new entry.
  recovered <- traning:::.load_manifest()
  expect_true("f.json" %in% names(recovered))
})

test_that(".compute_manifest_to_save: full run replaces, single-file merges", {
  # Three temp files; pretend we're considering all of them as candidates.
  a <- tempfile(fileext = ".json"); writeLines("{}", a)
  b <- tempfile(fileext = ".json"); writeLines("{}", b)
  c <- tempfile(fileext = ".json"); writeLines("{}", c)
  existing <- list("old_only.json" = list(md5 = "zzzz"))
  # A pre-existing entry for `a`. The full run should overwrite it with
  # the fresh md5; the single-file run should also overwrite it.
  existing[[basename(a)]] <- list(md5 = "stale")

  # Full run (path = NULL): manifest is replaced entirely. The stale entry
  # for `a` is replaced with its fresh md5; old_only.json disappears.
  res_full <- traning:::.compute_manifest_to_save(
    files = c(a, b, c), path = NULL, existing = existing
  )
  expect_false("old_only.json" %in% names(res_full))
  expect_true(all(c(basename(a), basename(b), basename(c)) %in% names(res_full)))
  expect_equal(res_full[[basename(a)]]$md5, unname(tools::md5sum(a)))

  # Single-file run: existing entries are preserved, only touched ones
  # overwritten. old_only.json must survive; the entry for `a` is
  # refreshed with the new md5.
  res_single <- traning:::.compute_manifest_to_save(
    files = a, path = a, existing = existing
  )
  expect_equal(res_single[["old_only.json"]]$md5, "zzzz")
  expect_equal(res_single[[basename(a)]]$md5, unname(tools::md5sum(a)))

  # Single-file run with a non-list `existing` (corrupt manifest) must
  # not crash — the merge proceeds against an empty base.
  res_corrupt <- traning:::.compute_manifest_to_save(
    files = a, path = a, existing = "this was the JSON content"
  )
  expect_true(basename(a) %in% names(res_corrupt))
})

# --- read_canonical_file daily_total fast-path ------------------------------

test_that("read_canonical_file uses daily_total fast path when present", {
  # Writer (Python storage.py) populates `daily_total` for sum metrics so
  # the reader can skip parsing 1000+ intra-day samples. Reader must
  # honor the precomputed value rather than re-summing the samples.
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp), add = TRUE)
  jsonlite::write_json(list(
    metric = "step_count",
    date = "2026-04-15",
    units = "count",
    daily_total = 12345,
    # Deliberately mismatched samples — the fast-path should NOT touch
    # these; if it does and re-aggregates, the test would see 999.
    samples = list(
      list(date = "2026-04-15 08:00:00 +0200", qty = 999, source = "AW")
    )
  ), tmp, auto_unbox = TRUE)
  result <- read_canonical_file(tmp)
  expect_equal(nrow(result), 1)
  expect_equal(result$value, 12345)
  expect_equal(result$metric, "step_count")
  expect_equal(result$source, "AW")
})

test_that("read_canonical_file aggregates sum-metric samples when daily_total missing", {
  # Older canonical files (pre-2026-05-11) have no daily_total. The
  # downstream import pipeline collapses (date, metric) with
  # distinct(.keep_all=TRUE), so the reader must hand it a single
  # pre-summed row — otherwise a 1100-sample day collapses to one
  # tiny intra-day reading instead of the true total.
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp), add = TRUE)
  jsonlite::write_json(list(
    metric = "step_count",
    date = "2026-04-15",
    units = "count",
    samples = list(
      list(date = "2026-04-15 08:00:00 +0200", qty = 7000, source = "AW"),
      list(date = "2026-04-15 17:00:00 +0200", qty = 3000, source = "AW")
    )
  ), tmp, auto_unbox = TRUE)
  result <- read_canonical_file(tmp)
  expect_equal(nrow(result), 1)
  expect_equal(result$metric[[1]], "step_count")
  expect_equal(result$value[[1]], 10000)
})

test_that("read_canonical_file ignores daily_total for non-sum metrics", {
  # The fast-path is gated on metric name. A daily_total field
  # accidentally present for an average-style metric must not be used —
  # summing HRV samples, for instance, would produce nonsense.
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp), add = TRUE)
  jsonlite::write_json(list(
    metric = "heart_rate_variability",
    date = "2026-04-15",
    units = "ms",
    daily_total = 99999,
    samples = list(
      list(date = "2026-04-15 08:00:00 +0200", qty = 55, source = "AW")
    )
  ), tmp, auto_unbox = TRUE)
  result <- read_canonical_file(tmp)
  expect_false(any(result$value == 99999))
})
