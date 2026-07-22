# R/freshness.R
#
# How recently did each inbound data flow actually deliver?
#
# Motivation: on 2026-07-21 the evening summary said "Vilodag. Dagsform
# 🔴 Röd 21 …" on a day with a six-hour paddling session. Nothing in
# the stack looked at data age, so silence rendered as rest.
#
# The outage was asymmetric: /v1/workouts went quiet on 2026-06-02
# while /v1/health kept flowing for another five weeks until
# 2026-07-11. The receiver answered GET /health with 200 throughout and
# doctor reported green through both. A watchdog that only asks "has
# the receiver heard anything" would have seen the metric pushes and
# said ok for seven weeks — so each flow is assessed on its own
# evidence, and the worst one decides.
#
# One source of truth for the thresholds *and* the Swedish wording:
# check_data_freshness() (R/doctor.R) and day_summary_prose()
# (R/day_summary.R) both go through data_freshness().

# --- Receiver probe ----------------------------------------------------------

# Base URL of the FastAPI receiver. The receiver binds
# TRANING_RECEIVER_HOST:PORT (a Tailscale IP on kailash), so probing
# localhost would yield a false "unreachable"; a wildcard bind is
# reachable via loopback. Sys.getenv's default only applies when the
# var is unset, so present-but-empty values are normalised too.
.receiver_base_url <- function() {
  host <- Sys.getenv("TRANING_RECEIVER_HOST", "127.0.0.1")
  port <- Sys.getenv("TRANING_RECEIVER_PORT", "8421")
  if (host %in% c("", "0.0.0.0")) host <- "127.0.0.1"
  if (!nzchar(port)) port <- "8421"
  sprintf("http://%s:%s", host, port)
}

.receiver_status_url <- function() {
  paste0(.receiver_base_url(), "/v1/status")
}

# Fetch GET /v1/status and return the parsed payload, or NULL when the
# receiver is unreachable, unauthenticated or answering non-JSON.
# Never signals — every caller treats NULL as "fall back to disk".
.receiver_status <- function(url = .receiver_status_url(),
                              timeout = 5L,
                              api_key = Sys.getenv("TRANING_API_KEY")) {
  api_key <- trimws(api_key)
  if (!nzchar(api_key)) return(NULL)
  # A key containing a quote or newline would break out of the curl
  # config syntax below and inject options. Keys are hex, so refusing
  # is safe.
  if (grepl("[\"\r\n]", api_key)) return(NULL)

  # Feed the key through curl's stdin config rather than argv: command
  # lines are world-readable via /proc on the receiver host.
  cfg <- c(
    sprintf('url = "%s"', url),
    sprintf('header = "X-API-Key: %s"', api_key),
    sprintf("max-time = %s", as.character(timeout)),
    "silent",
    "fail"
  )
  out <- suppressWarnings(system2("curl", c("--config", "-"),
                                   input = cfg,
                                   stdout = TRUE, stderr = FALSE))
  status <- attr(out, "status")
  if (!is.null(status) && !identical(as.integer(status), 0L)) return(NULL)
  if (length(out) == 0) return(NULL)
  payload <- tryCatch(
    jsonlite::fromJSON(paste(out, collapse = "\n"), simplifyVector = TRUE),
    error = function(e) NULL)
  if (!is.list(payload)) return(NULL)
  payload
}

# --- Evidence extraction -----------------------------------------------------

.na_time <- function() as.POSIXct(NA_character_)

# Parse the receiver's ISO strings. FastAPI emits naive local time
# (datetime.now().isoformat()), but tolerate a trailing Z / date-only
# values so a future serialisation change degrades to "older reading"
# rather than "no reading".
.parse_iso_time <- function(x) {
  if (is.null(x) || length(x) == 0) return(.na_time())
  x <- as.character(x)[1]
  if (is.na(x) || !nzchar(x)) return(.na_time())
  tz <- ""
  if (grepl("Z$", x)) {
    x <- sub("Z$", "", x)
    tz <- "UTC"
  }
  fmts <- c("%Y-%m-%dT%H:%M:%OS", "%Y-%m-%d %H:%M:%OS",
            "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d")
  for (f in fmts) {
    ts <- suppressWarnings(as.POSIXct(x, format = f, tz = tz))
    if (!is.na(ts)) return(ts)
  }
  .na_time()
}

