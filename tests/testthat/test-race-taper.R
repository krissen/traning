# Tests for compute_taper_plan() and compute_race_readiness().

.fixture_summaries_for_taper <- function(weeks_back = 8L,
                                          weekly_km = 40,
                                          today = Sys.Date()) {
  # One running session per day for `weeks_back` weeks ending the
  # Sunday before today, with `weekly_km` km split over 4 sessions/week.
  iso_dow <- function(d) as.integer(format(d, "%u"))
  end <- today - iso_dow(today)               # last Sunday
  start <- end - weeks_back * 7L + 1L
  dates <- seq.Date(start, end, by = "day")
  # 4 sessions per week, equal length
  per_run_km <- weekly_km / 4
  is_run <- (iso_dow(dates) %in% c(1L, 3L, 5L, 7L))
  d <- dates[is_run]
  tibble::tibble(
    sessionStart       = as.POSIXct(paste0(d, " 08:00:00"), tz = "UTC"),
    distance           = per_run_km * 1000,    # metres
    sport              = "running",
    durationMoving     = as.difftime(per_run_km * 6, units = "mins"),
    duration           = as.difftime(per_run_km * 6, units = "mins"),
    avgHeartRateMoving = 145
  )
}


# --- compute_taper_plan -----------------------------------------------------

test_that("compute_taper_plan produces one row per ISO week through race", {
  s <- .fixture_summaries_for_taper(weeks_back = 8L, weekly_km = 40)
  race_date <- Sys.Date() + 28L
  plan <- compute_taper_plan(s, race_date, distance_km = 21.1,
                              taper_weeks = 2L)
  expect_s3_class(plan, "data.frame")
  # Weeks span from this Monday through race week.
  iso_dow <- function(d) as.integer(format(d, "%u"))
  expect_equal(plan$week_start[[1]],
               Sys.Date() - (iso_dow(Sys.Date()) - 1L))
  expect_equal(tail(plan$week_start, 1L),
               race_date - (iso_dow(race_date) - 1L))
  expect_true(all(plan$weeks_until_race[-nrow(plan)] >
                  plan$weeks_until_race[-1]))
  expect_equal(tail(plan$weeks_until_race, 1L), 0L)
})


test_that("compute_taper_plan applies 0.45 race-week floor", {
  s <- .fixture_summaries_for_taper(weeks_back = 8L, weekly_km = 40)
  race_date <- Sys.Date() + 28L
  plan <- compute_taper_plan(s, race_date, taper_weeks = 2L)
  race_row <- plan[plan$phase == "race", ]
  expect_equal(nrow(race_row), 1L)
  expect_equal(race_row$relative_to_baseline, 0.45, tolerance = 0.01)
  baseline <- race_row$baseline_km[[1]]
  expect_equal(race_row$target_km, round(baseline * 0.45, 1),
               tolerance = 0.1)
})


test_that("compute_taper_plan rejects past race_date", {
  s <- .fixture_summaries_for_taper(weeks_back = 4L)
  expect_error(compute_taper_plan(s, Sys.Date() - 1L),
               "race_date")
})


test_that("compute_taper_plan rejects invalid taper_weeks", {
  s <- .fixture_summaries_for_taper(weeks_back = 4L)
  expect_error(compute_taper_plan(s, Sys.Date() + 14L, taper_weeks = 0L),
               "taper_weeks")
  expect_error(compute_taper_plan(s, Sys.Date() + 14L, taper_weeks = 5L),
               "taper_weeks")
})


