# Tests for the sport-agnostic parts of R/day_summary.R:
# the alternative-training purpose line and the week line.

.ms_session <- function(time_str, sport, km = 0, min = 60, hr = NA_real_,
                        rpe = NA_real_) {
  tibble::tibble(
    sessionStart = as.POSIXct(time_str, tz = "UTC"),
    sport = sport,
    distance = km * 1000,
    avgPaceMoving = NA_real_,
    avgHeartRateMoving = hr,
    durationMoving = as.difftime(min, units = "mins"),
    garmin_directWorkoutRpe = rpe
  )
}

# Prose helper: run the day-summary without the form line, which needs
# PMC / readiness data these fixtures don't carry.
.ms_prose <- function(summaries, date, hr_max = 185) {
  suppressMessages(
    day_summary_prose(summaries, date = date, hr_max = hr_max,
                      hr_rest = 50, health_daily = NULL)
  )
}

# --- Duration formatting -----------------------------------------------------

test_that(".fmt_duration_sv reads durations the way the prose says them", {
  expect_equal(traning:::.fmt_duration_sv(45), "45 min")
  expect_equal(traning:::.fmt_duration_sv(89), "89 min")
  expect_equal(traning:::.fmt_duration_sv(90), "1 h 30 min")
  expect_equal(traning:::.fmt_duration_sv(135), "2 h 15 min")
  # Rounds up to a whole hour when the remainder is under 5 min
  expect_equal(traning:::.fmt_duration_sv(358), "6 h")
  expect_equal(traning:::.fmt_duration_sv(360), "6 h")
  # No "1 h 60 min" at the rollover
  expect_equal(traning:::.fmt_duration_sv(119.9), "2 h")
  expect_true(is.na(traning:::.fmt_duration_sv(NA_real_)))
})

# --- Swedish decimal comma ---------------------------------------------------

test_that("fmt_dec_sv renders Swedish decimals", {
  expect_equal(traning:::fmt_dec_sv(26.0), "26,0")
  expect_equal(traning:::fmt_dec_sv(9.75), "9,8")
  expect_equal(traning:::fmt_dec_sv(3.2, signed = TRUE), "+3,2")
  expect_equal(traning:::fmt_dec_sv(-0.5, signed = TRUE), "-0,5")
  expect_true(is.na(traning:::fmt_dec_sv(NA_real_)))
})

test_that("one notification never mixes decimal separators", {
  # Regression: the sport line rendered "26.0 km" while the week line
  # rendered "9,8 h" in the same sentence.
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-19 07:00", "running", km = 12.4, min = 70,
                hr = 150),
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 26, min = 365,
                hr = 83)
  )
  txt <- .ms_prose(s, d)
  expect_false(grepl("[0-9]\\.[0-9]", txt),
               info = paste("decimal point in Swedish prose:", txt))
  expect_true(grepl("[0-9],[0-9]", txt))
})

# --- Sport line --------------------------------------------------------------

test_that("long efforts show both distance and time", {
  d <- as.Date("2026-07-21")
  s <- .ms_session("2026-07-21 09:00", "paddelsporter", km = 26, min = 365,
                   hr = 83)
  txt <- .ms_prose(s, d)
  expect_match(txt, "Dagens pass: paddling 26,0 km / 6 h 5 min\\.")
})

test_that("a long run gets the same treatment as a long paddle", {
  d <- as.Date("2026-07-21")
  s <- .ms_session("2026-07-21 09:00", "running", km = 24, min = 150,
                   hr = 140)
  txt <- .ms_prose(s, d)
  expect_match(txt, "löpning 24,0 km / 2 h 30 min")
})

test_that("short efforts keep the distance-only wording", {
  d <- as.Date("2026-07-21")
  s <- .ms_session("2026-07-21 09:00", "running", km = 10, min = 55,
                   hr = 140)
  txt <- .ms_prose(s, d)
  expect_match(txt, "löpning 10,0 km\\.")
  expect_false(grepl("/", txt, fixed = TRUE))
})

test_that("sports without a distance are described by time alone", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "yoga", km = 0, min = 40, hr = 90),
    .ms_session("2026-07-21 18:00", "karntraning", km = 0, min = 100,
                hr = 95)
  )
  txt <- .ms_prose(s, d)
  expect_match(txt, "yoga 40 min")
  expect_match(txt, "kärnträning 1 h 40 min")
})

