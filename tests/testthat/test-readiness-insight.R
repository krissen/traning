# Tests for state-based health insight functions in R/health_export.R:
# health_insight_readiness(), health_insight_update(),
# recent_data_dump(), latest_known_metrics().

# --- Fixtures ---------------------------------------------------------------

.fixture_health_daily <- function(today = as.Date("2026-04-20")) {
  metrics <- c("heart_rate_variability", "sleep_totalSleep",
                "sleep_deep", "sleep_rem", "resting_heart_rate",
                "vo2_max", "apple_sleeping_wrist_temperature",
                "respiratory_rate")
  dates <- seq(today - 21, today, by = "day")
  rows <- list()
  set.seed(42)
  for (m in metrics) {
    base <- switch(m,
      heart_rate_variability = 70,
      sleep_totalSleep = 7,
      sleep_deep = 1.0,
      sleep_rem = 1.5,
      resting_heart_rate = 55,
      vo2_max = 53,
      apple_sleeping_wrist_temperature = 36.5,
      respiratory_rate = 15
    )
    for (d in dates) {
      rows[[length(rows) + 1]] <- list(
        date = as.Date(d, origin = "1970-01-01"),
        metric = m,
        value = base + stats::rnorm(1, 0, base * 0.05),
        source = "test"
      )
    }
  }
  do.call(rbind.data.frame, lapply(rows, as.data.frame)) |> tibble::as_tibble()
}

.fixture_summaries <- function(today = as.Date("2026-04-20")) {
  starts <- as.POSIXct(seq(today - 14, today, by = "day"))
  n <- length(starts)
  tibble::tibble(
    sessionStart       = starts,
    sport              = "running",
    distance           = rep(8000, n),
    durationMoving     = rep(2700, n),
    avgPaceMoving      = rep(5.6, n),
    avgSpeedMoving     = rep(2.97, n),
    avgHeartRateMoving = rep(140, n),
    file               = paste0("test_", seq_len(n), ".tcx"),
    year               = format(starts, "%Y")
  )
}

# --- health_insight_readiness ----------------------------------------------

test_that("health_insight_readiness returns prosa with status and score", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  res <- health_insight_readiness(hd, s, hr_max = 185)
  expect_type(res, "list")
  expect_true("prosa" %in% names(res))
  expect_true("components_present" %in% names(res))
  expect_true(grepl("Dagsform", res$prosa))
  # Header includes one of the status strings
  expect_true(grepl("Grön|Gul|Röd", res$prosa))
})

test_that("health_insight_readiness reports missing components on partial", {
  hd <- .fixture_health_daily()
  # Drop today's HRV so quality drops
  today <- max(hd$date)
  hd_partial <- hd[!(hd$metric == "heart_rate_variability" & hd$date == today), ]
  s <- .fixture_summaries(today)
  res <- health_insight_readiness(hd_partial, s, hr_max = 185, on_date = today)
  expect_false(isTRUE(res$components_present$hrv))
  # HRV should be in components but with NA value
  expect_true(is.na(res$components$hrv$value))
})

test_that("health_insight_readiness returns empty list with no data", {
  empty_hd <- tibble::tibble(date = as.Date(character()),
                             metric = character(),
                             value = numeric(),
                             source = character())
  s <- .fixture_summaries()
  res <- health_insight_readiness(empty_hd, s)
  expect_equal(res$prosa, "")
})

# --- health_insight_update --------------------------------------------------

test_that("health_insight_update re-renders when partial component arrives", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  today <- max(hd$date)
  prev <- list(
    date = format(today, "%Y-%m-%d"),
    morning_sent = TRUE,
    morning_kvalitet = "partial",
    morning_components = list(
      hrv = FALSE, sleep = TRUE, rhr = TRUE,
      load = TRUE, wrist_temp = TRUE
    ),
    morning_status = "Gul",
    morning_score = 55,
    afternoon_updates_sent = list()
  )
  res <- health_insight_update(hd, s, prev, hr_max = 185, on_date = today)
  expect_equal(res$trigger, "rerender")
  expect_true(grepl("uppdaterad", res$prosa))
  expect_true(grepl("HRV", res$prosa))
})

