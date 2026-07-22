# Tests for R/freshness.R — the per-flow data-freshness watchdog.
#
# Regression anchors, all from the 2026 outage:
#   - 2026-06-02  /v1/workouts went quiet while /v1/health kept flowing
#   - 2026-07-11  /v1/health went quiet too
#   - 2026-07-21  the evening summary said "Vilodag." on a day with a
#                 six-hour paddling session

# --- Helpers -------------------------------------------------------------

NOW <- as.POSIXct("2026-07-21 21:30:00", tz = "")

iso_before <- function(hours, now = NOW) {
  format(now - as.difftime(hours, units = "hours"), "%Y-%m-%dT%H:%M:%S")
}

# Receiver payload with per-flow ages in hours; NULL = field absent.
payload <- function(received = NULL, workouts = NULL, now = NOW, ...) {
  c(list(
    last_received = if (is.null(received)) NULL else iso_before(received, now),
    last_workouts_import = if (is.null(workouts)) NULL
                            else iso_before(workouts, now)
  ), list(...))
}

health_at <- function(date) {
  tibble::tibble(date = as.Date(date), metric = "restingHeartRate",
                 value = 48, source = "hae")
}

sessions_at <- function(...) {
  tibble::tibble(sessionStart = as.POSIXct(c(...), tz = ""),
                 sport = "running", distance = 8000)
}

# A directory whose only file has the given mtime.
inbox_at <- function(ts, dir = tempfile()) {
  dir.create(dir, recursive = TRUE)
  f <- file.path(dir, "push.json")
  writeLines("{}", f)
  Sys.setFileTime(f, ts)
  dir
}

hours_ago <- function(h, now = NOW) now - as.difftime(h, units = "hours")

# Assess with no receiver and no inboxes unless explicitly given, so
# every test states its own evidence and none reads the real data root.
assess <- function(..., now = NOW) {
  args <- list(...)
  if (is.null(args$metrics_dir))  args$metrics_dir  <- tempfile()
  if (is.null(args$workouts_dir)) args$workouts_dir <- tempfile()
  if (is.null(args$status_payload)) args$status_fetch <- function() NULL
  do.call(data_freshness, c(args, list(now = now, data_dir = "")))
}

# --- Metric-flow thresholds ----------------------------------------------

test_that("metrics flow is ok well inside the warn threshold", {
  fr <- assess(health_daily = health_at("2026-07-21"))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$metrics$source, "health_cache")
})

test_that("metrics flow treats exactly 36 h as still ok", {
  # Boundaries are exclusive — the watchdog fires *above* the
  # threshold, so a 36.0 h gap must not wake anyone.
  fr <- assess(status_payload = payload(received = 36))
  expect_equal(fr$flows$metrics$status, "ok")
})

test_that("metrics flow warns just past 36 h and fails just past 72 h", {
  warn <- assess(status_payload = payload(received = 36.5))
  fail <- assess(status_payload = payload(received = 72.5))
  expect_equal(warn$flows$metrics$status, "warn")
  expect_equal(fail$flows$metrics$status, "fail")
})

test_that("metrics flow treats exactly 72 h as warn, not fail", {
  fr <- assess(status_payload = payload(received = 72))
  expect_equal(fr$flows$metrics$status, "warn")
})

test_that("metric thresholds are parameters", {
  fr <- assess(status_payload = payload(received = 10),
               metrics_warn_hours = 6, metrics_fail_hours = 8)
  expect_equal(fr$flows$metrics$status, "fail")
})

# --- Workout-flow thresholds ---------------------------------------------

test_that("workouts flow tolerates training-free days when metrics are stale too", {
  # No asymmetry to lean on → the forgiving 96 h / 14 d apply.
  fr <- assess(status_payload = payload(received = 200, workouts = 90))
  expect_equal(fr$flows$metrics$status, "fail")
  expect_equal(fr$flows$workouts$status, "ok")
  expect_false(fr$flows$workouts$tightened)
  expect_equal(fr$flows$workouts$warn_hours, 96)
})

test_that("workouts flow warns past 96 h and fails past 14 d without asymmetry", {
  warn <- assess(status_payload = payload(received = 200, workouts = 100))
  fail <- assess(status_payload = payload(received = 200, workouts = 24 * 15))
  expect_equal(warn$flows$workouts$status, "warn")
  expect_equal(fail$flows$workouts$status, "fail")
})

# --- Asymmetry -----------------------------------------------------------

