# Alcohol: import-time derivation, energy, baseline and prose.
# Fixtures are inline tibbles, matching the pattern in
# test-health-export.R — no external JSON to keep in sync.

sample_row <- function(date, qty, source = "DrinkControl",
                        units = "count") {
  tibble::tibble(date = as.Date(date), qty = qty, source = source,
                 units = units)
}

# 1768.3175 kJ is 422.6 kcal, which at 7 kcal/g is 60.4 g of ethanol —
# the real DrinkControl figures for 2026-09-05.
kj_for_six_drinks <- 1768.3175

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
    alcohol_grams = 0,
    alcohol_grams_estimated = FALSE,
    alcohol_g_per_unit = NA_real_,
    alcohol_unit_mismatch = FALSE,
    alcohol_logging_active = TRUE
  )
}

# Set the derived columns for one night the way build_alcohol_nights
# would, so query-side fixtures cannot drift from the import shape.
set_night <- function(a, date, units, kcal = NULL) {
  i <- a$date == date
  a$alcohol_night_units[i] <- units
  if (is.null(kcal)) {
    a$alcohol_kcal[i] <- NA_real_
    a$alcohol_grams[i] <- units * 10
    a$alcohol_grams_estimated[i] <- TRUE
  } else {
    a$alcohol_kcal[i] <- kcal
    a$alcohol_grams[i] <- kcal / 7
  }
  a$alcohol_g_per_unit[i] <- a$alcohol_grams[i] / units
  a
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

test_that("a day's drinking is attributed to the following morning", {
  expect_equal(traning:::.alcohol_night_date(as.Date("2026-09-05")),
               as.Date("2026-09-06"))
  expect_equal(traning:::.alcohol_night_date(as.Date(c("2026-01-01",
                                                        "2026-12-31"))),
               as.Date(c("2026-01-02", "2027-01-01")))
})

test_that("the canonical document date wins over the export timestamp", {
  tmp <- withr::local_tempdir()
  dir.create(file.path(tmp, "alcohol_consumption"))
  # The sample timestamp is when the export ran, and it can fall on a
  # different day than the one the metric is for.
  writeLines(
    '{"metric": "alcohol_consumption", "date": "2026-09-05", "units": "count", "samples": [{"source": "DrinkControl", "qty": 6, "date": "2026-09-06 09:12:00 +0200"}]}',
    file.path(tmp, "alcohol_consumption", "2026-09-05.json"))
  out <- traning:::.read_canonical_samples(file.path(tmp,
                                                     "alcohol_consumption"))
  expect_equal(out$date, as.Date("2026-09-05"))
})

# --- Night table -------------------------------------------------------------

test_that("build_alcohol_nights attributes an evening to the next morning", {
  n <- build_alcohol_nights(sample_row("2026-09-05", 6))

  night <- n[n$date == as.Date("2026-09-06"), ]
  expect_equal(night$alcohol_night_units, 6)

  # The calendar-day total stays on the day the drinks were logged, so a
  # per-day metric view and this table cannot disagree.
  day <- n[n$date == as.Date("2026-09-05"), ]
  expect_equal(day$alcohol_units, 6)
  expect_equal(day$alcohol_night_units, 0)
})

test_that("grams come from the app's energy, not from the count", {
  n <- build_alcohol_nights(
    sample_row("2026-09-05", 6),
    sample_row("2026-09-05", kj_for_six_drinks, "DrinkControl", "kJ"))
  night <- n[n$date == as.Date("2026-09-06"), ]

  expect_equal(round(night$alcohol_grams, 1), 60.4)
  expect_false(night$alcohol_grams_estimated)
  # grams / count recovers DrinkControl's own unit setting.
  expect_equal(round(night$alcohol_g_per_unit, 1), 10.1)
  expect_false(night$alcohol_unit_mismatch)
})

test_that("a night without app energy falls back to ten grams, flagged", {
  n <- build_alcohol_nights(sample_row("2026-09-05", 4))
  night <- n[n$date == as.Date("2026-09-06"), ]
  expect_equal(night$alcohol_grams, 40)
  expect_true(night$alcohol_grams_estimated)
  # A fallback figure cannot disagree with the constant it was built
  # from, so it is never reported as a unit mismatch.
  expect_false(night$alcohol_unit_mismatch)
})

test_that("a changed unit setting is flagged rather than swallowed", {
  # 14 g units (the US setting) against an assumed 10: the energy says
  # 84 g for six drinks, so grams per unit lands at 14.
  n <- build_alcohol_nights(
    sample_row("2026-09-05", 6),
    sample_row("2026-09-05", 84 * 7 * 4.184, "DrinkControl", "kJ"))
  night <- n[n$date == as.Date("2026-09-06"), ]
  expect_equal(round(night$alcohol_g_per_unit), 14)
  expect_true(night$alcohol_unit_mismatch)
})

test_that("import_alcohol says so out loud when the unit setting drifts", {
  tmp <- withr::local_tempdir()
  dir.create(file.path(tmp, "alcohol_consumption"), recursive = TRUE)
  dir.create(file.path(tmp, "dietary_energy"), recursive = TRUE)
  writeLines(
    '{"metric": "alcohol_consumption", "date": "2026-09-05", "units": "count", "samples": [{"source": "DrinkControl", "qty": 6, "date": "2026-09-05 18:44:00 +0200"}]}',
    file.path(tmp, "alcohol_consumption", "2026-09-05.json"))
  writeLines(
    sprintf('{"metric": "dietary_energy", "date": "2026-09-05", "units": "kJ", "samples": [{"source": "DrinkControl", "qty": %f, "date": "2026-09-05 18:44:00 +0200"}]}',
            84 * 7 * 4.184),
    file.path(tmp, "dietary_energy", "2026-09-05.json"))
  expect_message(
    import_alcohol(save = FALSE, canonical_dir = tmp, verbose = FALSE),
    "avvikande gram per glas"
  )
})

test_that("kcal comes only from DrinkControl's own dietary_energy samples", {
  s <- sample_row("2026-09-05", 6)
  e <- dplyr::bind_rows(
    sample_row("2026-09-05", kj_for_six_drinks, "DrinkControl", "kJ"),
    # A food logger writing dietary energy the same day must not be
    # counted as alcohol energy.
    sample_row("2026-09-05", 4000, "MatLogg", "kJ")
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
  n <- build_alcohol_nights(sample_row("2026-09-05", 6),
                             today = as.Date("2026-09-20"))

  near <- n[n$date == as.Date("2026-09-10"), ]
  expect_true(near$alcohol_logging_active)
  expect_equal(near$alcohol_night_units, 0)

  far <- n[n$date == as.Date("2026-09-16"), ]
  expect_false(far$alcohol_logging_active)
  expect_true(is.na(far$alcohol_night_units))
})

test_that("the table never runs past today", {
  # The active window pads ten days past the last sample. Left alone,
  # that manufactured future mornings with zero drinks and a
  # logging-active flag, and the weekly report then announced seven
  # alcohol-free days in a week that had not happened.
  n <- build_alcohol_nights(sample_row("2026-09-05", 6),
                             today = as.Date("2026-09-08"))
  expect_equal(max(n$date), as.Date("2026-09-08"))
  expect_false(any(n$date > as.Date("2026-09-08")))

  # But the morning after the last logged day is real data and stays,
  # even when that morning is tomorrow.
  today_run <- build_alcohol_nights(sample_row("2026-09-05", 6),
                                     today = as.Date("2026-09-05"))
  expect_equal(max(today_run$date), as.Date("2026-09-06"))
  expect_equal(today_run$alcohol_night_units[
    today_run$date == as.Date("2026-09-06")], 6)
})

test_that("no future week reaches the weekly report", {
  n <- build_alcohol_nights(sample_row("2026-09-05", 6),
                             today = as.Date("2026-09-08"))
  w <- compute_alcohol_week(n, NULL)
  expect_false(any(w$week_start > as.Date("2026-09-08")))
  expect_false("2026-W38" %in% w$iso_week)
})

test_that("build_alcohol_nights survives empty input", {
  expect_equal(nrow(build_alcohol_nights(NULL)), 0)
  expect_equal(nrow(build_alcohol_nights(sample_row(NA, NA_real_))), 0)
})


# --- Cache round trip --------------------------------------------------------

test_that("the alcohol cache round-trips and sits beside the health cache", {
  tmp <- withr::local_tempdir()
  health_cache <- file.path(tmp, "health_daily.RData")
  expect_equal(traning:::.alcohol_cache_path(health_cache),
               file.path(tmp, "alcohol_nights.RData"))

  nights <- build_alcohol_nights(sample_row("2026-09-05", 6))
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

test_that("the real DrinkControl export lands on the expected night", {
  # The one live canonical day, used as a fixture in place rather than
  # copied into the repo: it is a personal record and this repo is
  # public. Skips where the data repo is not present.
  root <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  skip_if(is.na(root), "TRANING_DATA is not set")
  canonical <- file.path(root, "kristian", "health_export", "canonical")
  skip_if_not(file.exists(file.path(canonical, "alcohol_consumption",
                                     "2026-09-05.json")),
              "no live canonical alcohol file")

  out <- import_alcohol(save = FALSE, canonical_dir = canonical,
                        verbose = FALSE)
  night <- out[out$date == as.Date("2026-09-06"), ]
  expect_equal(round(night$alcohol_night_units), 6)
  expect_equal(round(night$alcohol_kcal, 1), 422.6)
  expect_equal(round(night$alcohol_grams, 1), 60.4)
  expect_equal(round(night$alcohol_g_per_unit, 1), 10.1)
  expect_false(night$alcohol_unit_mismatch)
})

test_that("a missing canonical directory is not an error", {
  tmp <- withr::local_tempdir()
  out <- import_alcohol(save = FALSE,
                        canonical_dir = file.path(tmp, "nope"),
                        verbose = FALSE)
  expect_equal(nrow(out), 0)
})


# --- Energy ------------------------------------------------------------------

test_that("standardglas is grams over twelve, not the raw count", {
  a <- set_night(fake_nights(as.Date("2026-09-06")), as.Date("2026-09-06"),
                 units = 6, kcal = 422.6)
  out <- compute_alcohol_energy(a, NULL)
  expect_equal(round(out$alcohol_grams, 1), 60.4)
  expect_equal(round(out$alcohol_standardglas, 2), round(60.4 / 12, 2))
  # Multiplying the count by twelve grams would have said 72 g, nearly a
  # fifth too much for a count denominated in ten-gram units.
  expect_false(isTRUE(all.equal(round(out$alcohol_grams), 72)))
})

test_that("the fallback constant follows the option, at import", {
  withr::local_options(traning.alcohol_g_per_unit = 14)
  n <- build_alcohol_nights(sample_row("2026-09-05", 6))
  night <- n[n$date == as.Date("2026-09-06"), ]
  expect_equal(night$alcohol_grams, 84)
  expect_true(night$alcohol_grams_estimated)
})

test_that("fallback kcal is used only when the app wrote none, and is flagged", {
  a <- fake_nights(as.Date(c("2026-09-05", "2026-09-06")))
  a <- set_night(a, as.Date("2026-09-05"), units = 4)
  a <- set_night(a, as.Date("2026-09-06"), units = 6, kcal = 422.6)
  out <- compute_alcohol_energy(a, NULL)

  expect_true(out$alcohol_kcal_estimated[1])
  expect_equal(out$alcohol_kcal[1], 4 * 10 * 7)
  expect_false(out$alcohol_kcal_estimated[2])
  expect_equal(out$alcohol_kcal[2], 422.6)
})

test_that("the share is a fraction of the 28-day mean expenditure", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a <- set_night(a, as.Date("2026-09-06"), units = 6, kcal = 422.6)

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
  a <- set_night(a, as.Date("2026-09-06"), units = 6, kcal = 422.6)

  out <- compute_alcohol_energy(a, hd)
  expect_true(is.na(out$alcohol_share[out$date == as.Date("2026-09-06")]))
})

test_that("the expenditure metrics' units travel with the alcohol table", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  # A device writing kcal, on a hard training day: 1500 + 3000 is a
  # 4500 kcal day. Divided by 4.184 on the assumption of kilojoules it
  # lands at 1076, INSIDE the plausibility band, so the band cannot catch
  # it and every share built on it is wrong by a factor of four.
  hd <- fake_health(dates, active = 1500, basal = 3000)

  as_kj <- traning:::.alcohol_daily_energy(hd)
  expect_equal(round(as_kj$tdee_kcal[1]), 1076)

  as_kcal <- traning:::.alcohol_daily_energy(
    hd, NULL, c(active_energy = "kcal", basal_energy_burned = "kcal"))
  expect_equal(round(as_kcal$tdee_kcal[1]), 4500)

  # Unknown units fall back to kilojoules, which is what this device
  # writes.
  expect_equal(traning:::.metric_energy_unit(NULL, "active_energy"), "kJ")
  expect_equal(traning:::.metric_energy_unit(c(active_energy = NA_character_),
                                              "active_energy"), "kJ")
})

test_that("import records the units and they survive the cache round trip", {
  tmp <- withr::local_tempdir()
  dir.create(file.path(tmp, "alcohol_consumption"), recursive = TRUE)
  dir.create(file.path(tmp, "active_energy"), recursive = TRUE)
  writeLines(
    '{"metric": "alcohol_consumption", "date": "2026-09-05", "units": "count", "samples": [{"source": "DrinkControl", "qty": 6, "date": "2026-09-05 18:44:00 +0200"}]}',
    file.path(tmp, "alcohol_consumption", "2026-09-05.json"))
  writeLines(
    '{"metric": "active_energy", "date": "2026-09-05", "units": "kJ", "samples": [{"source": "AW", "qty": 3300, "date": "2026-09-05 18:44:00 +0200"}]}',
    file.path(tmp, "active_energy", "2026-09-05.json"))

  cache <- file.path(tmp, "alcohol_nights.RData")
  n <- import_alcohol(save = TRUE, cache_path = cache, canonical_dir = tmp,
                      verbose = FALSE, today = as.Date("2026-09-06"))
  expect_equal(unname(attr(n, "energy_units")[["active_energy"]]), "kJ")
  # basal_energy_burned has no canonical directory here, so its unit is
  # unknown rather than assumed.
  expect_true(is.na(attr(n, "energy_units")[["basal_energy_burned"]]))
  expect_equal(attr(load_alcohol_data(cache), "energy_units"),
               attr(n, "energy_units"))
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

test_that("a contaminated day is dropped from the expenditure pool", {
  # A Garmin session with rest-level watch energy means the watch was
  # not worn for it. The day is removed from the pool that feeds the
  # 28-day mean, rather than suppressing the output of whichever night
  # happens to share its date.
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  hd$value[hd$metric == "active_energy"] <- rep(c(3000, 9000),
                                                 length.out = length(dates))
  bad_day <- as.Date("2026-09-01")
  hd$value[hd$metric == "active_energy" & hd$date == bad_day] <- 1500
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-09-01 10:00:00", tz = "UTC"))

  pool_all <- traning:::.alcohol_daily_energy(hd, NULL)
  pool_clean <- traning:::.alcohol_daily_energy(hd, summaries)
  expect_true(bad_day %in% pool_all$date)
  expect_false(bad_day %in% pool_clean$date)
  # Only that day goes; the rest of the window is untouched.
  expect_equal(nrow(pool_clean), nrow(pool_all) - 1)
})

test_that("the daily and weekly shares use the same expenditure pool", {
  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  hd$value[hd$metric == "active_energy"] <- rep(c(3000, 9000),
                                                 length.out = length(dates))
  hd$value[hd$metric == "active_energy" &
             hd$date == as.Date("2026-09-01")] <- 1500
  summaries <- data.frame(
    sessionStart = as.POSIXct("2026-09-01 10:00:00", tz = "UTC"))

  a <- fake_nights(dates)
  a <- set_night(a, as.Date("2026-09-06"), units = 6, kcal = 422.6)

  daily_with <- compute_alcohol_energy(a, hd, summaries)
  daily_without <- compute_alcohol_energy(a, hd, NULL)
  row <- daily_with$date == as.Date("2026-09-06")
  # Dropping a low-energy day raises the mean rather than blanking the
  # share: the night itself is still reportable.
  expect_true(is.finite(daily_with$tdee_kcal_28d[row]))
  expect_gt(daily_with$tdee_kcal_28d[row], daily_without$tdee_kcal_28d[row])
  expect_true(is.finite(daily_with$alcohol_share[row]))

  week_with <- compute_alcohol_week(a, hd, summaries)
  week_without <- compute_alcohol_week(a, hd, NULL)
  wk <- "2026-W36"
  expect_lt(week_with$week_tdee_kcal[week_with$iso_week == wk],
            week_without$week_tdee_kcal[week_without$iso_week == wk])
})


# --- Weekly ------------------------------------------------------------------

test_that("the weekly summary counts evenings, dry days and its own share", {
  # The night table is keyed by MORNINGS, so a week of evenings runs
  # Tuesday morning to the following Monday morning. Expenditure is
  # keyed by the calendar day, which is the drinking day.
  mornings <- seq(as.Date("2026-09-01"), as.Date("2026-09-07"), by = "day")
  drink_days <- seq(as.Date("2026-08-31"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(drink_days)
  a <- fake_nights(mornings)
  a <- set_night(a, as.Date("2026-09-05"), units = 3, kcal = 210)
  a <- set_night(a, as.Date("2026-09-06"), units = 6, kcal = 422.6)

  w <- compute_alcohol_week(a, hd)
  expect_equal(nrow(w), 1)
  expect_equal(w$iso_week, "2026-W36")
  expect_equal(w$week_start, as.Date("2026-08-31"))
  expect_equal(w$drinking_days, 2L)
  expect_equal(w$dry_days, 5L)
  expect_equal(round(w$kcal, 1), 632.6)
  # Seven days of expenditure at 2390 kcal.
  expect_equal(round(w$share, 4), round(632.6 / (7 * 2390.057), 4))
})

test_that("a Sunday evening lands in the week it happened in", {
  # The night is attributed to Monday morning, which is the NEXT ISO
  # week. Grouping on the morning dropped a Sunday-evening session out of
  # the recap of its own week and moved it into a week the Monday recap
  # had already reported.
  sunday <- as.Date("2026-09-06")
  expect_equal(as.POSIXlt(sunday)$wday, 0L)
  expect_equal(format(sunday, "%G-W%V"), "2026-W36")
  expect_equal(format(sunday + 1, "%G-W%V"), "2026-W37")

  n <- build_alcohol_nights(sample_row(sunday, 4),
                             today = as.Date("2026-09-10"))
  w <- compute_alcohol_week(n, NULL)
  hit <- w[w$units > 0, ]
  expect_equal(nrow(hit), 1)
  expect_equal(hit$iso_week, "2026-W36")
  expect_equal(hit$drinking_days, 1L)
  # And the week it was wrongly landing in reports nothing.
  expect_equal(w$drinking_days[w$iso_week == "2026-W37"], 0L)
})

test_that("the Monday recap covers the week that just ended", {
  monday <- as.Date("2026-09-07")
  dates <- seq(monday - 40, monday, by = "day")
  a <- fake_nights(dates)
  a <- set_night(a, as.Date("2026-09-07"), units = 4, kcal = 280)  # Sun eve
  line <- traning:::.alcohol_weekly_line(a, fake_health(dates), monday)
  expect_match(line, "1 kväll\\.")
})

test_that("a week with too few expenditure days reports no share", {
  mornings <- seq(as.Date("2026-09-01"), as.Date("2026-09-07"), by = "day")
  hd <- fake_health(seq(as.Date("2026-08-31"), as.Date("2026-09-02"),
                         by = "day"))
  a <- fake_nights(mornings)
  a <- set_night(a, as.Date("2026-09-06"), units = 6, kcal = 422.6)

  w <- compute_alcohol_week(a, hd)
  expect_equal(nrow(w), 1)
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
  for (d in drink_nights) a <- set_night(a, d, units = 4)

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

test_that("the thin-baseline return still carries its gate fields", {
  a <- fake_nights(seq(as.Date("2026-09-01"), as.Date("2026-09-06"),
                        by = "day"))
  hd <- fake_health(seq(as.Date("2026-09-01"), as.Date("2026-09-06"),
                         by = "day"))
  b <- compute_alcohol_baseline(hd, a, on_date = as.Date("2026-09-06"))
  expect_lt(b$n_nights, 14)
  for (nm in names(traning:::.alcohol_measures)) {
    expect_true(all(c("center", "spread", "n", "gate_center", "gate_spread")
                    %in% names(b[[nm]])))
  }
})

test_that("measures are ordered by standardized effect size", {
  # Grosicki et al. (2026): resting heart rate 0.61/0.52 per drink above
  # personal average, HRV 0.30/0.26. Resting heart rate leads.
  expect_equal(names(traning:::.alcohol_measures), c("rhr", "hrv", "sleep"))

  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  dev <- compute_alcohol_deviation(hd, a, on_date = as.Date("2026-09-06"))
  expect_equal(dev$measure, c("rhr", "hrv", "sleep"))
})

test_that("ethanol energy uses 7 kcal per gram, not 7.1", {
  # EU 1169/2011 and DrinkControl's own documentation both use 7. An
  # earlier draft used 7.1, which shifts every gram figure by 1.4 %.
  expect_equal(traning:::.alcohol_kcal_per_g, 7)
})

test_that("a morning one robust SD out does not clear the gate", {
  # Pins the null branch. At the old threshold of 1 this fired on about
  # 40 % of ordinary mornings across three measures, which turned the
  # recovery sentence into an accusation hunting for evidence.
  expect_equal(traning:::.alcohol_deviation_z, 1.5)

  dates <- seq(as.Date("2026-08-01"), as.Date("2026-09-06"), by = "day")
  on_date <- as.Date("2026-09-06")
  hd <- fake_health(dates)
  # A resting-heart-rate series with a known robust spread: alternating
  # 47/49 gives a median of 48 and a MAD of 1 * 1.4826.
  rhr <- hd$metric == "resting_heart_rate"
  hd$value[rhr] <- rep(c(47, 49), length.out = sum(rhr))
  a <- fake_nights(dates)

  b <- compute_alcohol_baseline(hd, a, on_date = on_date)
  spread <- b$rhr$gate_spread
  expect_true(is.finite(spread))

  one_sd <- hd
  one_sd$value[rhr & one_sd$date == on_date] <- 48 + spread
  dev <- compute_alcohol_deviation(one_sd, a, on_date = on_date)
  expect_equal(round(dev$z[dev$measure == "rhr"], 2), 1)
  expect_false(dev$flagged[dev$measure == "rhr"])

  two_sd <- hd
  two_sd$value[rhr & two_sd$date == on_date] <- 48 + 2 * spread
  dev2 <- compute_alcohol_deviation(two_sd, a, on_date = on_date)
  expect_true(dev2$flagged[dev2$measure == "rhr"])
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
  a <- set_night(a, on_date, units = units,
                 kcal = if (is.na(kcal)) NULL else kcal)
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
  expect_match(line, "I dag: .* ligger inte sämre än vanligt\\.")
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
  expect_false(grepl("inte sämre än vanligt", line))
})

test_that("the prose names resting heart rate before HRV", {
  f <- alcohol_fixture()
  hd <- f$health_daily
  set.seed(7)
  for (m in c("heart_rate_variability", "resting_heart_rate")) {
    idx <- hd$metric == m
    hd$value[idx] <- if (m == "heart_rate_variability") {
      round(stats::rnorm(sum(idx), 52, 4), 1)
    } else {
      round(stats::rnorm(sum(idx), 48, 1.5))
    }
  }
  hd$value[hd$metric == "heart_rate_variability" & hd$date == f$on_date] <- 30
  hd$value[hd$metric == "resting_heart_rate" & hd$date == f$on_date] <- 56

  line <- traning:::.insight_alcohol_line(f$alcohol, hd, f$on_date)
  expect_lt(regexpr("vilopuls", line, fixed = TRUE),
            regexpr("HRV", line, fixed = TRUE))

  # And the honest null names them in the same order.
  null_line <- traning:::.insight_alcohol_line(f$alcohol, f$health_daily,
                                                f$on_date)
  expect_match(null_line, "vilopuls, HRV och sömn ligger")
})

test_that("the honest null names every measure that has a reading", {
  f <- alcohol_fixture()
  line <- traning:::.insight_alcohol_line(f$alcohol, f$health_daily,
                                           f$on_date)
  expect_match(line, "vilopuls, HRV och sömn ligger inte sämre än vanligt")

  # Drop sleep for that morning: the clause names the two that remain,
  # with no placeholder for the third.
  hd <- f$health_daily[!(f$health_daily$metric == "sleep_totalSleep" &
                           f$health_daily$date == f$on_date), ]
  two <- traning:::.insight_alcohol_line(f$alcohol, hd, f$on_date)
  expect_match(two, "vilopuls och HRV ligger inte sämre än vanligt")
  expect_false(grepl("sömn", two))
})

test_that("an unusually good morning is not called normal", {
  # The gate is one-sided, so a morning well ABOVE baseline lands in the
  # null branch. Saying it is at normal levels would be a small untruth
  # in the direction of the feature's own thesis.
  f <- alcohol_fixture()
  hd <- f$health_daily
  idx <- hd$metric == "heart_rate_variability"
  set.seed(13)
  hd$value[idx] <- round(stats::rnorm(sum(idx), 52, 4), 1)
  hd$value[idx & hd$date == f$on_date] <- 75

  line <- traning:::.insight_alcohol_line(f$alcohol, hd, f$on_date)
  expect_match(line, "ligger inte sämre än vanligt")
  expect_false(grepl("normala nivåer", line))
})

test_that("a computed kcal figure is labelled as computed", {
  f <- alcohol_fixture(kcal = NA_real_)
  line <- traning:::.insight_alcohol_line(f$alcohol, f$health_daily, f$on_date)
  expect_match(line, "420 kcal från alkoholen \\(beräknat\\)")
})

test_that("the weekly line runs on Monday only and only with drinks in it", {
  monday <- as.Date("2026-09-07")
  dates <- seq(monday - 40, monday, by = "day")
  hd <- fake_health(dates)
  a <- fake_nights(dates)
  a <- set_night(a, as.Date("2026-09-05"), units = 6, kcal = 422.6)

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

test_that("the alcohol line is additive, not a context-chain candidate", {
  f <- alcohol_fixture()
  hd <- f$health_daily
  # A steep HRV downtrend: the context chain has something to say, and
  # the alcohol line must still appear beside it rather than lose the
  # single slot. An energy figure is due after every logged evening.
  window <- hd$metric == "heart_rate_variability" & hd$date > f$on_date - 7
  hd$value[window] <- seq(60, 40, length.out = sum(window))

  ctx <- traning:::.insight_context_line(NULL, hd, f$on_date)
  expect_match(ctx, "HRV sjunkande trend")
  expect_false(grepl("glas", ctx))

  alcohol_line <- traning:::.insight_alcohol_line(f$alcohol, hd, f$on_date)
  expect_match(alcohol_line, "glas")
})

test_that("the context chain no longer takes an alcohol argument", {
  expect_false("alcohol" %in% names(formals(traning:::.insight_context_line)))
})


# --- Notification wiring -----------------------------------------------------

test_that("the alcohol lines have their own opt-out, not the context one", {
  f <- alcohol_fixture()
  withr::local_envvar(TRANING_NOTIFY_CONTEXT = "false")
  lines <- traning:::.alcohol_notification_lines(f$health_daily, NULL,
                                                  f$on_date, f$alcohol)
  expect_length(lines, 1)
  expect_match(lines[[1]], "glas")

  withr::local_envvar(TRANING_ALCOHOL_NOTIFY = "false")
  expect_length(
    traning:::.alcohol_notification_lines(f$health_daily, NULL, f$on_date,
                                           f$alcohol),
    0
  )
})

test_that("the alcohol line survives a morning with no readiness verdict", {
  # The watch uploaded nothing, so there is no HRV, no sleep and no
  # readiness row. The energy account needs none of them, and this is
  # exactly the morning where it is still true.
  f <- alcohol_fixture()
  energy_only <- f$health_daily[f$health_daily$metric %in%
                                  c("active_energy",
                                    "basal_energy_burned"), ]
  td <- traning_data(
    summaries = data.frame(sessionStart = as.POSIXct(NA)),
    health_daily = energy_only
  )
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  save_alcohol_data(f$alcohol,
                     file.path(tmp_data, "cache", "alcohol_nights.RData"))

  out <- health_insight_readiness(td, on_date = f$on_date)
  # Readiness itself is genuinely absent, and is reported as absent.
  expect_true(is.na(out$status))
  # The alcohol account is not.
  expect_match(out$prosa, "glas")
  expect_equal(out$datum, f$on_date)
})

# --- Reports -----------------------------------------------------------------

test_that("report_alcohol reports the actual deviation, not NA", {
  # The deviation columns used to come back silently NA on any R older
  # than 4.3: vapply() stripped the Date class off the loop variable and
  # the resulting as.Date(numeric) error was swallowed by a tryCatch.
  # Column names alone did not catch that, so this pins a value.
  on_date <- as.Date("2026-09-06")
  dates <- seq(on_date - 40, on_date, by = "day")
  hd <- fake_health(dates, rhr = 48)
  hd$value[hd$metric == "resting_heart_rate" & hd$date == on_date] <- 55
  a <- set_night(fake_nights(dates), on_date, units = 6, kcal = 422.6)
  td <- traning_data(summaries = data.frame(sessionStart = as.POSIXct(NA)),
                     health_daily = hd)

  out <- report_alcohol(td, after = on_date, before = on_date, alcohol = a)
  expect_equal(nrow(out), 1)
  expect_equal(out$`VP avvik`, 7)
  expect_false(is.na(out$`HRV avvik`))
})

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


# --- Wiring into the health import -------------------------------------------

test_that("a health import refreshes the alcohol table beside its cache", {
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  canonical <- file.path(tmp_data, "kristian", "health_export", "canonical")
  dir.create(file.path(canonical, "alcohol_consumption"), recursive = TRUE)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  writeLines(
    '{"metric": "alcohol_consumption", "date": "2026-09-05", "units": "count", "samples": [{"source": "DrinkControl", "qty": 6, "date": "2026-09-05 18:44:00 +0200"}]}',
    file.path(canonical, "alcohol_consumption", "2026-09-05.json"))

  cache <- file.path(tmp_data, "cache", "health_daily.RData")
  suppressMessages(import_health_export(cache_path = cache, verbose = FALSE))

  alcohol_cache <- file.path(tmp_data, "cache", "alcohol_nights.RData")
  expect_true(file.exists(alcohol_cache))
  nights <- load_alcohol_data(alcohol_cache)
  expect_equal(nights$alcohol_night_units[nights$date == as.Date("2026-09-06")],
               6)

  # The daily total also reaches health_daily, since the metric is now
  # whitelisted in .import_metrics.
  health <- load_health_data(cache)
  expect_true("alcohol_consumption" %in% health$metric)
})

test_that("a corrupt canonical file leaves the alcohol rebuild standing", {
  tmp_data <- withr::local_tempdir()
  withr::local_envvar(TRANING_DATA = tmp_data)
  dir.create(file.path(tmp_data, "cache"), recursive = TRUE)
  canonical <- file.path(tmp_data, "kristian", "health_export", "canonical")
  dir.create(file.path(canonical, "alcohol_consumption"), recursive = TRUE)
  writeLines("{ not json",
             file.path(canonical, "alcohol_consumption", "2026-09-05.json"))
  writeLines(
    '{"metric": "alcohol_consumption", "date": "2026-09-06", "units": "count", "samples": [{"source": "DrinkControl", "qty": 3, "date": "2026-09-06 20:00:00 +0200"}]}',
    file.path(canonical, "alcohol_consumption", "2026-09-06.json"))

  # The unreadable file is skipped with a named warning, and the
  # readable one still lands. Silence here would lose a whole day of
  # drinks with nothing to find it by.
  expect_warning(
    out <- import_alcohol(save = FALSE, verbose = FALSE,
                          today = as.Date("2026-09-20")),
    "Kunde inte l\u00e4sa canonical-fil"
  )
  expect_equal(out$alcohol_night_units[out$date == as.Date("2026-09-07")], 3)
  w <- tryCatch(
    import_alcohol(save = FALSE, verbose = FALSE,
                   today = as.Date("2026-09-20")),
    warning = function(w) w
  )
  expect_match(conditionMessage(w), "2026-09-05.json", fixed = TRUE)

  # And the refresh helper swallows any failure rather than taking the
  # health import down with it: the alcohol table is derived
  # convenience, health_daily.RData is not.
  blocker <- file.path(tmp_data, "blocker")
  writeLines("not a directory", blocker)
  # The failing write warns on its way out; that noise is the induced
  # failure itself, not a latent problem.
  expect_false(suppressWarnings(traning:::.refresh_alcohol_cache(
    file.path(blocker, "cache", "health_daily.RData"), verbose = FALSE)))
})
