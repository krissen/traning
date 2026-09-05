# Alcohol: import-time derivation, energy, baseline and prose.
# Fixtures are inline tibbles, matching the pattern in
# test-health-export.R — no external JSON to keep in sync.

sample_row <- function(ts, qty, source = "DrinkControl", units = "count") {
  tibble::tibble(ts = traning:::.parse_hae_timestamp(ts), qty = qty,
                 source = source, units = units)
}

# A dense health_daily over `dates`, one row per metric per day.
fake_health <- function(dates, hrv = 52, rhr = 48, sleep = 7.5,
                         active = 3300, basal = 6700) {
  tibble::tibble(
    date = rep(dates, 5),
    metric = rep(c("heart_rate_variability", "resting_heart_rate",
                   "sleep_totalSleep", "active_energy",
                   "basal_energy_burned"), each = length(dates)),
    value = c(rep(hrv, length.out = length(dates)),
              rep(rhr, length.out = length(dates)),
              rep(sleep, length.out = length(dates)),
              rep(active, length.out = length(dates)),
              rep(basal, length.out = length(dates))),
    source = "AW"
  )
}

# A night table with zero drinks everywhere, ready to be poked.
fake_nights <- function(dates) {
  tibble::tibble(
    date = dates,
    alcohol_units = 0,
    alcohol_night_units = 0,
    alcohol_kcal = 0,
    alcohol_last_sample_time = as.POSIXct(NA, tz = "UTC"),
    alcohol_logging_active = TRUE
  )
}


# --- Taxonomy and import filter ---------------------------------------------

test_that("alcohol_consumption is a sum metric, imported, and tier 3", {
  expect_true("alcohol_consumption" %in% traning:::.sum_metrics)
  expect_true("alcohol_consumption" %in% traning:::.import_metrics)
  # Tier 3 is not optional: an unclassified metric defaults to tier 1,
  # which would fire a push for every logged drink.
  expect_true("alcohol_consumption" %in% traning:::.tier3_metrics)
  expect_false("alcohol_consumption" %in% traning:::.tier1_metrics)
  expect_false("alcohol_consumption" %in% names(traning:::.tier2_thresholds))
})

test_that("basal_energy_burned is imported so the share has a denominator", {
  expect_true("basal_energy_burned" %in% traning:::.import_metrics)
})

test_that("health_insight_delta stays silent about a new drink", {
  before <- tibble::tibble(date = as.Date("2026-09-05"),
                           metric = "alcohol_consumption",
                           value = 0, source = "DrinkControl")
  after <- tibble::tibble(date = as.Date("2026-09-05"),
                           metric = "alcohol_consumption",
                           value = 6, source = "DrinkControl")
  expect_equal(health_insight_delta(before, after), "")
})


# --- Timestamps and night attribution ---------------------------------------

test_that(".parse_hae_timestamp keeps wall-clock time and ignores the offset", {
  ts <- traning:::.parse_hae_timestamp("2026-09-05 18:44:00 +0200")
  expect_equal(format(ts, "%Y-%m-%d %H:%M"), "2026-09-05 18:44")

  # ISO 8601 with a T separator parses the same way.
  ts2 <- traning:::.parse_hae_timestamp("2026-09-05T18:44:00+02:00")
  expect_equal(ts, ts2)

  # Date-only strings land at midnight rather than dropping out as NA.
  ts3 <- traning:::.parse_hae_timestamp("2026-09-05")
  expect_equal(format(ts3, "%H:%M"), "00:00")
  expect_true(is.na(traning:::.parse_hae_timestamp("not a timestamp")))
})

test_that("nights run noon to noon and end on the following morning", {
  night <- function(x) traning:::.alcohol_night_date(
    traning:::.parse_hae_timestamp(x))
  expect_equal(night("2026-09-05 11:59:00"), as.Date("2026-09-05"))
  expect_equal(night("2026-09-05 12:00:00"), as.Date("2026-09-06"))
  expect_equal(night("2026-09-05 23:30:00"), as.Date("2026-09-06"))
  # A drink at 01:00 belongs to the night already under way, not the
  # one that follows it.
  expect_equal(night("2026-09-06 01:00:00"), as.Date("2026-09-06"))
})


