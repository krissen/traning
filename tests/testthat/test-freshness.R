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
#
# `workouts` is the workout flow's last *successful* import — the signal
# the watchdog actually uses as arrival evidence — and defaults
# `import_ok`. `attempt` sets the raw last_workouts_import (last
# attempt, bumped on failures too); it exists only to prove that field
# is ignored as arrival evidence.
payload <- function(received = NULL, workouts = NULL, import_ok = workouts,
                    attempt = NULL, now = NOW, ...) {
  c(list(
    last_received = if (is.null(received)) NULL else iso_before(received, now),
    last_workouts_import = if (is.null(attempt)) NULL
                            else iso_before(attempt, now),
    last_workouts_import_ok = if (is.null(import_ok)) NULL
                              else iso_before(import_ok, now)
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

# A flat inbox whose last write happened at `ts` — both the file and
# the directory, since a directory whose newest entry is a month old
# has a month-old mtime too.
inbox_at <- function(ts, dir = tempfile()) {
  dir.create(dir, recursive = TRUE)
  f <- file.path(dir, "push.json")
  writeLines("{}", f)
  Sys.setFileTime(f, ts)
  Sys.setFileTime(dir, ts)
  dir
}

# A canonical-shaped tree: canonical/<metric>/<date>.json, with the
# newest write in one of the per-metric subdirectories.
canonical_at <- function(ts, dir = tempfile(), metrics = c("hrv", "steps")) {
  for (m in metrics) {
    sub <- file.path(dir, m)
    dir.create(sub, recursive = TRUE)
    f <- file.path(sub, "2026-07-21.json")
    writeLines("{}", f)
    Sys.setFileTime(f, ts)
    Sys.setFileTime(sub, ts)
  }
  Sys.setFileTime(dir, ts)
  dir
}

hours_ago <- function(h, now = NOW) now - as.difftime(h, units = "hours")

# Assess with no receiver and no inboxes unless explicitly given, so
# every test states its own evidence and none reads the real data root.
assess <- function(..., now = NOW) {
  args <- list(...)
  if (is.null(args$metrics_dir))   args$metrics_dir   <- tempfile()
  if (is.null(args$canonical_dir)) args$canonical_dir <- tempfile()
  if (is.null(args$workouts_dir))  args$workouts_dir  <- tempfile()
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

test_that("the asymmetric wording names the flow and, at fail, the cause", {
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 49))
  expect_match(fr$prose,
    "^Passdata från Apple Health har inte kommit in sedan 2 juni")
  expect_match(fr$prose, "trasig automation")
  expect_match(fr$message, "workouts: silent for")
  expect_match(fr$message, "tightened")
})

test_that("at warn the asymmetry is stated as an observation, not a cause", {
  # The eight-day training break in Oct--Nov 2024 sat in this band for
  # six consecutive days. Observing the silence is fair there; blaming
  # an automation is not.
  fr <- assess(status_payload = payload(received = 2, workouts = 60))
  expect_equal(fr$flows$workouts$status, "warn")
  expect_match(fr$prose, "medan hälsodata fortsätter komma in")
  expect_no_match(fr$prose, "trasig automation")
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

# --- Waking up and backfilling -------------------------------------------
# Empirical: after the phone app was reopened on 2026-07-21 the first
# metric push landed 19:01:41 and the first workout push 19:15:10, then
# workouts drained a ~50-day gap chronologically (+210 files in one
# sweep, 216 queued for import).

test_that("a draining queue with recent successful imports reads as in progress", {
  # Arrivals recent, queue non-empty, and imports still succeeding: the
  # backfill is actively landing. Alive (doctor keeps ok) but the
  # material is not yet complete (evening prose says so).
  fr <- assess(status_payload = payload(received = 2, workouts = 2,
                                         import_ok = 1, pending_workouts = 216))
  expect_equal(fr$flows$workouts$status, "ok")
  expect_equal(fr$flows$workouts$queue_state, "in_progress")
  expect_true(fr$flows$workouts$in_flight)
  expect_match(fr$flows$workouts$prose_pending,
               "^Passdata från Apple Health håller fortfarande på att läsas in")
  expect_false(fr$asymmetric)
})

test_that("a poison-message wedge is caught: fresh arrivals, no successful import", {
  # The issue-007 failure mode. A single malformed file fails every
  # import while well-formed pushes keep arriving, so every arrival
  # signal is fresh — the inbox mtime moves on each push, and
  # last_workouts_import bumps on the failed attempts too — while the
  # queue only grows and nothing reaches summaries. Judged on arrival
  # this reads healthy; only the stale SUCCESS timestamp exposes it.
  fr <- assess(
    status_payload = payload(received = 2, attempt = 1, import_ok = 24 * 6,
                              pending_workouts = 40),
    workouts_dir = inbox_at(hours_ago(1)))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$flows$workouts$queue_state, "stuck")
  expect_false(fr$flows$workouts$in_flight)
  expect_match(fr$flows$workouts$prose,
               "kommer in men har inte kunnat läsas in sedan")
  expect_match(fr$flows$workouts$message, "queue stuck")
})

test_that("last_workouts_import (last attempt) is not arrival evidence", {
  # Codex's sharpened root cause: the attempt-bumped field must not keep
  # the flow fresh. A fresh attempt + a stale success + a pending queue,
  # with no inbox and no sessions, must still fail. Against the code
  # that used last_workouts_import as arrival evidence this read ok /
  # in_progress and doctor never fired.
  fr <- assess(status_payload = payload(received = 2, attempt = 0.5,
                                         import_ok = 24 * 6,
                                         pending_workouts = 40))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$flows$workouts$queue_state, "stuck")
  # The verdict rests on the success timestamp, never the attempt.
  expect_equal(fr$flows$workouts$source, "receiver_import_ok")
})

# The next two tests are a matched pair: identical payloads — null
# success stamp, no arrival evidence, a pending queue — differing ONLY
# in uptime. Together they prove that the stuck/in_progress boundary
# turns on `import_stalled` (stale success past the uptime grace), not
# on whether a success stamp exists. If the ok verdict were ever keyed
# on "stamp present", the restart case (null stamp) would fall back to
# fail and one of these would break.

test_that("a queue whose import never succeeded since boot alarms once uptime passes the window", {
  # Null stamp, but uptime is well past the stall window: a healthy
  # backfill would have drained by now, so this is a wedge. Stuck/fail.
  fr <- assess(status_payload = payload(received = 2, import_ok = NULL,
                                         pending_workouts = 40,
                                         uptime_seconds = 24 * 3 * 3600))
  expect_equal(fr$flows$workouts$queue_state, "stuck")
  expect_equal(fr$flows$workouts$status, "fail")
})

test_that("a queue resumed into a just-booted receiver reads ok, not stuck", {
  # Same null stamp, but uptime is inside the grace: the import has
  # simply not run yet. The verdict must follow the queue state — a
  # backfill about to start is a live feed — not the raw arrival
  # evidence, which is unknown here. Fails against code that left
  # in_progress carrying the arrival verdict, and against code that
  # keyed ok on the stamp being present.
  fr <- assess(status_payload = payload(received = 2, import_ok = NULL,
                                         pending_workouts = 40,
                                         uptime_seconds = 300))
  expect_equal(fr$flows$workouts$queue_state, "in_progress")
  expect_equal(fr$flows$workouts$status, "ok")
  expect_true(fr$flows$workouts$ok)
})

test_that("a remote doctor with only /v1/status does not alarm on a working queue", {
  # No inbox, no summaries — only the receiver's status. A queue being
  # imported (fresh success) must read ok even though arrival evidence
  # is otherwise absent.
  fr <- assess(status_payload = payload(received = 2, import_ok = 1,
                                         pending_workouts = 40),
               workouts_dir = tempfile())
  expect_equal(fr$flows$workouts$queue_state, "in_progress")
  expect_equal(fr$flows$workouts$status, "ok")
})

test_that("the import-stall window is a parameter", {
  base <- payload(received = 2, workouts = 2, import_ok = 10,
                  pending_workouts = 40)
  expect_equal(assess(status_payload = base)$flows$workouts$queue_state,
               "in_progress")
  expect_equal(
    assess(status_payload = base,
           workout_import_stale_hours = 6)$flows$workouts$queue_state,
    "stuck")
})

test_that("no queue means clear, and no incompleteness claim to make", {
  fr <- assess(status_payload = payload(received = 2, workouts = 2,
                                         import_ok = 2, pending_workouts = 0))
  expect_equal(fr$flows$workouts$queue_state, "clear")
  expect_false(fr$flows$workouts$in_flight)
  expect_null(fr$flows$workouts$prose_pending)
})

test_that("an empty queue does not vouch for the workout feed", {
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 50,
                                         pending_workouts = 0,
                                         workouts_timer_armed = FALSE))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$flows$workouts$queue_state, "clear")
})