# --- Dominant alternative session -------------------------------------------

test_that(".day_alt_class aggregates auto-pause segments per sport", {
  # A six-hour paddle logged as three HAE segments must classify as one
  # very long session, not as the longest segment.
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 8, min = 115,
                hr = 120),
    .ms_session("2026-07-21 12:00", "paddelsporter", km = 8, min = 110,
                hr = 120),
    .ms_session("2026-07-21 15:00", "paddelsporter", km = 8, min = 135,
                hr = 120)
  )
  alt <- traning:::.day_alt_class(s, s, hr_max = 185)
  expect_equal(alt$sport, "paddelsporter")
  expect_equal(alt$duration_min, 360)
  expect_equal(alt$class, "low_very_long")
})

test_that(".day_alt_class picks the highest recovery cost, then the longest", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "walking", km = 5, min = 120, hr = 100),
    .ms_session("2026-07-21 18:00", "fotboll", min = 60, hr = 170)
  )
  alt <- traning:::.day_alt_class(s, s, hr_max = 185)
  # Football is "hard" → high cost; walking is long but only moderate.
  expect_equal(alt$sport, "fotboll")
  expect_equal(alt$recovery_cost, "high")
})

test_that(".day_alt_class ignores running and sub-20-minute efforts", {
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "running", km = 10, min = 55, hr = 150),
    .ms_session("2026-07-21 18:00", "karntraning", min = 8, hr = 110)
  )
  expect_null(traning:::.day_alt_class(s, s, hr_max = 185))
})

test_that("a qualifying HR segment sets intensity even if most of the day lacks HR", {
  # A measured 20-min block at 160 bpm (160/185 = 0.86 → moderate) is a
  # real intensity reading for that block, so the unit is moderate — the
  # approved "overstate hardness, never hide it" rule. The old
  # coverage-guard behaviour (calling this nohr) is exactly the kind of
  # smoothing finding 002 objected to.
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 3, min = 20,
                hr = 160),
    .ms_session("2026-07-21 10:00", "paddelsporter", km = 12, min = 160,
                hr = NA_real_)
  )
  alt <- traning:::.day_alt_class(s, s, hr_max = 185)
  expect_equal(alt$class, "moderate_very_long")
  expect_equal(alt$intensity, "moderate")
})

test_that("a unit whose only HR segments are sub-floor claims no intensity", {
  # No segment exceeds the 10-min TRIMP floor, so none contributes load.
  # Intensity must not be derived from those rows — otherwise the unit
  # could read hard while compute_trimp() scored it zero. It reads nohr,
  # which is what the load model gives it too.
  all_hr <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 1, min = 8,
                hr = 170),
    .ms_session("2026-07-21 10:00", "paddelsporter", km = 1, min = 6,
                hr = 170)
  )
  # 14 min total, all with HR, but every segment <= 10 min → nohr
  alt_a <- traning:::.day_alt_class(all_hr, all_hr, hr_max = 185,
                                    min_minutes = 10)
  expect_true(is.na(alt_a$intensity))
  expect_true(startsWith(alt_a$class, "nohr_"))

  # A single segment at exactly the floor (10 min) also does not
  # qualify — compute_trimp() uses `> 10`, so the two agree at the edge.
  edge <- .ms_session("2026-07-21 09:00", "paddelsporter", km = 2, min = 10,
                      hr = 170)
  alt_e <- traning:::.day_alt_class(edge, edge, hr_max = 185,
                                    min_minutes = 10)
  expect_true(is.na(alt_e$intensity))
})

# --- Alternative-training prose ---------------------------------------------

test_that("a paddling day gets alternative prose instead of a bare sport line", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 8, min = 120,
                hr = 120),
    .ms_session("2026-07-21 13:00", "paddelsporter", km = 16, min = 240,
                hr = 120)
  )
  txt <- .ms_prose(s, d)
  expect_match(txt, "Dagens pass: paddling 24,0 km / 6 h \\(2 pass\\)")
  expect_match(txt, "Mycket långt lågintensivt pass — stor aerob volym")
  expect_match(txt, "Måttlig återhämtning trots låg intensitet")
  expect_false(grepl("Vilodag", txt))
})