test_that("health_insight_update is silent when nothing changed", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  today <- max(hd$date)
  prev <- list(
    date = format(today, "%Y-%m-%d"),
    morning_sent = TRUE,
    morning_kvalitet = "full",
    morning_components = list(
      hrv = TRUE, sleep = TRUE, rhr = TRUE,
      load = TRUE, wrist_temp = TRUE
    ),
    morning_status = "Grön",
    morning_score = 80,
    afternoon_updates_sent = list("vo2_max", "apple_sleeping_wrist_temperature",
                                   "respiratory_rate", "blood_oxygen_saturation")
  )
  res <- health_insight_update(hd, s, prev, hr_max = 185, on_date = today)
  expect_equal(res$prosa, "")
  expect_equal(res$trigger, "")
})

test_that("health_insight_update returns empty when prev_state is NULL", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  res <- health_insight_update(hd, s, NULL, hr_max = 185)
  expect_equal(res$prosa, "")
})

# --- recent_data_dump -------------------------------------------------------

test_that("recent_data_dump filters to the requested window", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  res <- recent_data_dump(hd, s, hours = 48)
  expect_true(is.list(res))
  expect_true("metrics" %in% names(res))
  expect_true("sessions" %in% names(res))
  expect_true("last_pushes" %in% names(res))
  # Window should restrict
  for (m in names(res$metrics)) {
    dates <- as.Date(res$metrics[[m]]$date)
    expect_true(all(dates >= Sys.Date() - 3))
  }
})

# --- latest_known_metrics ---------------------------------------------------

test_that("latest_known_metrics returns one row per unique metric", {
  hd <- .fixture_health_daily()
  res <- latest_known_metrics(hd)
  expect_equal(nrow(res), length(unique(hd$metric)))
  expect_true(all(c("metric", "date", "value", "age_hours") %in% names(res)))
  # Should be sorted by date ascending
  expect_true(all(diff(as.numeric(res$date)) >= 0))
})

test_that("latest_known_metrics handles empty input", {
  empty <- tibble::tibble(date = as.Date(character()),
                          metric = character(),
                          value = numeric())
  res <- latest_known_metrics(empty)
  expect_equal(nrow(res), 0)
})

# --- Sport-aware notifications -----------------------------------------------

.fixture_multisport <- function(today = as.Date("2026-04-22")) {
  # Wed 2026-04-22 → ISO week 2026-W17 (Mon 04-20 .. Sun 04-26).
  # `.recent_sport_activity` looks at the 24h window ending one day past
  # on_date, i.e. for on_date=2026-04-22 it covers 2026-04-22 00:00 UTC
  # → 2026-04-23 00:00 UTC. Place 2 sessions in that window.
  midnight_today <- as.POSIXct(as.character(today), tz = "UTC")
  tibble::tibble(
    sessionStart = c(
      midnight_today + as.difftime(8,  units = "hours"),  # 04-22 08:00 run (W17)
      midnight_today + as.difftime(18, units = "hours"),  # 04-22 18:00 walk (W17)
      midnight_today - as.difftime(72 - 7, units = "hours"),  # 04-19 17:00 cycle (W16)
      midnight_today - as.difftime(120, units = "hours"),     # 04-17 00:00 run (W16)
      midnight_today - as.difftime(240, units = "hours"),     # 04-12 00:00 run (W15)
      midnight_today - as.difftime(264, units = "hours")      # 04-11 00:00 run (W15)
    ),
    sport = c("running", "walking", "cycling", "running", "running", "running"),
    distance = c(8100, 4200, 25000, 6500, 7000, 7500),
    durationMoving = rep(2400, 6),
    avgPaceMoving = c(5.0, 16.0, 2.4, 5.5, 5.2, 5.0),
    avgSpeedMoving = c(3.3, 1.0, 6.9, 3.0, 3.2, 3.3),
    avgHeartRateMoving = c(140, 95, 130, 138, 142, 140),
    file = paste0("ms_", seq_len(6), ".tcx"),
    year = format(midnight_today, "%Y")
  )
}

test_that(".recent_sport_activity aggregates the last 24h per sport", {
  s <- .fixture_multisport()
  res <- traning:::.recent_sport_activity(s, on_date = as.Date("2026-04-22"),
                                          hours = 24L)
  expect_s3_class(res, "data.frame")
  # Yesterday window should include the 1 run + 1 walk only
  expect_setequal(res$sport, c("running", "walking"))
  expect_equal(sort(res$km), c(4.2, 8.1))
})

test_that(".recent_sport_activity returns NULL on empty input", {
  expect_null(traning:::.recent_sport_activity(NULL,
                                                as.Date("2026-04-22")))
  expect_null(traning:::.recent_sport_activity(data.frame(),
                                                as.Date("2026-04-22")))
})

