# Tests for the smart-insight context line helpers in R/insight_context.R.

# --- Streak / comeback ------------------------------------------------------

test_that(".insight_streak_line fires after 3+ days off", {
  today <- as.Date("2026-05-11")
  # Last run was 4 days ago (2026-05-07), today has another run.
  summaries <- tibble::tibble(
    sessionStart = as.POSIXct(c("2026-05-07 08:00:00",
                                 "2026-05-11 08:00:00"),
                               tz = "UTC"),
    distance = c(8000, 6000),
    sport = "running"
  )
  line <- traning:::.insight_streak_line(summaries, today)
  expect_match(line, "Första löpningen på 4 dagar")
})

test_that(".insight_streak_line threshold uses calendar-days arithmetic", {
  # threshold_days = 3 means today - last_run >= 3, i.e. 2+ rest days
  # between the two runs. A 3-day gap (last May 7, today May 10) is
  # the smallest gap that triggers. Confirm both sides of the
  # boundary explicitly so the Swedish "på N dagar" wording stays
  # honest.
  today <- as.Date("2026-05-10")
  s_three <- tibble::tibble(  # 3-day gap → should fire
    sessionStart = as.POSIXct(c("2026-05-07 08:00:00",
                                 "2026-05-10 08:00:00"),
                               tz = "UTC"),
    distance = c(8000, 6000),
    sport = "running"
  )
  expect_match(traning:::.insight_streak_line(s_three, today),
               "på 3 dagar")
  s_two <- tibble::tibble(    # 2-day gap → must NOT fire
    sessionStart = as.POSIXct(c("2026-05-08 08:00:00",
                                 "2026-05-10 08:00:00"),
                               tz = "UTC"),
    distance = c(8000, 6000),
    sport = "running"
  )
  expect_null(traning:::.insight_streak_line(s_two, today))
})

test_that(".insight_streak_line is silent when ran yesterday", {
  today <- as.Date("2026-05-11")
  summaries <- tibble::tibble(
    sessionStart = as.POSIXct(c("2026-05-10 08:00:00",
                                 "2026-05-11 08:00:00"),
                               tz = "UTC"),
    distance = c(8000, 6000),
    sport = "running"
  )
  expect_null(traning:::.insight_streak_line(summaries, today))
})

test_that(".insight_streak_line silent when no run today", {
  today <- as.Date("2026-05-11")
  summaries <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-05 08:00:00", tz = "UTC"),
    distance = 8000,
    sport = "running"
  )
  expect_null(traning:::.insight_streak_line(summaries, today))
})

test_that(".insight_streak_line silent on empty inputs", {
  expect_null(traning:::.insight_streak_line(NULL, Sys.Date()))
  expect_null(traning:::.insight_streak_line(tibble::tibble(), Sys.Date()))
})


# --- ACWR commentary --------------------------------------------------------

# compute_acwr() expects sufficient history to produce non-zero ACWR. The
# fixture below provides 60 days of steady running with a few rest days
# baked in, so the latest row's ACWR is computable.
.fixture_acwr_summaries <- function(today = Sys.Date(), weekly_km = 30) {
  days <- seq.Date(today - 59L, today, by = "day")
  is_run_day <- (as.integer(format(days, "%u")) %in% c(1L, 3L, 5L, 7L))
  d <- days[is_run_day]
  per_km <- weekly_km / 4
  tibble::tibble(
    sessionStart = as.POSIXct(paste0(d, " 08:00:00"), tz = "UTC"),
    distance = per_km * 1000,
    sport = "running",
    durationMoving = as.difftime(rep(per_km * 6, length(d)),
                                  units = "mins"),
    duration       = as.difftime(rep(per_km * 6, length(d)),
                                  units = "mins"),
    avgHeartRateMoving = 140
  )
}

test_that(".insight_acwr_line returns NULL when ACWR is in normal band", {
  today <- as.Date("2026-05-11")
  s <- .fixture_acwr_summaries(today, weekly_km = 30)
  # Steady baseline → ACWR ≈ 1.0 → no commentary
  line <- traning:::.insight_acwr_line(s, today)
  expect_null(line)
})

test_that(".insight_acwr_line warns on elevated ACWR", {
  today <- as.Date("2026-05-11")
  # Steady 30 km/w baseline then a spike week pushes ACWR up.
  s <- .fixture_acwr_summaries(today, weekly_km = 30)
  # Add a heavy spike in the most recent 3 days
  spike <- tibble::tibble(
    sessionStart = as.POSIXct(c("2026-05-09 08:00:00",
                                 "2026-05-10 08:00:00",
                                 "2026-05-11 08:00:00"),
                               tz = "UTC"),
    distance = c(25000, 25000, 25000),
    sport = "running",
    durationMoving = as.difftime(rep(180, 3), units = "mins"),
    duration       = as.difftime(rep(180, 3), units = "mins"),
    avgHeartRateMoving = 140
  )
  s_spike <- dplyr::bind_rows(s, spike)
  line <- traning:::.insight_acwr_line(s_spike, today)
  expect_false(is.null(line))
  expect_match(line, "ACWR")
})


# --- HRV trend --------------------------------------------------------------

test_that(".insight_hrv_trend_line fires on a clear downtrend", {
  today <- as.Date("2026-05-11")
  hd <- tibble::tibble(
    metric = "heart_rate_variability",
    date   = today - (6:0),
    # Drop ~1 ms/day over the week
    value  = c(70, 69, 68, 67, 66, 65, 64),
    source = "AW"
  )
  line <- traning:::.insight_hrv_trend_line(hd, today)
  expect_match(line, "sjunkande trend")
})

test_that(".insight_hrv_trend_line silent when flat", {
  today <- as.Date("2026-05-11")
  hd <- tibble::tibble(
    metric = "heart_rate_variability",
    date   = today - (6:0),
    value  = rep(65, 7),
    source = "AW"
  )
  expect_null(traning:::.insight_hrv_trend_line(hd, today))
})


# --- Composer priority ------------------------------------------------------

test_that(".insight_context_line returns streak before ACWR", {
  today <- as.Date("2026-05-11")
  # Today is a comeback day (5 days off) AND a heavy spike that would
  # also trigger ACWR. Streak should win by priority.
  s <- .fixture_acwr_summaries(today, weekly_km = 30)
  # Replace recent runs with a gap + comeback
  s <- s[as.Date(s$sessionStart) <= today - 6L, ]
  comeback <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-11 08:00:00", tz = "UTC"),
    distance = 25000,
    sport = "running",
    durationMoving = as.difftime(180, units = "mins"),
    duration       = as.difftime(180, units = "mins"),
    avgHeartRateMoving = 140
  )
  s <- dplyr::bind_rows(s, comeback)
  line <- traning:::.insight_context_line(s, NULL, today)
  expect_match(line, "Första löpningen")
})

test_that(".insight_context_line returns NULL when everything is quiet", {
  today <- as.Date("2026-05-11")
  s <- .fixture_acwr_summaries(today, weekly_km = 30)
  expect_null(traning:::.insight_context_line(s, NULL, today))
})
