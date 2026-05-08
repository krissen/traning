test_that("classify_session: RPE primary cutoffs map to expected types", {
  mk <- function(rpe, dur_min = 60) {
    tibble::tibble(
      sessionStart = as.POSIXct("2026-05-07", tz = "UTC"),
      sport = "running",
      distance = 10000,
      avgPaceMoving = 5.0,
      avgHeartRateMoving = 150,
      durationMoving = as.difftime(dur_min, units = "mins"),
      garmin_directWorkoutRpe = rpe,
      garmin_hrTimeInZone_1 = NA_real_,
      garmin_hrTimeInZone_2 = NA_real_,
      garmin_hrTimeInZone_3 = NA_real_,
      garmin_hrTimeInZone_4 = NA_real_,
      garmin_hrTimeInZone_5 = NA_real_
    )
  }

  expect_equal(classify_session(mk(20, 30))$type, "recovery")    # RPE 2
  expect_equal(classify_session(mk(30, 60))$type, "endurance")    # RPE 3
  expect_equal(classify_session(mk(50, 100))$type, "long")        # RPE 5, >90 min
  expect_equal(classify_session(mk(60, 45))$type, "tempo")        # RPE 6
  expect_equal(classify_session(mk(75, 60))$type, "threshold_intervals")  # RPE 7.5
  expect_equal(classify_session(mk(85, 35))$type, "vo2max")       # RPE 8.5
  expect_equal(classify_session(mk(95, 50))$type, "race_pace")    # RPE 9.5
})

test_that("classify_session: zone-fraction heuristic", {
  mk_zones <- function(z1, z2, z3, z4, z5, dur_min = 60) {
    tibble::tibble(
      sessionStart = as.POSIXct("2026-05-07", tz = "UTC"),
      sport = "running",
      distance = 10000,
      avgPaceMoving = 5.0,
      avgHeartRateMoving = 150,
      durationMoving = as.difftime(dur_min, units = "mins"),
      garmin_directWorkoutRpe = NA_real_,
      garmin_hrTimeInZone_1 = z1,
      garmin_hrTimeInZone_2 = z2,
      garmin_hrTimeInZone_3 = z3,
      garmin_hrTimeInZone_4 = z4,
      garmin_hrTimeInZone_5 = z5
    )
  }

  # Pure Z1 long run: 110 min mostly in Garmin zones 1-2.
  long <- mk_zones(2400, 4200, 0, 0, 0, dur_min = 110)
  res <- classify_session(long)
  expect_equal(res$type, "long")
  expect_equal(res$zone, "Z1")
  expect_equal(res$confidence, "medium")

  # Pure Z1 endurance run, 60 min.
  end <- mk_zones(1200, 2400, 0, 0, 0, dur_min = 60)
  expect_equal(classify_session(end)$type, "endurance")

  # Z2-dominant tempo: 60 min mostly in Garmin zone 3.
  tempo <- mk_zones(300, 600, 2700, 0, 0, dur_min = 60)
  expect_equal(classify_session(tempo)$type, "tempo")

  # Z3 short bouts (VO2max intervals): 35 min with Garmin zones 4-5 ~25%.
  vo2 <- mk_zones(900, 600, 0, 450, 150, dur_min = 35)
  expect_equal(classify_session(vo2)$type, "vo2max")

  # Z3-dominant race-pace: 50 min, >40% of time in zones 4-5.
  race <- mk_zones(300, 300, 600, 1200, 600, dur_min = 50)
  expect_equal(classify_session(race)$type, "race_pace")
})

test_that("classify_session: HR-average fallback (no RPE, no zones)", {
  mk_hr <- function(hr, dur_min = 60) {
    tibble::tibble(
      sessionStart = as.POSIXct("2026-05-07", tz = "UTC"),
      sport = "running",
      distance = 10000,
      avgPaceMoving = 5.0,
      avgHeartRateMoving = hr,
      durationMoving = as.difftime(dur_min, units = "mins"),
      garmin_directWorkoutRpe = NA_real_,
      garmin_hrTimeInZone_1 = NA_real_,
      garmin_hrTimeInZone_2 = NA_real_,
      garmin_hrTimeInZone_3 = NA_real_,
      garmin_hrTimeInZone_4 = NA_real_,
      garmin_hrTimeInZone_5 = NA_real_
    )
  }

  # HR fallback uses get_hr_max(summaries) — pass an explicit hr_max
  # so the test is self-contained.
  expect_equal(classify_session(mk_hr(120, 30), hr_max = 180)$type, "recovery")
  expect_equal(classify_session(mk_hr(130, 60), hr_max = 180)$type, "endurance")
  expect_equal(classify_session(mk_hr(130, 100), hr_max = 180)$type, "long")
  expect_equal(classify_session(mk_hr(155, 60), hr_max = 180)$type, "tempo")     # ~86%
  expect_equal(classify_session(mk_hr(165, 45), hr_max = 180)$type, "threshold_intervals")  # 91.7% — below the 92% VT2 anchor
  expect_equal(classify_session(mk_hr(170, 30), hr_max = 180)$type, "vo2max")    # 94.4% — clearly Z3

  res <- classify_session(mk_hr(155, 60), hr_max = 180)
  expect_equal(res$confidence, "low")
})