# --- Night table -------------------------------------------------------------

test_that("build_alcohol_nights attributes an evening to the next morning", {
  s <- sample_row("2026-09-05 18:44:00 +0200", 6)
  n <- build_alcohol_nights(s)

  night <- n[n$date == as.Date("2026-09-06"), ]
  expect_equal(night$alcohol_night_units, 6)
  expect_equal(format(night$alcohol_last_sample_time, "%H:%M"), "18:44")

  # The calendar-day total stays on the day the drinks were logged, so a
  # per-day metric view and this table cannot disagree.
  day <- n[n$date == as.Date("2026-09-05"), ]
  expect_equal(day$alcohol_units, 6)
  expect_equal(day$alcohol_night_units, 0)
})

test_that("kcal comes only from DrinkControl's own dietary_energy samples", {
  s <- sample_row("2026-09-05 18:44:00 +0200", 6)
  e <- dplyr::bind_rows(
    sample_row("2026-09-05 18:44:00 +0200", 1768.3175, "DrinkControl", "kJ"),
    # A food logger writing dietary energy the same evening must not be
    # counted as alcohol energy.
    sample_row("2026-09-05 19:30:00 +0200", 4000, "MatLogg", "kJ")
  )
  n <- build_alcohol_nights(s, e)
  night <- n[n$date == as.Date("2026-09-06"), ]
  expect_equal(round(night$alcohol_kcal, 1), 422.6)
})

test_that("energy already in kcal is not converted a second time", {
  expect_equal(traning:::.energy_to_kcal(100, "kcal"), 100)
  expect_equal(round(traning:::.energy_to_kcal(418.4, "kJ"), 1), 100)
})

test_that("absence counts as zero only inside a logging-active stretch", {
  s <- sample_row("2026-09-05 18:44:00 +0200", 6)
  n <- build_alcohol_nights(s)

  near <- n[n$date == as.Date("2026-09-10"), ]
  expect_true(near$alcohol_logging_active)
  expect_equal(near$alcohol_night_units, 0)

  far <- n[n$date == as.Date("2026-09-16"), ]
  expect_false(far$alcohol_logging_active)
  expect_true(is.na(far$alcohol_night_units))
})

test_that("build_alcohol_nights survives empty input", {
  expect_equal(nrow(build_alcohol_nights(NULL)), 0)
  expect_equal(nrow(build_alcohol_nights(sample_row(NA_character_, NA_real_))), 0)
})


# --- Cache round trip --------------------------------------------------------

test_that("the alcohol cache round-trips and sits beside the health cache", {
  tmp <- withr::local_tempdir()
  health_cache <- file.path(tmp, "health_daily.RData")
  expect_equal(traning:::.alcohol_cache_path(health_cache),
               file.path(tmp, "alcohol_nights.RData"))

  nights <- build_alcohol_nights(sample_row("2026-09-05 18:44:00 +0200", 6))
  path <- traning:::.alcohol_cache_path(health_cache)
  save_alcohol_data(nights, path)
  expect_true(file.exists(path))
  expect_equal(load_alcohol_data(path), nights)
})

test_that("load_alcohol_data returns an empty table when no cache exists", {
  tmp <- withr::local_tempdir()
  out <- load_alcohol_data(file.path(tmp, "missing.RData"))
  expect_equal(nrow(out), 0)
  expect_true(all(c("date", "alcohol_night_units", "alcohol_kcal") %in%
                    names(out)))
})

test_that("import_alcohol reads canonical files and writes the cache", {
  tmp <- withr::local_tempdir()
  canonical <- file.path(tmp, "canonical")
  dir.create(file.path(canonical, "alcohol_consumption"), recursive = TRUE)
  dir.create(file.path(canonical, "dietary_energy"), recursive = TRUE)
  writeLines(
    '{"metric": "alcohol_consumption", "date": "2026-09-05", "units": "count", "samples": [{"source": "DrinkControl", "qty": 6, "date": "2026-09-05 18:44:00 +0200"}]}',
    file.path(canonical, "alcohol_consumption", "2026-09-05.json"))
  writeLines(
    '{"metric": "dietary_energy", "date": "2026-09-05", "units": "kJ", "samples": [{"source": "DrinkControl", "qty": 1768.3175, "date": "2026-09-05 18:44:00 +0200"}]}',
    file.path(canonical, "dietary_energy", "2026-09-05.json"))

  cache <- file.path(tmp, "alcohol_nights.RData")
  out <- import_alcohol(save = TRUE, cache_path = cache,
                        canonical_dir = canonical, verbose = FALSE)
  night <- out[out$date == as.Date("2026-09-06"), ]
  expect_equal(night$alcohol_night_units, 6)
  expect_equal(round(night$alcohol_kcal, 1), 422.6)
  expect_true(file.exists(cache))
})