test_that("a run plus an NA-sport session still gets a summary", {
  # Regression (issue-008): str_detect on an NA sport is NA, and the
  # un-guarded sum made n_running NA, so `n_running > 1` errored and the
  # whole summary was dropped — a run hidden behind an unmapped session.
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 07:00", "running", km = 8, min = 45, hr = 140,
                rpe = 30),
    .ms_session("2026-07-21 18:00", NA_character_, km = 4, min = 40, hr = 120)
  )
  txt <- .ms_prose(s, d)
  expect_false(grepl("Vilodag", txt))
  expect_match(txt, "löpning 8,0 km")
  expect_match(txt, "Distanspass")
})

test_that("an active day whose rows lack the HR column still gets a summary", {
  # Regression (issue-006 P2): .day_sport_units() read avgHeartRateMoving
  # unconditionally, so a legacy/manual summaries frame without that
  # column crashed day_summary_prose() and the "Tidigare idag" line
  # before reaching the intended no-HR path. A missing HR column must
  # degrade like a missing HR value.
  d <- as.Date("2026-07-21")
  s <- tibble::tibble(
    sessionStart = as.POSIXct(c("2026-07-21 09:00", "2026-07-21 18:00"),
                              tz = "UTC"),
    sport = c("cycling", "walking"),
    distance = c(20000, 3000),
    avgPaceMoving = NA_real_,
    durationMoving = as.difftime(c(60, 30), units = "mins")
  )
  expect_false("avgHeartRateMoving" %in% names(s))
  txt <- .ms_prose(s, d)
  expect_false(grepl("Vilodag", txt))
  expect_match(txt, "cykling 20,0 km")
  # No invented intensity — the no-HR path, reached rather than crashed
  expect_false(grepl("lugnt|hårt|mellanzon", txt, ignore.case = TRUE))

  # The shared "Tidigare idag" surface takes the same frame
  ctx <- traning:::.session_today_context_line(s)
  expect_match(ctx, "Tidigare idag: cykling 20,0 km")

  # Distance column absent too → time-only, still no crash
  s2 <- s
  s2$distance <- NULL
  expect_match(.ms_prose(s2, d), "cykling 60 min")
})

test_that("a paddling day without HR makes no intensity claim", {
  d <- as.Date("2026-07-21")
  s <- .ms_session("2026-07-21 09:00", "paddelsporter", km = 24, min = 360,
                   hr = NA_real_)
  txt <- .ms_prose(s, d)
  expect_match(txt, "Paddling 6 h — stor volym i veckan")
  for (word in c("lugnt", "Lugnt", "hårt", "Hårt", "måttlig", "Måttlig",
                 "lågintensivt", "aerob")) {
    expect_false(grepl(word, txt, fixed = TRUE),
                 info = paste("intensity word leaked:", word, "in:", txt))
  }
})

test_that("intermittent sports at low HR never get called 'lugnt'", {
  d <- as.Date("2026-07-21")
  s <- .ms_session("2026-07-21 18:00", "strength", min = 45, hr = 118)
  txt <- .ms_prose(s, d)
  expect_match(txt, "Styrketräning 45 min — med i veckans totalbelastning")
  expect_false(grepl("lugnt", txt, ignore.case = TRUE))
  expect_false(grepl("utanför löpdosen", txt))
})

test_that("a hard ball-sport session is called quality and costs recovery", {
  d <- as.Date("2026-07-21")
  s <- .ms_session("2026-07-21 19:00", "fotboll", min = 60, hr = 165)
  txt <- .ms_prose(s, d)
  expect_match(txt, "Fotboll på hög puls — räknas som kvalitet i veckans dos")
  expect_match(txt, "Hög återhämtningskostnad")
})

test_that("a mixed day describes both the run and the alternative session", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 07:00", "running", km = 8.2, min = 45, hr = 140,
                rpe = 30),
    .ms_session("2026-07-21 18:00", "strength", min = 45, hr = 118)
  )
  txt <- .ms_prose(s, d)
  expect_match(txt, "Dagens pass: löpning 8,2 km \\+ styrketräning 45 min")
  expect_match(txt, "Distanspass")
  expect_match(txt, "Styrketräning 45 min — med i veckans totalbelastning")
  # Running first, alternative second
  expect_lt(regexpr("Distanspass", txt), regexpr("Styrketräning 45 min", txt))
})

