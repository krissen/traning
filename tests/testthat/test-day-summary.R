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

  txt <- day_summary_prose(summaries, date = d)
  # Sport mix line present
  expect_match(txt, "Dagens pass")
  expect_match(txt, "löpning 8\\.0 km")
  expect_match(txt, "cykling 6\\.5 km")
  expect_match(txt, "gång 1\\.5 km")
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
  txt <- day_summary_prose(summaries, date = d)
  # "(2 pass)" annotation, total km summed (9.5 km)
  expect_match(txt, "cykling 9\\.5 km \\(2 pass\\)")
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

# --- Readiness data quality --------------------------------------------------
# Regression: the evening push on 2026-07-21 read "Dagsform 🔴 Röd 21 —
# återhämtningssignaler dominerar. Vila eller lugnt imorgon." on a
# one-component verdict. Once the health gap was backfilled the same
# day's actual readiness was 85 Grön — the verdict was inverted, and it
# carried training advice.

readiness_at <- function(status, score, kvalitet, present = character()) {
  comp <- function(name) {
    list(value = if (name %in% present) 1 else NA_real_,
         delta = NA_real_, flag = FALSE, score = NA_real_)
  }
  list(status = status, score = score, kvalitet = kvalitet,
       components = list(hrv = comp("hrv"), sleep = comp("sleep"),
                          rhr = comp("rhr"), load = comp("load")),
       components_present = list())
}

quality_summaries <- function() {
  tibble::tibble(
    sessionStart = as.POSIXct("2026-05-06 18:00", tz = "UTC"),
    sport = "running", distance = 8000,
    avgPaceMoving = 5.5, avgHeartRateMoving = 140,
    durationMoving = as.difftime(45, units = "mins"))
}

test_that("full quality leaves the verdict phrased exactly as before", {
  d <- as.Date("2026-05-08")
  full <- readiness_at("Röd", 40, "full",
                        present = c("hrv", "sleep", "rhr", "load"))
  txt <- .day_state_line(quality_summaries(), health_daily = NULL,
                          on_date = d, readiness = full)
  expect_equal(
    txt,
    paste("Dagsform \U0001F534 Röd 40 — återhämtningssignaler dominerar.",
          "Vila eller lugnt imorgon."))
})

test_that("partial quality keeps the verdict but says what is missing", {
  d <- as.Date("2026-05-08")
  partial <- readiness_at("Gul", 55, "partial",
                           present = c("hrv", "rhr", "load"))
  txt <- .day_state_line(quality_summaries(), health_daily = NULL,
                          on_date = d, readiness = partial)
  expect_match(txt, "Dagsform \U0001F7E1 Gul 55 \\(partial, sömn saknas än\\)")
})

test_that("partial quality still carries the Röd advice", {
  # Partial is thin, not untrustworthy — the advice stands.
  d <- as.Date("2026-05-08")
  partial <- readiness_at("Röd", 35, "partial",
                           present = c("hrv", "rhr", "load"))
  txt <- .day_state_line(quality_summaries(), health_daily = NULL,
                          on_date = d, readiness = partial)
  expect_match(txt, "\\(partial, sömn saknas än\\)")
  expect_match(txt, "Vila eller lugnt imorgon")
})

test_that("minimal quality withholds the verdict, the score and the advice", {
  d <- as.Date("2026-05-08")
  minimal <- readiness_at("Röd", 21, "minimal", present = "load")
  txt <- .day_state_line(quality_summaries(), health_daily = NULL,
                          on_date = d, readiness = minimal)
  expect_match(txt, "^Dagsformen kan inte bedömas")
  expect_match(txt, "HRV/sömn/vilopuls saknas")
  expect_no_match(txt, "Röd")
  expect_no_match(txt, "21")
  expect_no_match(txt, "Vila eller lugnt imorgon")
})

test_that("minimal quality keeps the TSB narrative it falls back on", {
  d <- as.Date("2026-05-08")
  minimal <- readiness_at("Röd", 21, "minimal", present = "load")
  txt <- .day_state_line(quality_summaries(), health_daily = NULL,
                          on_date = d, readiness = minimal)
  # A TSB line is computable from these summaries, so the state line
  # keeps saying something useful rather than going silent.
  expect_gt(nchar(txt), nchar("Dagsformen kan inte bedömas — "))
})