test_that("baseline_km counts zero-run weeks toward the median", {
  # Two recent ISO weeks have runs (30 km / 30 km), the other two
  # have no running at all. Median over [30, 30, 0, 0] is 15.
  # If the baseline silently dropped no-run weeks the median would
  # come out 30 instead and a taper schedule for an athlete
  # recovering from a layoff would aim 2× too high.
  iso_dow <- function(d) as.integer(format(d, "%u"))
  today <- Sys.Date()
  end <- today - iso_dow(today)
  # Only place runs in the two most recent weeks (i = 3, 4 of 4).
  rows <- list()
  for (i in c(3L, 4L)) {
    wk_start <- end - (4L - i + 1L) * 7L + 1L
    d <- wk_start + c(0L, 2L, 4L, 6L)
    rows[[length(rows) + 1L]] <- tibble::tibble(
      sessionStart   = as.POSIXct(paste0(d, " 08:00:00"), tz = "UTC"),
      distance       = 7.5 * 1000,
      sport          = "running",
      durationMoving = as.difftime(rep(45, 4), units = "mins"),
      duration       = as.difftime(rep(45, 4), units = "mins")
    )
  }
  s <- dplyr::bind_rows(rows)
  plan <- compute_taper_plan(s, Sys.Date() + 14L, taper_weeks = 2L)
  expect_equal(plan$baseline_km[[1]], 15, tolerance = 0.1)
})


test_that("compute_taper_plan baseline_km is the 4-week median, not mean", {
  # Build a fixture with three 30-km weeks and one 80-km spike — median
  # is 30, mean is 42.5. Confirm the plan uses the median so a single
  # overshoot week doesn't pull the entire schedule above maintenance.
  iso_dow <- function(d) as.integer(format(d, "%u"))
  today <- Sys.Date()
  end <- today - iso_dow(today)  # last Sunday
  weekly_km <- c(30, 30, 80, 30)
  rows <- lapply(seq_along(weekly_km), function(i) {
    wk_start <- end - (length(weekly_km) - i + 1) * 7L + 1L
    d <- wk_start + c(0L, 2L, 4L, 6L)
    per_km <- weekly_km[[i]] / 4
    tibble::tibble(
      sessionStart = as.POSIXct(paste0(d, " 08:00:00"), tz = "UTC"),
      distance = per_km * 1000,
      sport = "running",
      durationMoving = as.difftime(per_km * 6, units = "mins"),
      duration       = as.difftime(per_km * 6, units = "mins")
    )
  })
  s <- dplyr::bind_rows(rows)
  plan <- compute_taper_plan(s, Sys.Date() + 14L, taper_weeks = 2L)
  expect_equal(plan$baseline_km[[1]], 30, tolerance = 0.1)
})


test_that("render_taper_plan_prose mentions baseline, race date and distance", {
  s <- .fixture_summaries_for_taper(weeks_back = 8L, weekly_km = 40)
  race_date <- Sys.Date() + 28L
  plan <- compute_taper_plan(s, race_date, distance_km = 21.1,
                              taper_weeks = 2L)
  prose <- render_taper_plan_prose(plan)
  expect_match(prose, "baseline", ignore.case = TRUE)
  expect_match(prose, "21.1")
  expect_match(prose, format(race_date, "%Y"))
})


# --- compute_race_readiness -------------------------------------------------

test_that("compute_taper_plan handles a zero baseline (no recent running)", {
  # No sessions in the last 4 weeks at all. The schedule should not
  # silently produce zero-km rows pretending to be "100% av baseline";
  # it must signal insufficient_baseline and let the renderer say so.
  iso_dow <- function(d) as.integer(format(d, "%u"))
  today <- Sys.Date()
  # Place the only run well outside the lookback window.
  s <- tibble::tibble(
    sessionStart = as.POSIXct(paste0(today - 90L, " 08:00:00"),
                               tz = "UTC"),
    distance = 8000,
    sport = "running",
    durationMoving = as.difftime(45, units = "mins"),
    duration       = as.difftime(45, units = "mins")
  )
  plan <- compute_taper_plan(s, today + 14L, taper_weeks = 2L)
  expect_equal(nrow(plan), 0L)
  expect_true(isTRUE(attr(plan, "insufficient_baseline")))
  prose <- render_taper_plan_prose(plan)
  expect_match(prose, "Otillräcklig baseline")
})