test_that("a live metric feed tightens the workout thresholds", {
  # The 2026-06-02 fingerprint: metrics arriving, workouts silent. At
  # 60 h the forgiving threshold would still have said ok.
  fr <- assess(status_payload = payload(received = 2, workouts = 60))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$workouts$status, "warn")
  expect_true(fr$flows$workouts$tightened)
  expect_equal(fr$flows$workouts$warn_hours, 48)
  expect_true(fr$asymmetric)
})

test_that("asymmetric silence escalates to fail after a week", {
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 8))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$status, "fail")
})

test_that("the asymmetric wording names the flow and the likely cause", {
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 49))
  expect_match(fr$prose,
    "^Passdata från Apple Health har inte kommit in sedan 2 juni")
  expect_match(fr$prose, "trasig automation")
  expect_match(fr$message, "workouts: silent for")
  expect_match(fr$message, "tightened")
})

test_that("no asymmetry is claimed when both flows are quiet", {
  fr <- assess(status_payload = payload(received = 200, workouts = 400))
  expect_false(fr$asymmetric)
  expect_false(fr$flows$workouts$tightened)
})

# --- The outages this was built for --------------------------------------

test_that("the 2026-06-02 workouts-only outage is caught while metrics flow", {
  # State on 2026-06-09: workouts dead for a week, metrics healthy. A
  # single aggregate signal would have reported ok here.
  on_2026_06_09 <- as.POSIXct("2026-06-09 21:30:00", tz = "")
  fr <- assess(now = on_2026_06_09,
               status_payload = payload(received = 3, workouts = 24 * 7.2,
                                         now = on_2026_06_09))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$status, "fail")
  expect_match(fr$prose, "Passdata")
  expect_no_match(fr$prose, "Hälsodata")
})

test_that("the 2026-07-21 total outage flags both flows, workouts first", {
  fr <- assess(status_payload = payload(received = 24 * 10.6,
                                         workouts = 24 * 49))
  expect_equal(fr$flows$metrics$status, "fail")
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$status, "fail")
  # Workouts is the older silence, so it leads the notification.
  expect_match(fr$prose, "^Passdata")
  expect_match(fr$prose,
    "Hälsodata från Apple Health har inte kommit in sedan 11 juli")
})

# --- Evidence tiering ----------------------------------------------------

test_that("fresh Garmin sessions do not mask a dead HAE workout feed", {
  # summaries also carries the separate Garmin pipeline, so it sits in
  # a weaker tier than the receiver/inbox evidence.
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 30),
               summaries = sessions_at("2026-07-21 08:00:00"))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$flows$workouts$source, "receiver_import")
})

test_that("fresh workout pushes do not mask a dead metric feed", {
  # last_received is bumped by workout pushes too, so it must not
  # stand in for metric evidence when the health cache exists.
  fr <- assess(status_payload = payload(received = 1, workouts = 1),
               health_daily = health_at("2026-07-11"))
  expect_equal(fr$flows$metrics$status, "fail")
  expect_equal(fr$flows$metrics$source, "health_cache")
})

test_that("last_received serves metrics only when nothing local exists", {
  fr <- assess(status_payload = payload(received = 2))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$metrics$source, "receiver_push")
})

test_that("sessions serve workouts only when nothing local exists", {
  fr <- assess(summaries = sessions_at("2026-07-20 08:00:00"))
  expect_equal(fr$flows$workouts$source, "sessions")
  expect_equal(fr$flows$workouts$status, "ok")
})

# --- Inbox mtime fallback ------------------------------------------------

test_that("a null last_workouts_import falls back to the inbox mtime", {
  # /v1/status counters are in-memory and reset on every receiver
  # restart, so null is a normal post-restart state, not an outage.
  fr <- assess(
    status_payload = payload(received = 2, workouts = NULL,
                              uptime_seconds = 42),
    workouts_dir = inbox_at(hours_ago(3)))
  expect_equal(fr$flows$workouts$status, "ok")
  expect_equal(fr$flows$workouts$source, "workout_files")
  expect_equal(fr$details$receiver_uptime_seconds, 42)
})

test_that("the inbox mtime wins when it is fresher than the receiver counter", {
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 10),
               workouts_dir = inbox_at(hours_ago(2)))
  expect_equal(fr$flows$workouts$status, "ok")
  expect_equal(fr$flows$workouts$source, "workout_files")
})

test_that("a stale inbox with a null counter still alarms", {
  fr <- assess(status_payload = payload(received = 2, workouts = NULL),
               workouts_dir = inbox_at(hours_ago(24 * 30)))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$flows$workouts$source, "workout_files")
})

test_that("the metrics inbox is honoured when the cache lags behind it", {
  # Pushes still arriving but the import broke: the inbox is fresher
  # than the cache, and the flow is alive.
  fr <- assess(health_daily = health_at("2026-07-01"),
               metrics_dir = inbox_at(hours_ago(2)))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$metrics$source, "metric_files")
})