test_that(".readiness_quality_note tolerates an empty component list", {
  # is.na(NULL) is logical(0), which would abort an if-clause.
  note <- .readiness_quality_note("full", list())
  expect_equal(note$suffix, "")
  expect_true(note$trustworthy)
  expect_setequal(note$missing, c("HRV", "sömn", "vilopuls"))
})

test_that(".readiness_quality_note grades trustworthiness by quality alone", {
  expect_true(.readiness_quality_note("full", list())$trustworthy)
  expect_true(.readiness_quality_note("partial", list())$trustworthy)
  expect_false(.readiness_quality_note("minimal", list())$trustworthy)
  expect_true(.readiness_quality_note(NA_character_, list())$trustworthy)
})

# --- Freshness guard ---------------------------------------------------------
# Regression: 2026-07-21 said "Vilodag. Dagsform 🔴 Röd 21 …" on a day
# with a six-hour paddling session, because the HAE workout feed had
# been dead since 2026-06-02 and nothing checked data age.

# The guard only fires for the current day, so these cases have to be
# anchored to today rather than to a fixed calendar date. The exact
# Swedish wording is locked in test-freshness.R; what matters here is
# that day_summary_prose reaches for the workout flow's verdict.
DAY_NOW <- as.POSIXct(paste(Sys.Date(), "21:30:00"), tz = "")

# Build a freshness verdict without touching the network or disk, with
# each flow's last arrival given in hours before DAY_NOW.
day_freshness <- function(received = NULL, workouts = NULL, now = DAY_NOW,
                           pending_workouts = 0) {
  iso <- function(h) {
    if (is.null(h)) return(NULL)
    format(now - as.difftime(h, units = "hours"), "%Y-%m-%dT%H:%M:%S")
  }
  data_freshness(
    now = now, data_dir = "",
    metrics_dir = tempfile(), canonical_dir = tempfile(),
    workouts_dir = tempfile(),
    status_payload = list(last_received = iso(received),
                          last_workouts_import = iso(workouts),
                          pending_workouts = pending_workouts))
}

rest_day_summaries <- function() {
  tibble::tibble(
    sessionStart = as.POSIXct(paste(Sys.Date() - 15, "10:00"), tz = ""),
    sport = "running", distance = 5000,
    avgPaceMoving = 5.0, avgHeartRateMoving = 140,
    durationMoving = as.difftime(28, units = "mins"))
}

test_that("day_summary_prose keeps 'Vilodag.' when the workout feed is fresh", {
  fresh <- day_freshness(received = 2, workouts = 3)
  expect_true(fresh$ok)
  txt <- day_summary_prose(rest_day_summaries(), date = Sys.Date(),
                            freshness = fresh)
  expect_match(txt, "^Vilodag\\.")
})

test_that("a stale metric feed alone does not rewrite a genuine rest day", {
  # Metrics degrade the readiness half of the summary, but they say
  # nothing about whether a session happened.
  fr <- day_freshness(received = 24 * 10, workouts = 3)
  expect_equal(fr$flows$metrics$status, "fail")
  expect_equal(fr$flows$workouts$status, "ok")
  txt <- day_summary_prose(rest_day_summaries(), date = Sys.Date(),
                            freshness = fr)
  expect_match(txt, "^Vilodag\\.")
})

test_that("a queued import stops the day being called rest", {
  # The flow is alive — that is what the queue proves — but the very
  # sessions sitting in it are the ones missing from `summaries`.
  # Health and completeness are different questions.
  pending <- day_freshness(received = 2, workouts = 2, pending_workouts = 12)
  expect_true(pending$flows$workouts$ok)
  expect_true(pending$flows$workouts$in_flight)
  txt <- day_summary_prose(rest_day_summaries(), date = Sys.Date(),
                            freshness = pending)
  expect_no_match(txt, "^Vilodag\\.")
  expect_match(txt, "^Inga registrerade pass —")
  expect_match(txt, "håller fortfarande på att läsas in")
})