test_that("compute_race_readiness validates inputs", {
  s <- .fixture_summaries_for_taper(weeks_back = 12L, weekly_km = 40)
  expect_error(compute_race_readiness(s, NULL, NA),
               "target_date")
  expect_error(compute_race_readiness(s, NULL, Sys.Date() + 14L,
                                       taper_weeks = 0L),
               "taper_weeks")
  expect_error(compute_race_readiness(s, NULL, Sys.Date() + 14L,
                                       taper_weeks = 9L),
               "taper_weeks")
})


test_that("render_taper_plan_prose dates are locale-invariant ISO", {
  # The Shiny host's LC_TIME isn't always Swedish; %a/%b would emit
  # English on a C-locale server. Render must produce stable ISO
  # dates regardless of locale (or via an explicit Swedish mapping).
  s <- .fixture_summaries_for_taper(weeks_back = 8L, weekly_km = 40)
  race_date <- Sys.Date() + 28L
  plan <- compute_taper_plan(s, race_date, distance_km = 10.0,
                              taper_weeks = 2L)
  withr::with_locale(c("LC_TIME" = "C"), {
    prose <- render_taper_plan_prose(plan)
  })
  # ISO date is YYYY-MM-DD on Date objects regardless of locale.
  expect_match(prose, format(race_date), fixed = TRUE)
})


test_that("compute_race_readiness returns Otillräcklig data with empty inputs", {
  empty <- tibble::tibble(
    sessionStart = as.POSIXct(character(0)),
    distance = numeric(0),
    sport = character(0),
    avgHeartRateMoving = numeric(0),
    durationMoving = as.difftime(numeric(0), units = "mins")
  )
  r <- compute_race_readiness(empty, NULL, Sys.Date() + 14L)
  expect_equal(r$status, "Otillräcklig data")
  expect_true(is.na(r$score))
})


test_that("compute_race_readiness produces a score with PMC data only", {
  s <- .fixture_summaries_for_taper(weeks_back = 12L, weekly_km = 40)
  r <- compute_race_readiness(s, NULL, Sys.Date() + 21L)
  expect_false(is.na(r$score))
  expect_true(r$score >= 0 && r$score <= 100)
  # CTL trend + TSB projection are present; HRV / RHR absent.
  expect_named(r$components,
               c("ctl_trend", "tsb_projection"),
               ignore.order = TRUE)
})


test_that("compute_race_readiness prose mentions days_until and status", {
  s <- .fixture_summaries_for_taper(weeks_back = 12L, weekly_km = 40)
  r <- compute_race_readiness(s, NULL, Sys.Date() + 21L)
  expect_match(r$prose, "21 dagar kvar")
  # Score line is always present.
  expect_match(r$prose, "/100")
})


test_that("readiness prose lists missing components", {
  # PMC only — health_daily is NULL so HRV and resting HR get
  # dropped from the average. The prose must say so explicitly,
  # not silently use the running-only components and pretend
  # everything was measured.
  s <- .fixture_summaries_for_taper(weeks_back = 12L, weekly_km = 40)
  r <- compute_race_readiness(s, NULL, Sys.Date() + 21L)
  expect_match(r$prose, "Saknade komponenter")
  expect_match(r$prose, "HRV")
  expect_match(r$prose, "Vilopuls")
})


test_that(".score_stability hits the linear band", {
  # Symmetric "higher-is-better" semantics: good = within 0.5 of
  # baseline, bad = >3 below. Score 100 at delta=0, 0 at delta=-3.
  expect_equal(traning:::.score_stability(0,    0.5, 3), 100)
  expect_equal(traning:::.score_stability(-0.5, 0.5, 3), 100)
  expect_equal(traning:::.score_stability(-3.0, 0.5, 3),   0)
  # Linear region: at -1.75 ms, expect ~50/100 (midpoint of -0.5..-3).
  expect_equal(traning:::.score_stability(-1.75, 0.5, 3), 50,
               tolerance = 0.5)
  # Lower-is-better flips the sign convention.
  expect_equal(traning:::.score_stability(3, 1, 3,
                                           direction = "lower-is-better"),
               0)
  expect_equal(traning:::.score_stability(-1, 1, 3,
                                           direction = "lower-is-better"),
               100)
})