test_that("a missing canonical directory is not an error", {
  tmp <- withr::local_tempdir()
  out <- import_alcohol(save = FALSE,
                        canonical_dir = file.path(tmp, "nope"),
                        verbose = FALSE)
  expect_equal(nrow(out), 0)
})


# --- Energy ------------------------------------------------------------------

test_that("standard drinks convert as count times ten grams over twelve", {
  a <- fake_nights(as.Date("2026-09-06"))
  a$alcohol_night_units <- 6
  a$alcohol_kcal <- 422.6
  out <- compute_alcohol_energy(a, NULL)
  expect_equal(out$alcohol_grams, 60)
  expect_equal(out$alcohol_standardglas, 5)
  # The sketch's "count times twelve grams" would have said 72 g.
  expect_false(isTRUE(all.equal(out$alcohol_grams, 72)))
})

test_that("grams per unit follows the option when the app setting changes", {
  withr::local_options(traning.alcohol_g_per_unit = 12)
  a <- fake_nights(as.Date("2026-09-06"))
  a$alcohol_night_units <- 6
  out <- compute_alcohol_energy(a, NULL)
  expect_equal(out$alcohol_grams, 72)
  expect_equal(out$alcohol_standardglas, 6)
})

test_that("fallback kcal is used only when the app wrote none, and is flagged", {
  a <- fake_nights(as.Date(c("2026-09-05", "2026-09-06")))
  a$alcohol_night_units <- c(4, 6)
  a$alcohol_kcal <- c(NA_real_, 422.6)
  out <- compute_alcohol_energy(a, NULL)

  expect_true(out$alcohol_kcal_estimated[1])
  expect_equal(out$alcohol_kcal[1], 4 * 10 * 7.1)
  expect_false(out$alcohol_kcal_estimated[2])
  expect_equal(out$alcohol_kcal[2], 422.6)
})

test_that("the share is a fraction of the 28-day mean expenditure", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a$alcohol_night_units[a$date == as.Date("2026-09-06")] <- 6
  a$alcohol_kcal[a$date == as.Date("2026-09-06")] <- 422.6

  out <- compute_alcohol_energy(a, hd)
  row <- out[out$date == as.Date("2026-09-06"), ]
  # (3300 + 6700) kJ / 4.184 = 2390 kcal
  expect_equal(round(row$tdee_kcal_28d), 2390)
  expect_equal(round(row$alcohol_share, 3), round(422.6 / 2390.057, 3))
})

test_that("a thin expenditure window omits the share rather than guessing", {
  dates <- seq(as.Date("2026-09-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a$alcohol_night_units[a$date == as.Date("2026-09-06")] <- 6
  a$alcohol_kcal[a$date == as.Date("2026-09-06")] <- 422.6

  out <- compute_alcohol_energy(a, hd)
  expect_true(is.na(out$alcohol_share[out$date == as.Date("2026-09-06")]))
})

test_that("a day with only active energy is left out of the denominator", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  hd <- hd[!(hd$metric == "basal_energy_burned" &
               hd$date == as.Date("2026-09-01")), ]
  e <- traning:::.alcohol_daily_energy(hd)
  expect_false(as.Date("2026-09-01") %in% e$date)
})

test_that("an implausible daily total is dropped from the denominator", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  hd$value[hd$metric == "active_energy" &
             hd$date == as.Date("2026-09-01")] <- 500000
  e <- traning:::.alcohol_daily_energy(hd)
  expect_false(as.Date("2026-09-01") %in% e$date)
})