# Latest health-metric day, expressed as the end of that day: the date
# bucket covers the whole day, so a cache whose newest date is
# "yesterday" is at most ~24 h behind, not ~48 h.
.freshness_health_ts <- function(health_daily) {
  if (is.null(health_daily) || !inherits(health_daily, "data.frame") ||
      nrow(health_daily) == 0 || !"date" %in% names(health_daily)) {
    return(.na_time())
  }
  d <- suppressWarnings(as.Date(health_daily$date))
  d <- d[!is.na(d)]
  if (length(d) == 0) return(.na_time())
  as.POSIXct(paste(max(d), "23:59:59"), tz = "")
}

.freshness_session_ts <- function(summaries) {
  if (is.null(summaries) || !inherits(summaries, "data.frame") ||
      nrow(summaries) == 0 || !"sessionStart" %in% names(summaries)) {
    return(.na_time())
  }
  ts <- suppressWarnings(as.POSIXct(summaries$sessionStart))
  ts <- ts[!is.na(ts)]
  if (length(ts) == 0) return(.na_time())
  max(ts)
}

# Newest write into an inbox directory — an *arrival* time, which is
# the thing freshness is about. It matters that this is not a content
# date: after an outage the phone backfills chronologically, so a file
# delivered a minute ago can carry a workout from seven weeks back.
# Judged on content it looks ancient; judged on arrival it correctly
# reads as a live feed.
#
# It is also the durable half of the receiver's evidence: /v1/status's
# counters live in process memory and reset on every restart, so
# without this a restart would read as "workouts never arrived".
# Caveat: a fresh git clone rewrites mtimes to checkout time, which
# reads as artificially fresh.
#
# Cost matters here — the workouts inbox holds ~15 000 files and the
# canonical metric tree ~62 000 across 78 per-metric subdirectories, and
# this runs on every doctor pass and every evening notification. So the
# primary signal is the mtime of the directories themselves, which the
# kernel bumps whenever an entry is created: one stat per directory
# instead of one per file. Creating a file is what an arriving push
# does, so this sees arrivals without walking the archive.
#
# A rewrite of an existing filename leaves the directory mtime alone
# (canonical dedups per metric per day, so the day's later pushes
# overwrite). That costs at most a day of resolution — the first push
# of each day still creates files — which sits well inside the 36 h
# threshold. Small directories are scanned file-by-file anyway, so the
# gap only applies to archives too large to walk cheaply.
.freshness_dir_mtime <- function(dir, max_scan = 5000L) {
  if (is.null(dir) || !nzchar(dir) || !dir.exists(dir)) return(.na_time())

  # The directory itself plus one level of subdirectories: canonical
  # writes land in canonical/<metric>/, so the root's own mtime would
  # only move when a brand-new metric appears.
  subdirs <- list.dirs(dir, recursive = FALSE, full.names = TRUE)
  files <- list.files(dir, recursive = FALSE, full.names = TRUE, no.. = TRUE)
  # An inbox that was created but never written to would otherwise
  # report its own creation time as an arrival.
  if (length(subdirs) == 0 && length(files) == 0) return(.na_time())

  candidates <- suppressWarnings(file.mtime(c(dir, subdirs)))
  if (length(files) > 0 && length(files) <= max_scan) {
    candidates <- c(candidates, suppressWarnings(file.mtime(files)))
  }

  candidates <- candidates[!is.na(candidates)]
  if (length(candidates) == 0) return(.na_time())
  max(candidates)
}

# Pick the newest timestamp from the first tier that has any evidence
# at all, keeping the label of the one that won. Tiers, not a flat
# max: a later tier is a weaker proxy for the flow, so letting it
# compete on recency is exactly how a live neighbouring flow masks a
# dead one. `tiers` is a list of named lists of POSIXct scalars.
.freshness_newest <- function(tiers) {
  for (tier in tiers) {
    keep <- !vapply(tier, is.na, logical(1))
    if (!any(keep)) next
    tier <- tier[keep]
    ts <- do.call(c, lapply(tier, as.POSIXct))
    i <- which.max(ts)
    return(list(ts = ts[[i]], source = names(tier)[i]))
  }
  list(ts = .na_time(), source = NA_character_)
}

# Is the receiver holding workouts it has received but not yet
# imported? After the phone app is reopened it backfills the whole
# gap in chronological chunks — 216 files were queued at once on
# 2026-07-21 — and during that catch-up the last *import* timestamp
# still points at the old data. Deliveries in flight are the opposite
# of a dead feed, so this counts as arrival evidence.
.freshness_backfill_in_flight <- function(status_payload) {
  pending <- suppressWarnings(
    as.numeric(status_payload[["pending_workouts"]] %||% NA_real_))
  armed <- isTRUE(status_payload[["workouts_timer_armed"]])
  armed || (!is.na(pending) && pending > 0)
}