test_that("inbox directories are derived from data_dir", {
  root <- withr::local_tempdir()
  inbox_at(hours_ago(2),
           dir = file.path(root, "kristian", "health_export", "workouts"))
  fr <- data_freshness(now = NOW, data_dir = root,
                        status_fetch = function() NULL)
  expect_equal(fr$flows$workouts$source, "workout_files")
  expect_equal(fr$flows$workouts$status, "ok")
})

# --- Unmeasurable --------------------------------------------------------

test_that("data_freshness reports unknown when nothing at all is measurable", {
  fr <- assess()
  expect_equal(fr$flows$metrics$status, "unknown")
  expect_equal(fr$flows$workouts$status, "unknown")
  expect_equal(fr$status, "unknown")
  expect_false(fr$ok)
  expect_true(is.na(fr$last_data))
  expect_match(fr$prose, "går inte att verifiera")
})

test_that("one unknown flow does not hide the other flow's failure", {
  fr <- assess(status_payload = payload(received = 24 * 10))
  expect_equal(fr$flows$metrics$status, "fail")
  expect_equal(fr$flows$workouts$status, "unknown")
  expect_equal(fr$status, "fail")
})

test_that("an unknown flow outranks an ok one", {
  fr <- assess(health_daily = health_at("2026-07-21"))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$workouts$status, "unknown")
  expect_equal(fr$status, "unknown")
  expect_false(fr$ok)
})

test_that("data_freshness survives a status_fetch that signals", {
  fr <- data_freshness(now = NOW, data_dir = "",
                        metrics_dir = tempfile(), workouts_dir = tempfile(),
                        status_fetch = function() stop("connection refused"))
  expect_equal(fr$status, "unknown")
  expect_false(fr$details$receiver_reachable)
})

# --- Wording -------------------------------------------------------------

test_that("healthy flows still produce prose", {
  fr <- assess(status_payload = payload(received = 2, workouts = 3))
  expect_true(fr$ok)
  expect_match(fr$prose, "kom in senast 21 juli")
})

test_that("Swedish month names are locale-independent", {
  # The systemd-launched renderer runs in C locale, where
  # format(., '%B') would yield 'July'.
  withr::with_locale(c(LC_TIME = "C"), {
    fr <- assess(status_payload = payload(received = 24 * 10))
    expect_match(fr$prose, "11 juli")
  })
})

test_that("dates from another year carry the year", {
  fr <- assess(status_payload = payload(received = 24 * 300))
  expect_match(fr$prose, "2025")
})

# --- Receiver probe ------------------------------------------------------

test_that(".receiver_status_url follows the receiver bind env", {
  withr::with_envvar(
    c(TRANING_RECEIVER_HOST = "100.93.126.68", TRANING_RECEIVER_PORT = "8421"),
    expect_equal(.receiver_status_url(),
                 "http://100.93.126.68:8421/v1/status")
  )
  withr::with_envvar(
    c(TRANING_RECEIVER_HOST = "0.0.0.0", TRANING_RECEIVER_PORT = ""),
    expect_equal(.receiver_status_url(), "http://127.0.0.1:8421/v1/status")
  )
})

test_that(".receiver_status returns NULL without an API key", {
  expect_null(.receiver_status(url = "http://127.0.0.1:1/v1/status",
                                api_key = ""))
})

test_that(".receiver_status refuses keys that could inject curl options", {
  expect_null(.receiver_status(url = "http://127.0.0.1:1/v1/status",
                                api_key = "abc\nurl = \"http://evil\""))
})

test_that(".receiver_status returns NULL when nothing is listening", {
  # Port 1 is not bound; curl fails fast and the probe must degrade to
  # NULL rather than signalling.
  expect_null(.receiver_status(url = "http://127.0.0.1:1/v1/status",
                                timeout = 2L, api_key = "deadbeef"))
})

# --- .parse_iso_time -----------------------------------------------------

test_that(".parse_iso_time handles the receiver's formats and junk", {
  expect_equal(format(.parse_iso_time("2026-07-21T20:14:03.123456"),
                       "%Y-%m-%d %H:%M:%S"),
               "2026-07-21 20:14:03")
  expect_equal(format(.parse_iso_time("2026-07-21"), "%Y-%m-%d"),
               "2026-07-21")
  expect_true(is.na(.parse_iso_time(NULL)))
  expect_true(is.na(.parse_iso_time("")))
  expect_true(is.na(.parse_iso_time("not a date")))
})