test_that("the share is suppressed when a Garmin day has rest-level energy", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  # Give active energy a spread so the 90th percentile is meaningful,
  # and leave the drinking day at rest level despite a logged session.
  hd$value[hd$metric == "active_energy"] <- rep(c(3000, 9000),
                                                 length.out = length(dates))
  hd$value[hd$metric == "active_energy" &
             hd$date == as.Date("2026-09-06")] <- 1500

  a <- fake_nights(dates)
  a$alcohol_night_units[a$date == as.Date("2026-09-06")] <- 6
  a$alcohol_kcal[a$date == as.Date("2026-09-06")] <- 422.6
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-09-06 10:00:00", tz = "UTC"))

  with_session <- compute_alcohol_energy(a, hd, summaries)
  without <- compute_alcohol_energy(a, hd, NULL)
  expect_true(is.na(with_session$alcohol_share[
    with_session$date == as.Date("2026-09-06")]))
  expect_true(is.finite(without$alcohol_share[
    without$date == as.Date("2026-09-06")]))
})


# --- Weekly ------------------------------------------------------------------

test_that("the weekly summary counts evenings, dry days and its own share", {
  dates <- seq(as.Date("2026-08-31"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a$alcohol_night_units[a$date %in% as.Date(c("2026-09-05", "2026-09-06"))] <-
    c(3, 6)
  a$alcohol_kcal[a$date %in% as.Date(c("2026-09-05", "2026-09-06"))] <-
    c(210, 422.6)

  w <- compute_alcohol_week(a, hd)
  expect_equal(nrow(w), 1)
  expect_equal(w$iso_week, "2026-W36")
  expect_equal(w$drinking_days, 2L)
  expect_equal(w$dry_days, 5L)
  expect_equal(round(w$kcal, 1), 632.6)
  # Seven days of expenditure at 2390 kcal.
  expect_equal(round(w$share, 4), round(632.6 / (7 * 2390.057), 4))
})

test_that("a week with too few expenditure days reports no share", {
  dates <- seq(as.Date("2026-08-31"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates[1:3])
  a <- fake_nights(dates)
  a$alcohol_night_units[a$date == as.Date("2026-09-06")] <- 6
  a$alcohol_kcal[a$date == as.Date("2026-09-06")] <- 422.6

  w <- compute_alcohol_week(a, hd)
  expect_true(is.na(w$share))
  expect_equal(w$drinking_days, 1L)
})

test_that("nights outside a logging-active stretch never reach the weekly table", {
  dates <- seq(as.Date("2026-08-31"), as.Date("2026-09-06"), by = "day")
  a <- fake_nights(dates)
  a$alcohol_logging_active <- FALSE
  a$alcohol_night_units <- NA_real_
  expect_equal(nrow(compute_alcohol_week(a, NULL)), 0)
})


# --- Baseline and deviation --------------------------------------------------

test_that("the baseline uses alcohol-free nights only and needs 14 of them", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  # Drinking nights carry a much lower HRV; if they leaked into the
  # baseline the median would move.
  drink_nights <- as.Date(c("2026-09-04", "2026-09-05"))
  hd$value[hd$metric == "heart_rate_variability" &
             hd$date %in% drink_nights] <- 20

  a <- fake_nights(dates)
  a$alcohol_night_units[a$date %in% drink_nights] <- 4

  b <- compute_alcohol_baseline(hd, a, on_date = as.Date("2026-09-06"))
  expect_equal(b$hrv$center, 52)
  expect_true(b$n_nights >= 14)

  # Too few qualifying nights: nothing is reported rather than a thin
  # reference being reported as if it were solid.
  short <- fake_nights(seq(as.Date("2026-09-01"), as.Date("2026-09-06"),
                            by = "day"))
  b2 <- compute_alcohol_baseline(hd, short, on_date = as.Date("2026-09-06"))
  expect_true(is.na(b2$hrv$center))
  expect_lt(b2$n_nights, 14)
})

test_that("illness-flagged days are excluded from the baseline", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  wt <- tibble::tibble(date = dates,
                       metric = "apple_sleeping_wrist_temperature",
                       value = 36.5, source = "AW")
  fever <- as.Date("2026-09-01")
  wt$value[wt$date == fever] <- 37.4
  hd <- dplyr::bind_rows(hd, wt)

  expect_true(fever %in% traning:::.alcohol_illness_dates(hd))

  a <- fake_nights(dates)
  b_all <- compute_alcohol_baseline(hd, a, on_date = as.Date("2026-09-06"))
  b_no_wt <- compute_alcohol_baseline(fake_health(dates), a,
                                       on_date = as.Date("2026-09-06"))
  expect_equal(b_all$n_nights, b_no_wt$n_nights - 1L)
})

test_that("deviation flags an adverse move and stays quiet on a normal one", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  set.seed(11)
  hd <- fake_health(dates)
  hrv_idx <- hd$metric == "heart_rate_variability"
  hd$value[hrv_idx] <- round(stats::rnorm(sum(hrv_idx), 52, 4), 1)
  rhr_idx <- hd$metric == "resting_heart_rate"
  hd$value[rhr_idx] <- round(stats::rnorm(sum(rhr_idx), 48, 1.5))

  a <- fake_nights(dates)
  on_date <- as.Date("2026-09-06")

  quiet <- compute_alcohol_deviation(hd, a, on_date = on_date)
  expect_setequal(quiet$measure, c("hrv", "rhr", "sleep"))
  expect_false(any(quiet$flagged))

  hd$value[hrv_idx & hd$date == on_date] <- 30
  hd$value[rhr_idx & hd$date == on_date] <- 56
  loud <- compute_alcohol_deviation(hd, a, on_date = on_date)
  expect_true(loud$flagged[loud$measure == "hrv"])
  expect_true(loud$flagged[loud$measure == "rhr"])
  expect_lt(loud$delta[loud$measure == "hrv"], 0)
  expect_gt(loud$delta[loud$measure == "rhr"], 0)
})