test_that("the asymmetry is not held against a just-restarted receiver", {
  # The 14-minute window where metrics have resumed and workouts have
  # not yet: the flows do not wake in step, and the in-memory counters
  # are meaningless this soon after start.
  fr <- assess(status_payload = payload(received = 0.1, workouts = 60,
                                         uptime_seconds = 300))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_false(fr$flows$workouts$tightened)
  expect_equal(fr$flows$workouts$status, "ok")
})

test_that("the restart grace expires and the asymmetry then bites", {
  fr <- assess(status_payload = payload(received = 2, workouts = 60,
                                         uptime_seconds = 4000))
  expect_true(fr$flows$workouts$tightened)
  expect_equal(fr$flows$workouts$status, "warn")
})

test_that("the restart grace is a parameter", {
  fr <- assess(status_payload = payload(received = 2, workouts = 60,
                                         uptime_seconds = 4000),
               receiver_grace_hours = 2)
  expect_false(fr$flows$workouts$tightened)
})

test_that("a long-running receiver is never in grace", {
  # uptime absent (older receiver build) must not read as "just booted".
  fr <- assess(status_payload = payload(received = 2, workouts = 60))
  expect_true(fr$flows$workouts$tightened)
})

test_that("freshness is measured on arrival, not on what the file contains", {
  # A backfilled June workout delivered a minute ago: content seven
  # weeks old, arrival current. The feed is alive.
  fr <- assess(status_payload = payload(received = 2),
               summaries = sessions_at("2026-06-02 08:00:00"),
               workouts_dir = inbox_at(hours_ago(0.1)))
  expect_equal(fr$flows$workouts$status, "ok")
  expect_equal(fr$flows$workouts$source, "workout_files")
})