test_that("a stuck import surfaces as data-came-in-but-unread, not rest", {
  # Queue non-empty but no recent arrival: the import wedged. The day
  # is not rest, and the prose must point at the importer rather than
  # claim nothing arrived.
  stuck <- day_freshness(received = 2, workouts = 24 * 10,
                          pending_workouts = 12)
  expect_equal(stuck$flows$workouts$queue_state, "stuck")
  txt <- day_summary_prose(rest_day_summaries(), date = Sys.Date(),
                            freshness = stuck)
  expect_no_match(txt, "^Vilodag\\.")
  expect_match(txt, "^Inga registrerade pass —")
  expect_match(txt, "har kommit in men inte kunnat läsas in")
})

test_that("an emptied queue leaves a genuine rest day alone", {
  # The distinction is undelivered work *now*, not a flush that
  # recently completed — otherwise every rest day after an import
  # would read as suspect.
  flushed <- day_freshness(received = 2, workouts = 2, pending_workouts = 0)
  expect_false(flushed$flows$workouts$in_flight)
  txt <- day_summary_prose(rest_day_summaries(), date = Sys.Date(),
                            freshness = flushed)
  expect_match(txt, "^Vilodag\\.")
})

test_that("an armed import timer also blocks the rest-day claim", {
  pending <- day_freshness(received = 2, workouts = 2)
  pending$flows$workouts$in_flight <- TRUE
  pending$flows$workouts$prose_pending <- "test-vokabulär"
  guard <- .day_freshness_guard(Sys.Date(), NULL, NULL, freshness = pending)
  expect_false(is.null(guard))
  expect_equal(guard$prose, "test-vokabulär")
})

test_that("day_summary_prose flags a dead workout feed instead of claiming rest", {
  # The real outage: metrics still arriving, workouts silent for weeks.
  stale <- day_freshness(received = 2, workouts = 24 * 49)
  expect_equal(stale$flows$workouts$status, "fail")
  txt <- day_summary_prose(rest_day_summaries(), date = Sys.Date(),
                            freshness = stale)
  expect_no_match(txt, "^Vilodag\\.")
  expect_match(txt, "^Inga registrerade pass —")
  expect_true(grepl(stale$flows$workouts$prose, txt, fixed = TRUE))
})

test_that("day_summary_prose flags a dead workout feed on empty summaries too", {
  stale <- day_freshness(received = 2, workouts = 24 * 49)
  txt <- day_summary_prose(NULL, date = Sys.Date(), freshness = stale)
  expect_match(txt, "^Inga registrerade pass —")
})

test_that("day_summary_prose leaves an actual training day untouched", {
  # The guard only applies to zero-session days — a stale feed must
  # not rewrite a day that does have sessions.
  s <- tibble::tibble(
    sessionStart = as.POSIXct(paste(Sys.Date(), "08:00"), tz = ""),
    sport = "running", distance = 8000,
    avgPaceMoving = 5.5, avgHeartRateMoving = 140,
    durationMoving = as.difftime(45, units = "mins"))
  stale <- day_freshness(received = 2, workouts = 24 * 49)
  txt <- day_summary_prose(s, date = Sys.Date(), freshness = stale)
  expect_match(txt, "Dagens pass")
  expect_no_match(txt, "Inga registrerade pass")
})

test_that("an injected verdict does not escape the historical date gate", {
  # The gate is unconditional: a supplied freshness list is a test
  # seam, not a way past the invariant that only today is guarded.
  stale <- day_freshness(received = 2, workouts = 24 * 49)
  expect_null(.day_freshness_guard(Sys.Date() - 30, NULL, NULL,
                                    freshness = stale))
  txt <- day_summary_prose(rest_day_summaries(), date = "2026-05-08",
                            freshness = stale)
  expect_match(txt, "^Vilodag\\.")
})

test_that(".day_freshness_guard leaves historical rest days alone", {
  # Without the date gate, today's dead feed would retro-flag every
  # rest day in the archive.
  expect_null(.day_freshness_guard(Sys.Date() - 30, NULL, NULL))
})

test_that(".day_freshness_guard never signals when the probe blows up", {
  # The 21:30 notification matters more than the watchdog.
  local_mocked_bindings(
    data_freshness = function(...) stop("boom"),
    .package = "traning"
  )
  expect_null(.day_freshness_guard(Sys.Date(), NULL, NULL))
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