test_that("the recovery fragment is dropped when the run already claims it", {
  d <- as.Date("2026-07-21")
  # RPE 90 → vo2max → high recovery cost for the run; a long low-intensity
  # walk would otherwise add a moderate-cost line saying the same thing.
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 07:00", "running", km = 12, min = 60, hr = 170,
                rpe = 90),
    .ms_session("2026-07-21 15:00", "walking", km = 8, min = 120, hr = 100)
  )
  txt <- .ms_prose(s, d)
  expect_match(txt, "Mycket långt lågintensivt pass")
  expect_false(grepl("Måttlig återhämtning", txt))
})

# --- Week line ---------------------------------------------------------------

test_that("running-specific week metrics are labelled as such", {
  d <- as.Date("2026-07-21")
  # Two Z3 runs in the window (RPE 90 → vo2max → Z3)
  s <- dplyr::bind_rows(
    .ms_session("2026-07-18 07:00", "running", km = 10, min = 50, hr = 170,
                rpe = 90),
    .ms_session("2026-07-20 07:00", "running", km = 10, min = 50, hr = 170,
                rpe = 90)
  )
  line <- traning:::.day_week_line(s, d, hr_max = 185, hr_rest = 50,
                                  hr_max_alt = 185)
  expect_match(line, "Veckan \\(löpning\\): 2 kvalitetspass")
})

test_that("three hard sessions of any sport trigger the overload warning", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-16 19:00", "fotboll", min = 60, hr = 168),
    .ms_session("2026-07-18 19:00", "fotboll", min = 60, hr = 168),
    .ms_session("2026-07-20 19:00", "fotboll", min = 60, hr = 168)
  )
  line <- traning:::.day_week_line(s, d, hr_max = 185, hr_rest = 50,
                                  hr_max_alt = 185)
  expect_match(line, "3 hårda pass totalt \\(0 löpning, 3 alternativt\\)")
})

test_that("a single hard alternative session is added to the running count", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-18 07:00", "running", km = 10, min = 50, hr = 170,
                rpe = 90),
    .ms_session("2026-07-20 19:00", "fotboll", min = 60, hr = 168)
  )
  line <- traning:::.day_week_line(s, d, hr_max = 185, hr_rest = 50,
                                  hr_max_alt = 185)
  expect_match(line, "Veckan \\(löpning\\): 1 kvalitetspass")
  expect_match(line, "Plus 1 hårt alternativpass")
})

test_that("the weekly alternative dose is reported in hours and load share", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-19 07:00", "running", km = 10, min = 60, hr = 150),
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 24, min = 300,
                hr = 120)
  )
  line <- traning:::.day_week_line(s, d, hr_max = 185, hr_rest = 50,
                                  hr_max_alt = 185)
  expect_match(line, "Alternativt: 5,0 h \\([0-9]+% av veckans belastning\\)")
})

test_that("the load share is withheld when a quarter of the time lacks HR", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-19 07:00", "running", km = 10, min = 60, hr = 150),
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 24, min = 300,
                hr = NA_real_)
  )
  line <- traning:::.day_week_line(s, d, hr_max = 185, hr_rest = 50,
                                  hr_max_alt = 185)
  expect_match(line, "Alternativt: 5,0 h\\.")
  expect_false(grepl("av veckans belastning", line))
})

test_that("a small alternative dose is not mentioned", {
  d <- as.Date("2026-07-21")
  s <- dplyr::bind_rows(
    .ms_session("2026-07-19 07:00", "running", km = 12, min = 70, hr = 150),
    .ms_session("2026-07-20 07:00", "running", km = 12, min = 70, hr = 150),
    .ms_session("2026-07-21 18:00", "karntraning", min = 25, hr = 100)
  )
  stats <- traning:::.alt_week_stats(s, d, hr_max = 185, hr_rest = 50)
  expect_lt(stats$share, 0.25)
  expect_lt(stats$hours, 3)
  expect_null(traning:::.alt_week_dose_line(stats))
})