# --- Evidence tiering ----------------------------------------------------

test_that("fresh Garmin sessions do not mask a dead HAE workout feed", {
  # summaries also carries the separate Garmin pipeline, so it sits in
  # a weaker tier than the receiver/inbox evidence.
  fr <- assess(status_payload = payload(received = 2, workouts = 24 * 30),
               summaries = sessions_at("2026-07-21 08:00:00"))
  expect_equal(fr$flows$workouts$status, "fail")
  expect_equal(fr$flows$workouts$source, "receiver_import_ok")
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

test_that("the canonical tree is honoured when the cache import is stuck", {
  # save_health_push() writes every non-sleep metric under canonical/,
  # and import_health_export() prefers it; metrics/ now carries only
  # legacy sleep files. A stuck import with live pushes is exactly when
  # this evidence decides, so missing it would alarm falsely.
  fr <- assess(health_daily = health_at("2026-07-01"),
               canonical_dir = canonical_at(hours_ago(2)))
  expect_equal(fr$flows$metrics$status, "ok")
  expect_equal(fr$flows$metrics$source, "canonical_files")
})

test_that("a quiet canonical tree does not vouch for the metric flow", {
  fr <- assess(health_daily = health_at("2026-07-01"),
               canonical_dir = canonical_at(hours_ago(24 * 20)))
  expect_equal(fr$flows$metrics$status, "fail")
})

test_that(".freshness_dir_mtime sees writes in per-metric subdirectories", {
  # The root's own mtime only moves when a brand-new metric appears, so
  # the one-level directory walk is what carries the canonical layout.
  dir <- canonical_at(hours_ago(48))
  sub <- file.path(dir, "hrv")
  fresh <- file.path(sub, "2026-07-22.json")
  writeLines("{}", fresh)
  Sys.setFileTime(fresh, hours_ago(1))
  Sys.setFileTime(sub, hours_ago(1))
  expect_gt(.freshness_dir_mtime(dir), hours_ago(2))
})

test_that(".freshness_dir_mtime skips the file scan on large archives", {
  # Directory mtimes alone must carry a directory too big to walk —
  # the workouts inbox holds ~15 000 files and this runs daily.
  dir <- inbox_at(hours_ago(50))
  Sys.setFileTime(dir, hours_ago(1))
  expect_gt(.freshness_dir_mtime(dir, max_scan = 0L), hours_ago(2))
})

test_that("writing a file moves its directory's mtime", {
  # Characterisation, not behaviour: the whole cheap-mtime design rests
  # on the filesystem doing this. Every other test here sets mtimes with
  # Sys.setFileTime(), so they would all stay green while production
  # read ancient timestamps if the premise ever stopped holding.
  dir <- withr::local_tempdir()
  Sys.setFileTime(dir, as.POSIXct("2020-01-01 00:00:00", tz = ""))
  writeLines("{}", file.path(dir, "arrival.json"))
  expect_gt(file.mtime(dir), as.POSIXct("2021-01-01 00:00:00", tz = ""))
})

test_that(".freshness_dir_mtime returns NA for a missing or empty directory", {
  expect_true(is.na(.freshness_dir_mtime(tempfile())))
  expect_true(is.na(.freshness_dir_mtime(NULL)))
  # An inbox created but never written to must not report its own
  # creation time as an arrival.
  empty <- withr::local_tempdir()
  expect_true(is.na(.freshness_dir_mtime(empty)))
})

test_that("the legacy metrics inbox is honoured when the cache lags behind it", {
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

test_that("a just-after-midnight arrival is dated in local time", {
  # as.Date() on a POSIXct converts via UTC, which would render a 00:30
  # local arrival as the previous day — and disagree with the English
  # message, which is built with format().
  midnight <- as.POSIXct("2026-07-12 00:30:00", tz = "")
  fr <- assess(now = as.POSIXct("2026-07-21 21:30:00", tz = ""),
               status_payload = list(
                 last_received = format(midnight, "%Y-%m-%dT%H:%M:%S")))
  expect_match(fr$flows$metrics$prose, "sedan 12 juli")
  expect_match(fr$flows$metrics$message, "2026-07-12 00:30")
})

test_that("a just-before-midnight arrival is dated in local time", {
  # The mirror case: UTC+2 in summer means 23:30 local is already the
  # next day in UTC.
  late <- as.POSIXct("2026-07-11 23:30:00", tz = "")
  fr <- assess(now = as.POSIXct("2026-07-21 21:30:00", tz = ""),
               status_payload = list(
                 last_received = format(late, "%Y-%m-%dT%H:%M:%S")))
  expect_match(fr$flows$metrics$prose, "sedan 11 juli")
  expect_match(fr$flows$metrics$message, "2026-07-11 23:30")
})

test_that("the year boundary is judged in local time too", {
  # 00:30 on 1 January locally is still 31 December in UTC, so the
  # year suffix would appear on a same-year date.
  ny <- as.POSIXct("2026-01-01 00:30:00", tz = "")
  expect_equal(.freshness_date_sv(ny, reference = ny), "1 januari")
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
