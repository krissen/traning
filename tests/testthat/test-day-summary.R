test_that("day_summary_prose returns 'Vilodag.' on empty summaries", {
  expect_match(
    day_summary_prose(NULL, date = "2026-05-08"),
    "^Vilodag\\."
  )
  empty <- tibble::tibble(
    sessionStart = as.POSIXct(character(0), tz = "UTC"),
    sport = character(0), distance = numeric(0),
    avgPaceMoving = numeric(0), avgHeartRateMoving = numeric(0),
    durationMoving = as.difftime(numeric(0), units = "mins")
  )
  expect_match(day_summary_prose(empty, date = "2026-05-08"), "^Vilodag\\.")
})

test_that("day_summary_prose includes sport mix and dominant type", {
  d <- as.Date("2026-05-08")
  s <- function(date_str, sport, km, min, hr = NA_real_, pace = NA_real_,
                z1 = NA_real_, z2 = NA_real_, z3 = NA_real_,
                z4 = NA_real_, z5 = NA_real_, rpe = NA_real_) {
    tibble::tibble(
      sessionStart = as.POSIXct(date_str, tz = "UTC"),
      sport = sport, distance = km * 1000,
      avgPaceMoving = pace, avgHeartRateMoving = hr,
      durationMoving = as.difftime(min, units = "mins"),
      garmin_directWorkoutRpe = rpe,
      garmin_hrTimeInZone_1 = z1, garmin_hrTimeInZone_2 = z2,
      garmin_hrTimeInZone_3 = z3, garmin_hrTimeInZone_4 = z4,
      garmin_hrTimeInZone_5 = z5
    )
  }

  # One Z1 endurance run + one cycling commute + a walk on the same day.
  summaries <- dplyr::bind_rows(
    s("2026-05-08 07:30", "running", 8.0, 50, hr = 130, pace = 6.0,
      z1 = 1200, z2 = 1800, z3 = 0, z4 = 0, z5 = 0, rpe = 30),
    s("2026-05-08 12:15", "cycling", 6.5, 25, hr = 120),
    s("2026-05-08 18:45", "walking", 1.5, 18, hr = 95)
  )

  # Anchors passed explicitly: without them the fixture (no garmin_maxHR,
  # no TRANING_DATA) makes every HRmax and HRrest lookup warn.
  txt <- day_summary_prose(summaries, date = d, hr_max = 185, hr_rest = 50)
  # Sport mix line present
  expect_match(txt, "Dagens pass")
  expect_match(txt, "löpning 8,0 km")
  expect_match(txt, "cykling 6,5 km")
  expect_match(txt, "gång 1,5 km")
  # Endurance label (RPE 30 → endurance per classify_session)
  expect_match(txt, "Distanspass")
})

test_that("day_summary_prose annotates pass-count for repeat sports", {
  d <- as.Date("2026-05-08")
  mk <- function(time_str, sport, km, min) {
    tibble::tibble(
      sessionStart = as.POSIXct(time_str, tz = "UTC"),
      sport = sport, distance = km * 1000,
      avgPaceMoving = NA_real_, avgHeartRateMoving = NA_real_,
      durationMoving = as.difftime(min, units = "mins")
    )
  }
  # Two cycling segments (HAE-style auto-pause split)
  summaries <- dplyr::bind_rows(
    mk("2026-05-08 08:00", "cycling", 4.0, 20),
    mk("2026-05-08 17:30", "cycling", 5.5, 30)
  )
  # Anchors passed explicitly: without them the fixture (no garmin_maxHR,
  # no TRANING_DATA) makes every HRmax and HRrest lookup warn.
  txt <- day_summary_prose(summaries, date = d, hr_max = 185, hr_rest = 50)
  # "(2 pass)" annotation, total km summed (9.5 km)
  expect_match(txt, "cykling 9,5 km \\(2 pass\\)")
})

test_that(".day_state_line: Röd readiness overrides TSB form claim", {
  # Regression: 2026-05-09 morning notification flagged Röd
  # (HRV 32 ms, -56 vs 7d) but day-summary said "Form på topp"
  # because TSB was +11. Readiness must override the TSB phrasing.
  d <- as.Date("2026-05-08")
  s <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-06 18:00", tz = "UTC"),
    sport = "running", distance = 8000,
    avgPaceMoving = 5.5, avgHeartRateMoving = 140,
    durationMoving = as.difftime(45, units = "mins")
  )
  # Inject a Red readiness verdict directly to bypass the
  # readiness-computation pipeline (tested elsewhere).
  red <- list(status = "Röd", score = 40,
              kvalitet = "full", components = list(),
              components_present = list())
  txt <- .day_state_line(s, health_daily = NULL, on_date = d,
                          readiness = red)
  expect_false(grepl("Form på topp", txt %||% ""),
               info = paste("Got:", txt))
  expect_match(txt %||% "", "Röd 40")
  expect_match(txt %||% "", "återhämtningssignaler dominerar")
})

test_that(".day_state_line: Gul readiness prepends to TSB text", {
  d <- as.Date("2026-05-08")
  s <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-06 18:00", tz = "UTC"),
    sport = "running", distance = 8000,
    avgPaceMoving = 5.5, avgHeartRateMoving = 140,
    durationMoving = as.difftime(45, units = "mins")
  )
  yellow <- list(status = "Gul", score = 55, kvalitet = "full",
                 components = list(), components_present = list())
  txt <- .day_state_line(s, health_daily = NULL, on_date = d,
                          readiness = yellow)
  expect_match(txt %||% "", "Gul 55")
})

test_that(".day_state_line: Grön readiness keeps TSB phrasing", {
  d <- as.Date("2026-05-08")
  s <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-06 18:00", tz = "UTC"),
    sport = "running", distance = 8000,
    avgPaceMoving = 5.5, avgHeartRateMoving = 140,
    durationMoving = as.difftime(45, units = "mins")
  )
  green <- list(status = "Grön", score = 85, kvalitet = "full",
                components = list(), components_present = list())
  txt <- .day_state_line(s, health_daily = NULL, on_date = d,
                          readiness = green)
  # Grön means TSB phrasing represents the day fine — Dagsform
  # text not added.
  expect_false(grepl("Dagsform", txt %||% ""))
})

test_that("day_summary_prose returns 'Vilodag.' when no sessions on the date", {
  # Sessions exist on other days but not on the requested date.
  s <- tibble::tibble(
    sessionStart = as.POSIXct("2026-05-06 10:00", tz = "UTC"),
    sport = "running", distance = 5000,
    avgPaceMoving = 5.0, avgHeartRateMoving = 140,
    durationMoving = as.difftime(28, units = "mins")
  )
  txt <- day_summary_prose(s, date = "2026-05-08")
  expect_match(txt, "^Vilodag\\.")
})