test_that("a measure with no reading is dropped, not carried as a placeholder", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  hd <- hd[!(hd$metric == "sleep_totalSleep" &
               hd$date == as.Date("2026-09-06")), ]
  a <- fake_nights(dates)
  dev <- compute_alcohol_deviation(hd, a, on_date = as.Date("2026-09-06"))
  expect_false("sleep" %in% dev$measure)
  expect_true("hrv" %in% dev$measure)
})


# --- Prose -------------------------------------------------------------------

alcohol_fixture <- function(on_date = as.Date("2026-09-06"), units = 6,
                            kcal = 422.6) {
  dates <- seq(on_date - 40, on_date, by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a$alcohol_night_units[a$date == on_date] <- units
  a$alcohol_kcal[a$date == on_date] <- kcal
  list(health_daily = hd, alcohol = a, on_date = on_date)
}

test_that("the daily line reports drinks, energy and share", {
  f <- alcohol_fixture()
  line <- traning:::.insight_alcohol_line(f$alcohol, f$health_daily, f$on_date)
  expect_match(line, "6 glas")
  expect_match(line, "5 standardglas")
  expect_match(line, "423 kcal")
  expect_match(line, "18 procent")
  # No imperative, ever.
  expect_false(grepl("bör|ta det lugnt|kompensera", line))
})

test_that("the daily line is silent on a dry night", {
  f <- alcohol_fixture()
  expect_null(traning:::.insight_alcohol_line(f$alcohol, f$health_daily,
                                               f$on_date - 1))
})

test_that("the daily line is silent outside a logging-active stretch", {
  f <- alcohol_fixture()
  f$alcohol$alcohol_logging_active <- FALSE
  expect_null(traning:::.insight_alcohol_line(f$alcohol, f$health_daily,
                                               f$on_date))
})

test_that("an honest null is stated when nothing moved", {
  f <- alcohol_fixture()
  line <- traning:::.insight_alcohol_line(f$alcohol, f$health_daily, f$on_date)
  expect_match(line, "normala niv")
  expect_false(grepl("\\?", line))
})

test_that("a flagged measure replaces the null statement", {
  f <- alcohol_fixture()
  hd <- f$health_daily
  hd$value[hd$metric == "heart_rate_variability"] <-
    round(stats::rnorm(sum(hd$metric == "heart_rate_variability"), 52, 4), 1)
  hd$value[hd$metric == "heart_rate_variability" & hd$date == f$on_date] <- 30
  line <- traning:::.insight_alcohol_line(f$alcohol, hd, f$on_date)
  expect_match(line, "HRV 30 ms mot")
  expect_false(grepl("normala niv", line))
})

test_that("a computed kcal figure is labelled as computed", {
  f <- alcohol_fixture(kcal = NA_real_)
  line <- traning:::.insight_alcohol_line(f$alcohol, f$health_daily, f$on_date)
  expect_match(line, "426 kcal från alkoholen \\(beräknat\\)")
})

test_that("the weekly line runs on Monday only and only with drinks in it", {
  monday <- as.Date("2026-09-07")
  dates <- seq(monday - 40, monday, by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a$alcohol_night_units[a$date == as.Date("2026-09-05")] <- 6
  a$alcohol_kcal[a$date == as.Date("2026-09-05")] <- 422.6

  expect_equal(as.POSIXlt(monday)$wday, 1L)
  line <- traning:::.alcohol_weekly_line(a, hd, monday)
  expect_match(line, "Förra veckan")
  expect_match(line, "423 kcal")
  expect_match(line, "1 kväll\\.")

  # Any other weekday, and a week with no drinks, stay silent.
  expect_null(traning:::.alcohol_weekly_line(a, hd, monday + 1))
  dry <- fake_nights(dates)
  expect_null(traning:::.alcohol_weekly_line(dry, hd, monday))
})

test_that("alcohol is the lowest-priority context line", {
  f <- alcohol_fixture()
  hd <- f$health_daily
  # A steep HRV downtrend over the last week: that line must win.
  window <- hd$metric == "heart_rate_variability" &
    hd$date > f$on_date - 7
  hd$value[window] <- seq(60, 40, length.out = sum(window))

  line <- traning:::.insight_context_line(NULL, hd, f$on_date,
                                           alcohol = f$alcohol)
  expect_match(line, "HRV sjunkande trend")

  # With no downtrend, the alcohol line is reached.
  line2 <- traning:::.insight_context_line(NULL, f$health_daily, f$on_date,
                                            alcohol = f$alcohol)
  expect_match(line2, "glas")
})

test_that("the context chain is unchanged when no alcohol table exists", {
  f <- alcohol_fixture()
  expect_null(traning:::.insight_context_line(NULL, f$health_daily,
                                               f$on_date, alcohol = NULL))
})


# --- Reports -----------------------------------------------------------------

test_that("report_alcohol returns Swedish columns, newest first", {
  f <- alcohol_fixture()
  td <- traning_data(
    summaries = data.frame(sessionStart = as.POSIXct("2026-09-01 10:00:00",
                                                      tz = "UTC")),
    health_daily = f$health_daily
  )
  out <- report_alcohol(td, after = "2026-09-01", alcohol = f$alcohol)
  expect_true(all(c("Datum", "Glas", "Standardglas", "kcal", "Andel %",
                    "HRV avvik", "VP avvik") %in% names(out)))
  expect_equal(out$Datum, sort(out$Datum, decreasing = TRUE))
  expect_equal(out$Glas[out$Datum == f$on_date], 6)
  expect_equal(out$Standardglas[out$Datum == f$on_date], 5)
})

test_that("report_alcohol_weekly aggregates by ISO week, newest first", {
  f <- alcohol_fixture()
  td <- traning_data(summaries = data.frame(sessionStart = as.POSIXct(NA)),
                     health_daily = f$health_daily)
  out <- report_alcohol_weekly(td, alcohol = f$alcohol)
  expect_true(all(c("Vecka", "Start", "Glas", "kcal", "Kvällar") %in%
                    names(out)))
  expect_equal(out$Start, sort(out$Start, decreasing = TRUE))
  expect_equal(sum(out$Kvällar), 1L)
})

test_that("the reports degrade to an empty table without alcohol data", {
  td <- traning_data(summaries = data.frame(sessionStart = as.POSIXct(NA)),
                     health_daily = fake_health(as.Date("2026-09-06")))
  empty <- traning:::.empty_alcohol_nights()
  expect_equal(nrow(report_alcohol(td, alcohol = empty)), 0)
  expect_equal(nrow(report_alcohol_weekly(td, alcohol = empty)), 0)
})