# Seconds since the receiver process started, NA when unknown.
.freshness_uptime <- function(status_payload) {
  suppressWarnings(
    as.numeric(status_payload[["uptime_seconds"]] %||% NA_real_))
}

# --- Swedish wording ---------------------------------------------------------

.FRESHNESS_FLOW_SV <- c(
  metrics  = "Hälsodata från Apple Health",
  workouts = "Passdata från Apple Health"
)

# "11 juli" — locale-independent (systemd-launched R runs in C locale,
# where format(..., "%B") is English). Year is appended only when the
# timestamp falls outside the reference year.
.freshness_date_sv <- function(ts, reference = Sys.time()) {
  if (is.na(ts)) return(NA_character_)
  # Read the calendar fields off the timestamp directly. as.Date() on a
  # POSIXct converts via UTC, so an arrival at 00:30 local time would
  # render as the previous day here while the English message — built
  # with format() — named the right one. A function whose whole purpose
  # is to say *when* something last arrived cannot afford that.
  base <- sprintf("%d %s", as.integer(format(ts, "%d")),
                  .swedish_months[as.integer(format(ts, "%m"))])
  if (format(ts, "%Y") != format(reference, "%Y")) {
    base <- paste(base, format(ts, "%Y"))
  }
  base
}

# --- Per-flow assessment -----------------------------------------------------

# Rank for picking the flow that decides the overall verdict.
# "unknown" outranks "ok" (we could not measure at all) but not "warn".
.FRESHNESS_RANK <- c(ok = 0L, unknown = 1L, warn = 2L, fail = 3L)

.freshness_assess_flow <- function(flow, tiers, now,
                                    warn_hours, fail_hours,
                                    tightened = FALSE) {
  label <- .FRESHNESS_FLOW_SV[[flow]]
  newest <- .freshness_newest(tiers)

  if (is.na(newest$ts)) {
    return(list(
      flow = flow, status = "unknown", ok = FALSE,
      last_data = .na_time(), age_hours = NA_real_,
      source = NA_character_,
      warn_hours = warn_hours, fail_hours = fail_hours,
      tightened = tightened,
      message = sprintf(
        "%s: no signal — receiver silent and nothing on disk.", flow),
      prose = sprintf(
        "%s går inte att verifiera, så underlaget kan vara ofullständigt.",
        label)
    ))
  }

  age <- as.numeric(difftime(now, newest$ts, units = "hours"))
  status <- if (age > fail_hours) "fail"
            else if (age > warn_hours) "warn"
            else "ok"
  when <- format(newest$ts, "%Y-%m-%d %H:%M")

  message <- if (status == "ok") {
    sprintf("%s: %.1f h old (%s, %s).", flow, max(age, 0), newest$source, when)
  } else {
    sprintf("%s: silent for %.1f h (%s above %g h%s) — newest %s from %s.",
            flow, age, status,
            if (status == "fail") fail_hours else warn_hours,
            if (tightened) ", tightened: metrics still arriving" else "",
            when, newest$source)
  }

  date_sv <- .freshness_date_sv(newest$ts, reference = now)
  prose <- if (status == "ok") {
    sprintf("%s kom in senast %s.", label, date_sv)
  } else if (tightened) {
    # The actionable half of the message: a live metric feed proves the
    # phone is pushing, so a silent workout feed is a broken automation
    # rather than a quiet training week.
    sprintf(paste("%s har inte kommit in sedan %s, medan hälsodata",
                  "fortsätter komma in — troligen en trasig automation."),
            label, date_sv)
  } else {
    sprintf(
      "%s har inte kommit in sedan %s, så underlaget är ofullständigt.",
      label, date_sv)
  }

  list(
    flow = flow, status = status, ok = status == "ok",
    last_data = newest$ts, age_hours = age, source = newest$source,
    warn_hours = warn_hours, fail_hours = fail_hours,
    tightened = tightened,
    message = message, prose = prose
  )
}

# --- Public entry point ------------------------------------------------------