test_that("classify_session: unknown when no inputs", {
  bare <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-07", tz = "UTC"),
    sport = "running", distance = 0, avgPaceMoving = NA_real_,
    avgHeartRateMoving = NA_real_,
    durationMoving = as.difftime(0, units = "mins")
  )
  expect_equal(classify_session(bare)$type, "unknown")
})

test_that("session_z3_count counts only Z3-classified runs in window", {
  zone_row <- function(date, z1, z2, z3, z4, z5, dur_min) {
    tibble::tibble(
      sessionStart = as.POSIXct(date, tz = "UTC"), sport = "running",
      distance = 10000, avgPaceMoving = 5.0, avgHeartRateMoving = 150,
      durationMoving = as.difftime(dur_min, units = "mins"),
      garmin_directWorkoutRpe = NA_real_,
      garmin_hrTimeInZone_1 = z1, garmin_hrTimeInZone_2 = z2,
      garmin_hrTimeInZone_3 = z3, garmin_hrTimeInZone_4 = z4,
      garmin_hrTimeInZone_5 = z5
    )
  }
  on_date <- as.Date("2026-05-07")
  summaries <- dplyr::bind_rows(
    zone_row(on_date - 1, 300, 300, 600, 1200, 600, 50),  # race_pace (Z3)
    zone_row(on_date - 3, 900, 600, 0, 450, 150, 35),     # vo2max (Z3)
    zone_row(on_date - 5, 1200, 2400, 0, 0, 0, 60),       # endurance (Z1)
    zone_row(on_date - 10, 300, 300, 600, 1200, 600, 50)  # outside 7-day window
  )
  expect_equal(session_z3_count(summaries, on_date = on_date, days = 7), 2L)
})

test_that("session_z2_fraction sums Garmin zone 3 over window", {
  zone_row <- function(date, z1, z2, z3, z4, z5) {
    tibble::tibble(
      sessionStart = as.POSIXct(date, tz = "UTC"), sport = "running",
      distance = 10000, avgPaceMoving = 5.0, avgHeartRateMoving = 150,
      durationMoving = as.difftime(60, units = "mins"),
      garmin_hrTimeInZone_1 = z1, garmin_hrTimeInZone_2 = z2,
      garmin_hrTimeInZone_3 = z3, garmin_hrTimeInZone_4 = z4,
      garmin_hrTimeInZone_5 = z5
    )
  }
  on_date <- as.Date("2026-05-07")
  # 3 sessions of equal total time; zone-3 share: 0%, 50%, 25%.
  summaries <- dplyr::bind_rows(
    zone_row(on_date - 1, 1800, 1800, 0, 0, 0),       # 0% Z2
    zone_row(on_date - 5, 600, 600, 1800, 600, 0),    # 50% Z2
    zone_row(on_date - 60, 1800, 600, 1200, 0, 0)     # 33% Z2
  )
  frac <- session_z2_fraction(summaries, on_date = on_date, days = 90)
  # total_sec = 3600 * 3 = 10800; z3 = 0 + 1800 + 1200 = 3000 → 27.78%
  expect_equal(frac, 3000 / 10800, tolerance = 1e-6)
})

test_that("session_prose returns Swedish prose for the latest running run", {
  latest <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-07 18:00", tz = "UTC"),
    sport = "running", distance = 12000,
    avgPaceMoving = 5.0, avgHeartRateMoving = 145,
    durationMoving = as.difftime(60, units = "mins"),
    garmin_directWorkoutRpe = 30,
    garmin_hrTimeInZone_1 = NA_real_, garmin_hrTimeInZone_2 = NA_real_,
    garmin_hrTimeInZone_3 = NA_real_, garmin_hrTimeInZone_4 = NA_real_,
    garmin_hrTimeInZone_5 = NA_real_
  )
  txt <- session_prose(latest, sport = "running", include_tsb = FALSE)
  # RPE 3 → endurance (Z1) on 60 min
  expect_match(txt, "^Distanspass —")
  expect_match(txt, "Låg återhämtningskostnad")
})

test_that("session_prose falls back to legacy line for non-running sport", {
  df <- tibble::tibble(
    sessionStart = as.POSIXct(c("2026-05-06", "2026-05-07"), tz = "UTC"),
    sport = c("cycling", "cycling"),
    distance = c(20000, 25000),
    avgPaceMoving = c(2.5, 2.4),
    avgHeartRateMoving = c(120, 125),
    durationMoving = as.difftime(c(50, 60), units = "mins")
  )
  txt <- session_prose(df, sport = "cycling")
  expect_match(txt, "^Cykling 25 km")
})