test_that(".weekly_sport_aggregate sums per-sport km for current week", {
  s <- .fixture_multisport()
  res <- traning:::.weekly_sport_aggregate(s,
                                            on_date = as.Date("2026-04-22"),
                                            week_offset = 0L)
  expect_match(res$iso_week, "^2026-W")
  # Week 17 (Mon 04-20 .. Sun 04-26) only contains the two 04-22 sessions
  # (run + walk). The cycling row on 04-19 falls in week 16.
  expect_setequal(res$per_sport$sport, c("running", "walking"))
  expect_equal(round(res$total_km, 1), 12.3)  # 8.1 + 4.2
})

test_that(".recent_sport_activity drops zero-distance sports", {
  # Strength sessions have no distance; the prose should silently skip
  # them rather than rendering "styrketräning 0.0 km".
  base <- as.POSIXct("2026-04-22 12:00:00", tz = "UTC")
  s <- tibble::tibble(
    sessionStart = c(base + as.difftime(c(2, 4), units = "hours")),
    sport = c("running", "strength"),
    distance = c(8000, 0)
  )
  res <- traning:::.recent_sport_activity(s,
                                           on_date = as.Date("2026-04-22"))
  expect_equal(res$sport, "running")
  expect_false("strength" %in% res$sport)
})

test_that(".format_recent_activity_line renders Swedish prose", {
  activity <- data.frame(
    sport = c("running", "cycling"),
    sessions = c(1L, 1L),
    km = c(8.1, 25),
    stringsAsFactors = FALSE
  )
  out <- traning:::.format_recent_activity_line(activity)
  expect_match(out, "^Senaste dygnet: ")
  expect_match(out, "löpning 8.1 km")
  expect_match(out, "cykling 25 km")
})

test_that(".format_recent_activity_line returns NULL when no rows", {
  expect_null(traning:::.format_recent_activity_line(NULL))
  expect_null(traning:::.format_recent_activity_line(
    data.frame(sport = character(0), sessions = integer(0),
               km = numeric(0))
  ))
})

test_that(".format_weekly_summary_line handles 1/2/3+ sport variants", {
  # 1 sport
  one <- list(iso_week = "2026-W17", total_km = 32, total_trimp = NA_real_,
              per_sport = data.frame(sport = "running", sessions = 4L,
                                      km = 32, stringsAsFactors = FALSE))
  expect_match(traning:::.format_weekly_summary_line(one),
               "^Förra veckan: 32 km löpning")

  # 2 sports — total >= 10 so per-sport km should render as integers
  two <- list(iso_week = "2026-W17", total_km = 45, total_trimp = NA_real_,
              per_sport = data.frame(
                sport = c("running", "cycling"),
                sessions = c(2L, 1L),
                km = c(30, 15),
                stringsAsFactors = FALSE
              ))
  expect_match(traning:::.format_weekly_summary_line(two),
               "^Förra veckan: 45 km \\(löpning 30, cykling 15\\)")

  # 3+ sports → bucket count, and integer rendering for the mixed list
  three <- list(iso_week = "2026-W17", total_km = 64, total_trimp = NA_real_,
                per_sport = data.frame(
                  sport = c("running", "cycling", "walking", "strength"),
                  sessions = c(2L, 1L, 3L, 1L),
                  km = c(30, 20, 12, 2),
                  stringsAsFactors = FALSE
                ))
  out_three <- traning:::.format_weekly_summary_line(three)
  expect_match(out_three, "över 4 sporter")
  # decimal-consistency: with total_km >= 10, per-sport km are integers
  # even when one is small (2 km rendered as "2", not "2.0").
  expect_match(out_three, "styrketräning 2\\b")
  expect_false(grepl("2\\.0", out_three))
})

test_that(".format_weekly_summary_line uses TRIMP delta when available", {
  cur  <- list(iso_week = "2026-W17", total_km = 45, total_trimp = 360,
               per_sport = data.frame(sport = "running", sessions = 4L,
                                       km = 45, stringsAsFactors = FALSE))
  prev <- list(iso_week = "2026-W16", total_km = 60, total_trimp = 300,
               per_sport = data.frame(sport = "running", sessions = 3L,
                                       km = 60, stringsAsFactors = FALSE))
  out <- traning:::.format_weekly_summary_line(cur, prev)
  # 360 vs 300 → +20%
  expect_match(out, "\\+20 % belastning mot v\\.16\\.")
  # No km-delta phrasing when TRIMP is the comparator
  expect_false(grepl("km mot", out))
})