#' Assess how recently each inbound data flow delivered
#'
#' Answers "is the data source alive?" per flow, so that consumers do
#' not read silence as rest. Two flows are tracked:
#'
#' \describe{
#'   \item{\code{metrics}}{Apple Health metric pushes. Evidence: the
#'     newest day in \code{health_daily} or the newest write into the
#'     canonical / legacy metric inboxes; failing those, the receiver's
#'     \code{last_received}. That field is bumped by \emph{any} inbound
#'     push, workouts included, so it cannot prove this flow
#'     specifically and only serves a host with no data root.}
#'   \item{\code{workouts}}{Apple Health workout pushes. Evidence: a
#'     backfill in flight (\code{pending_workouts}), the receiver's
#'     \code{last_workouts_import}, or the newest file in the workouts
#'     inbox; failing all three, the newest \code{sessionStart} (which
#'     also covers the separate Garmin pipeline, so it cannot prove
#'     this flow either).}
#' }
#'
#' Evidence is tiered rather than pooled: a weaker proxy never competes
#' on recency with a flow-specific one, which is what would let a live
#' neighbouring flow mask a dead one.
#'
#' Freshness is measured on \emph{arrival}, never on the content date
#' of what arrived. After an outage the phone backfills chronologically,
#' so a file delivered a minute ago may carry a seven-week-old workout;
#' judged on content that live feed would read as dead.
#'
#' Thresholds and Swedish wording live here so the doctor check
#' (\code{check_data_freshness()}) and the day-summary prose agree.
#'
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}.
#' @param summaries Optional summaries data frame.
#' @param now Reference instant (default \code{Sys.time()}).
#' @param metrics_warn_hours,metrics_fail_hours Metric-flow thresholds
#'   (default 36 h / 72 h). Metrics arrive several times a day, so a day
#'   and a half of silence is already anomalous. Boundaries are
#'   exclusive: exactly 36 h is still \code{"ok"}.
#' @param workout_warn_hours,workout_fail_hours Workout-flow thresholds
#'   (default 96 h / 14 d). Workouts only arrive when a session was
#'   recorded, and a few training-free days are legitimate.
#' @param workout_asym_warn_hours,workout_asym_fail_hours Workout-flow
#'   thresholds used when the metric flow is fresh (default 48 h / 7 d).
#'   Absolute time is the weaker signal; the asymmetry — metrics
#'   arriving while workouts are silent — is the fingerprint of a single
#'   dead automation and is worth reacting to sooner. 48 h sits just
#'   above the observed noise floor: across 850 workout days since
#'   2024-01-01 there were seven two-day gaps and only three gaps of
#'   three days or more (the longest eight days, Oct--Nov 2024), so this
#'   threshold would have fired about once a year, each time on a
#'   genuine anomaly.
#' @param receiver_grace_hours Suppress the asymmetry tightening for
#'   this long after a receiver restart (default 1 h), while the
#'   in-memory counters and the import queue settle and the two flows
#'   resume out of step.
#' @param data_dir Data root, default \code{TRANING_DATA}.
#' @param metrics_dir,canonical_dir,workouts_dir Inbox directories,
#'   derived from \code{data_dir} by default. \code{canonical_dir} is
#'   the per-metric-per-day surface that receives every non-sleep
#'   metric; \code{metrics_dir} now holds only legacy sleep files.
#' @param status_payload Pre-fetched \code{/v1/status} payload (a list).
#'   Supply this in tests to avoid network access.
#' @param status_fetch Function returning the payload, or \code{NULL} to
#'   skip the receiver entirely. Only called when \code{status_payload}
#'   is \code{NULL}.
#' @return A list with the overall \code{status} ("ok", "warn", "fail"
#'   or "unknown"), \code{ok}, \code{worst_flow} and that flow's
#'   \code{last_data}, \code{age_hours} and \code{source}, a
#'   \code{flows} list with one entry per flow, \code{asymmetric}, an
#'   English \code{message} for ops output and Swedish \code{prose} for
#'   notifications.
#' @export
data_freshness <- function(health_daily = NULL,
                            summaries = NULL,
                            now = Sys.time(),
                            metrics_warn_hours = 36,
                            metrics_fail_hours = 72,
                            workout_warn_hours = 96,
                            workout_fail_hours = 24 * 14,
                            workout_asym_warn_hours = 48,
                            workout_asym_fail_hours = 24 * 7,
                            receiver_grace_hours = 1,
                            data_dir = Sys.getenv("TRANING_DATA"),
                            metrics_dir = NULL,
                            canonical_dir = NULL,
                            workouts_dir = NULL,
                            status_payload = NULL,
                            status_fetch = .receiver_status) {
  if (is.null(status_payload) && is.function(status_fetch)) {
    status_payload <- tryCatch(status_fetch(), error = function(e) NULL)
  }
  now <- as.POSIXct(now)

  if (is.null(metrics_dir) && nzchar(data_dir)) {
    metrics_dir <- file.path(data_dir, "kristian", "health_export", "metrics")
  }
  if (is.null(canonical_dir) && nzchar(data_dir)) {
    canonical_dir <- file.path(data_dir, "kristian", "health_export",
                                "canonical")
  }
  if (is.null(workouts_dir) && nzchar(data_dir)) {
    workouts_dir <- file.path(data_dir, "kristian", "health_export", "workouts")
  }

  metrics_flow <- .freshness_assess_flow(
    "metrics",
    list(
      # canonical/ is where save_health_push() writes every non-sleep
      # metric and what import_health_export() prefers; metrics/ now
      # carries only legacy sleep files. Without canonical the check
      # would miss live arrivals whenever the cache import is the thing
      # that is stuck — which is precisely when this evidence matters.
      list(health_cache = .freshness_health_ts(health_daily),
           canonical_files = .freshness_dir_mtime(canonical_dir),
           metric_files = .freshness_dir_mtime(metrics_dir)),
      # Weaker tier: /v1/status's last_received is bumped by any inbound
      # push, workouts included, so it would mask a metric outage. Used
      # only on a host with neither cache nor inbox.
      list(receiver_push = .parse_iso_time(status_payload[["last_received"]]))
    ),
    now = now,
    warn_hours = metrics_warn_hours, fail_hours = metrics_fail_hours)

  # Tighten the workout thresholds when metrics are demonstrably
  # arriving — see workout_asym_* in the docs above. Suppressed for the
  # first hour after a receiver restart: the in-memory counters and the
  # import queue have not settled, and the two flows do not resume in
  # step. On 2026-07-21 the first metric push landed at 19:01 and the
  # first workout push at 19:15, so a tightened verdict in between
  # would have alarmed on a feed that was in the middle of waking up.
  uptime <- .freshness_uptime(status_payload)
  settled <- is.na(uptime) || uptime >= receiver_grace_hours * 3600
  tightened <- identical(metrics_flow$status, "ok") && settled
  workouts_flow <- .freshness_assess_flow(
    "workouts",
    list(
      # Strongest evidence, all arrival-based: a queued import proves
      # deliveries are happening right now, last_workouts_import is
      # in-memory and resets on every receiver restart, and the inbox
      # mtime is the durable half of the same evidence.
      list(pending_import = if (.freshness_backfill_in_flight(status_payload))
                              now else .na_time(),
           receiver_import = .parse_iso_time(
             status_payload[["last_workouts_import"]]),
           workout_files = .freshness_dir_mtime(workouts_dir)),
      # Weaker tier, and a content date rather than an arrival time:
      # summaries also carries the separate Garmin pipeline, and during
      # a backfill its newest sessionStart lags weeks behind delivery.
      list(sessions = .freshness_session_ts(summaries))
    ),
    now = now,
    warn_hours = if (tightened) workout_asym_warn_hours
                 else workout_warn_hours,
    fail_hours = if (tightened) workout_asym_fail_hours
                 else workout_fail_hours,
    tightened = tightened)

  flows <- list(metrics = metrics_flow, workouts = workouts_flow)
  ranks <- vapply(flows, function(f) .FRESHNESS_RANK[[f$status]], integer(1))
  ages <- vapply(flows, function(f) f$age_hours, numeric(1))
  # Severity first, then longest silence — when both flows have failed,
  # the one that died first is the one worth naming.
  ranked <- order(ranks, ifelse(is.na(ages), -Inf, ages), decreasing = TRUE)
  worst <- flows[[ranked[1]]]

  bad <- flows[ranked]
  bad <- bad[!vapply(bad, `[[`, logical(1), "ok")]

  list(
    status = worst$status,
    ok = worst$ok,
    worst_flow = worst$flow,
    last_data = worst$last_data,
    age_hours = worst$age_hours,
    source = worst$source,
    flows = flows,
    asymmetric = tightened && !workouts_flow$ok,
    details = list(
      receiver_reachable = !is.null(status_payload),
      receiver_uptime_seconds =
        as.numeric(status_payload[["uptime_seconds"]] %||% NA_real_),
      pending_workouts =
        as.numeric(status_payload[["pending_workouts"]] %||% NA_real_)
    ),
    message = paste(vapply(flows, `[[`, character(1), "message"),
                    collapse = " "),
    prose = if (length(bad) == 0) {
      paste(vapply(flows, `[[`, character(1), "prose"), collapse = " ")
    } else {
      paste(vapply(bad, `[[`, character(1), "prose"), collapse = " ")
    }
  )
}