# --- The 2026-07-21 paddling session, as imported ---------------------------
#
# A six-hour paddle performed on 2026-07-21. It did not reach the cache
# until 2026-07-22, seven weeks after the data inflow had stalled, so
# the evening summary that day said "Vilodag." — because the row was
# missing, not because of anything in it. Once imported the row reads
# (verified against the kailash cache):
#   sessionStart 2026-07-21 12:10:31, sport "paddelsporter",
#   durationMoving 365.0 min, distance 25 965 m, avgHeartRate 82.6.
# Rounded here to the values a human would read off the summary.
.paddle_20260721 <- function() {
  tibble::tibble(
    sessionStart = as.POSIXct("2026-07-21 12:10:31", tz = "UTC"),
    sport = "paddelsporter",
    distance = 25965,
    avgPaceMoving = NA_real_,
    avgHeartRate = 82.6,
    avgHeartRateMoving = 82.6,
    durationMoving = as.difftime(365, units = "mins"),
    duration = as.difftime(365, units = "mins"),
    garmin_directWorkoutRpe = NA_real_,
    source = "hae"
  )
}

test_that("the 2026-07-21 paddling session is named, timed and classified", {
  txt <- .ms_prose(.paddle_20260721(), as.Date("2026-07-21"))

  # 1. Swedish label, not the raw slug
  expect_match(txt, "paddling")
  expect_false(grepl("paddelsporter", txt))
  # 2. Distance and time both present
  expect_match(txt, "Dagens pass: paddling 26,0 km / 6 h 5 min\\.")
  # 3. Qualitative class: 82.6 bpm is low intensity even against a
  #    conservative HRmax, and 365 min is the top duration band.
  expect_match(txt, "Mycket långt lågintensivt pass — stor aerob volym")
  expect_match(txt, "Måttlig återhämtning trots låg intensitet")
  # 4. Not a rest day
  expect_false(grepl("Vilodag", txt))
})

test_that("the paddling session is classified low even at HRmax 139", {
  # 139 bpm was the session max; anchoring on it is the most
  # conservative HRmax available, and 82.6 / 139 = 0.59 is still low.
  cls <- classify_alt_session(.paddle_20260721(), hr_max = 139)
  expect_equal(cls$intensity, "low")
  expect_equal(cls$class, "low_very_long")
  expect_equal(cls$recovery_cost, "moderate")
})

test_that("the paddling session contributes load without a compute_trimp change", {
  # TRIMP parity: compute_trimp() is purely HR-based and already
  # defaults to sport = "all", so a non-running session with HR and
  # more than 10 minutes counts in full. Verified rather than changed.
  s <- .paddle_20260721()
  trimp <- compute_trimp(s, hr_max = 185, hr_rest = 50)
  expect_equal(nrow(trimp), 1)
  expect_equal(trimp$date, as.Date("2026-07-21"))
  expect_gt(trimp$daily_trimp, 0)

  # The same figure comes out when the bucket is narrowed to endurance,
  # which paddling now belongs to.
  trimp_end <- compute_trimp(s, hr_max = 185, hr_rest = 50,
                             sport = "endurance")
  expect_equal(trimp_end$daily_trimp, trimp$daily_trimp)

  # And it reaches the fitness curve.
  pmc <- compute_pmc(s, hr_max = 185, hr_rest = 50)
  expect_gt(pmc$ctl[pmc$date == as.Date("2026-07-21")], 0)
})

test_that("the week line labels its running-only metrics on a paddling week", {
  # The rolling Z2 fraction counts running sessions only; on a week
  # whose training was paddling it must not claim to describe the week.
  d <- as.Date("2026-07-21")
  zone_run <- function(time_str, z2_sec, z3_sec) {
    tibble::tibble(
      sessionStart = as.POSIXct(time_str, tz = "UTC"),
      sport = "running", distance = 10000,
      avgPaceMoving = NA_real_, avgHeartRateMoving = 150,
      durationMoving = as.difftime(60, units = "mins"),
      garmin_directWorkoutRpe = NA_real_,
      garmin_hrTimeInZone_1 = 600, garmin_hrTimeInZone_2 = 600,
      garmin_hrTimeInZone_3 = z2_sec, garmin_hrTimeInZone_4 = z3_sec,
      garmin_hrTimeInZone_5 = 0
    )
  }
  s <- dplyr::bind_rows(
    zone_run("2026-07-15 07:00", 2400, 0),
    .paddle_20260721()
  )
  line <- traning:::.day_week_line(s, d, hr_max = 185, hr_rest = 50,
                                  hr_max_alt = 185)
  expect_match(line, "Mellanzon-andel \\(löpning\\) [0-9]+%")
  expect_match(line, "Alternativt: 6,1 h")
})