test_that(".format_weekly_summary_line falls back to km delta without TRIMP", {
  cur <- list(iso_week = "2026-W17", total_km = 45, total_trimp = NA_real_,
              per_sport = data.frame(sport = "running", sessions = 4L,
                                      km = 45, stringsAsFactors = FALSE))
  prev <- list(iso_week = "2026-W16", total_km = 32, total_trimp = NA_real_,
               per_sport = data.frame(sport = "running", sessions = 3L,
                                       km = 32, stringsAsFactors = FALSE))
  out <- traning:::.format_weekly_summary_line(cur, prev)
  # Phrasing: "mot v.16" — never "mot förra veckan" (avoids double use
  # in the morning push).
  expect_match(out, "\\+13 km mot v\\.16")
  expect_false(grepl("mot förra veckan", out))
})

test_that(".weekly_line_for_date fires only on Monday", {
  s <- .fixture_multisport(today = as.Date("2026-04-22"))
  # Mid-week → silent
  expect_null(traning:::.weekly_line_for_date(s, as.Date("2026-04-22")))
  # Sunday is no longer a trigger (partial week-in-progress recap was
  # dropped; the same number changes once the Sunday session lands)
  expect_null(traning:::.weekly_line_for_date(s, as.Date("2026-04-26")))
  # Monday → make-up post for the completed previous week
  monday <- as.Date("2026-04-27")
  out <- traning:::.weekly_line_for_date(s, monday)
  expect_match(out, "^Förra veckan: ")
})

test_that("health_insight_readiness includes recent activity line", {
  today <- as.Date("2026-04-22")
  hd <- .fixture_health_daily(today)
  s <- .fixture_multisport(today)
  res <- health_insight_readiness(hd, s, hr_max = 185, on_date = today)
  expect_match(res$prosa, "Senaste dygnet: ")
})

test_that("health_insight_readiness includes weekly recap on Monday", {
  monday <- as.Date("2026-04-27")
  hd <- .fixture_health_daily(monday)
  s <- .fixture_multisport(today = monday)
  res <- health_insight_readiness(hd, s, hr_max = 185, on_date = monday)
  expect_match(res$prosa, "Förra veckan: ")
})

test_that("TRANING_NOTIFY_SPORT=false suppresses the new lines", {
  withr::with_envvar(c("TRANING_NOTIFY_SPORT" = "false"), {
    today <- as.Date("2026-04-22")
    hd <- .fixture_health_daily(today)
    s <- .fixture_multisport(today)
    res <- health_insight_readiness(hd, s, hr_max = 185, on_date = today)
    expect_false(grepl("Senaste dygnet:", res$prosa))
  })
})


# --- Smart insight context line --------------------------------------------

# Streak-comeback fixture: last running session 5 days before `today`,
# plus today, so the streak helper has the cleanest possible trigger.
.fixture_streak_comeback <- function(today) {
  # Explicit UTC mirrors the other fixtures in this file. Without it
  # the test becomes timezone-dependent — `today - 5L` is a Date but
  # `as.POSIXct(Date)` defaults to local time, so the
  # `as.Date(sessionStart)` step inside the helper can shift by a
  # day on hosts with extreme offsets (CI runners in non-CET zones).
  starts <- as.POSIXct(paste0(c(today - 5L, today), " 08:00:00"),
                       tz = "UTC")
  tibble::tibble(
    sessionStart = starts,
    sport = "running",
    distance = c(8000, 6000),
    durationMoving = as.difftime(c(45, 30), units = "mins"),
    duration       = as.difftime(c(45, 30), units = "mins"),
    avgHeartRateMoving = c(140, 138),
    file = c("a.tcx", "b.tcx"),
    year = format(starts, "%Y")
  )
}

test_that("health_insight_readiness appends the context line when streak fires", {
  today <- as.Date("2026-04-22")
  hd <- .fixture_health_daily(today)
  s  <- .fixture_streak_comeback(today)
  res <- health_insight_readiness(hd, s, hr_max = 185, on_date = today)
  expect_match(res$prosa, "Första löpningen på 5 dagar")
})


test_that("TRANING_NOTIFY_CONTEXT=false suppresses the context line", {
  withr::with_envvar(c("TRANING_NOTIFY_CONTEXT" = "false"), {
    today <- as.Date("2026-04-22")
    hd <- .fixture_health_daily(today)
    s  <- .fixture_streak_comeback(today)
    res <- health_insight_readiness(hd, s, hr_max = 185, on_date = today)
    expect_false(grepl("Första löpningen", res$prosa))
  })
})
