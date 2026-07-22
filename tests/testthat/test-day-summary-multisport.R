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

test_that(".day_alt_class ignores HR that covers less than half the time", {
  # 20 min of measured HR across a 3-hour outing is not an intensity
  # reading for the outing.
  s <- dplyr::bind_rows(
    .ms_session("2026-07-21 09:00", "paddelsporter", km = 3, min = 20,
                hr = 160),
    .ms_session("2026-07-21 10:00", "paddelsporter", km = 12, min = 160,
                hr = NA_real_)
  )
  alt <- traning:::.day_alt_class(s, s, hr_max = 185)
  expect_equal(alt$class, "nohr_very_long")
  expect_true(is.na(alt$intensity))
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
  expect_match(txt, "Dagens pass: paddling 24\\.0 km \\(2 pass\\)")
  expect_match(txt, "Mycket långt lågintensivt pass — stor aerob volym")
  expect_match(txt, "Måttlig återhämtning trots låg intensitet")
  expect_false(grepl("Vilodag", txt))
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
  expect_match(txt, "Dagens pass: löpning 8\\.2 km \\+ styrketräning 45 min")
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
  expect_match(line, "Alternativt: 5,0 h \\([0-9]+ % av veckans belastning\\)")
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
