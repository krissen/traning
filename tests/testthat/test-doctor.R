# Tests for R/doctor.R — health checks for the traning deployment.

# --- Helpers -------------------------------------------------------------

make_pkg_matrix <- function(rows) {
  # rows: list(list(Package=, LibPath=, Built=))
  mat <- do.call(rbind, lapply(rows, function(r) {
    c(Package = r$Package, LibPath = r$LibPath, Built = r$Built)
  }))
  if (is.null(mat)) {
    mat <- matrix(character(0), nrow = 0, ncol = 3,
                   dimnames = list(NULL, c("Package", "LibPath", "Built")))
  }
  mat
}

# --- check_stale_builds --------------------------------------------------

test_that("check_stale_builds is OK when all packages match current R", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "foo", LibPath = "/usr/lib/R/library",
         Built = "R 4.6.0; x86_64-pc-linux-gnu; 2026-04-01 12:00:00 UTC; unix"),
    list(Package = "bar", LibPath = "/home/user/R/library",
         Built = "R 4.6.0; x86_64-pc-linux-gnu; 2026-04-01 12:00:00 UTC; unix")
  ))
  res <- check_stale_builds(installed_pkgs = pkgs, r_version = "4.6",
                              marker_file = tempfile())
  expect_equal(res$status, "ok")
  expect_match(res$message, "All 2 package")
})

test_that("check_stale_builds fails when a package was built against older R", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "foo", LibPath = "/usr/lib/R/library",
         Built = "R 4.6.0; x86_64-pc-linux-gnu; 2026-04-01 12:00:00 UTC; unix"),
    list(Package = "rlang", LibPath = "/home/user/R/library",
         Built = "R 4.5.3; x86_64-pc-linux-gnu; 2025-12-01 12:00:00 UTC; unix")
  ))
  res <- check_stale_builds(installed_pkgs = pkgs, r_version = "4.6",
                              marker_file = tempfile())
  expect_equal(res$status, "fail")
  expect_match(res$message, "1 package")
  stale_names <- vapply(res$details$stale, `[[`, character(1), "package")
  expect_equal(stale_names, "rlang")
})

test_that("check_stale_builds is OK when nothing is installed", {
  pkgs <- make_pkg_matrix(list())
  res <- check_stale_builds(installed_pkgs = pkgs, r_version = "4.6",
                              marker_file = tempfile())
  expect_equal(res$status, "ok")
})

test_that("check_stale_builds warns on unparseable Built tag", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "weird", LibPath = "/usr/lib/R/library",
         Built = "")
  ))
  res <- check_stale_builds(installed_pkgs = pkgs, r_version = "4.6",
                              marker_file = tempfile())
  expect_equal(res$status, "warn")
  expect_match(res$message, "unparseable")
})

test_that("check_stale_builds mentions marker file when it exists", {
  marker <- withr::local_tempfile()
  file.create(marker)
  pkgs <- make_pkg_matrix(list(
    list(Package = "rlang", LibPath = "/home/user/R/library",
         Built = "R 4.5.3; x86_64-pc-linux-gnu; 2025-12-01 12:00:00 UTC; unix")
  ))
  res <- check_stale_builds(installed_pkgs = pkgs, r_version = "4.6",
                              marker_file = marker)
  expect_equal(res$status, "fail")
  expect_match(res$message, "rebuild-stale")
})

# --- check_services ------------------------------------------------------

test_that("check_services is OK when all services active and HTTP probes respond", {
  res <- check_services(
    services = c("svc-a", "svc-b"),
    shiny_url = "http://shiny",
    receiver_url = "http://receiver/health",
    systemctl_check = function(unit) TRUE,
    http_check = function(url) TRUE
  )
  expect_equal(res$status, "ok")
  expect_true(res$details$receiver_ok)
})

test_that("check_services fails when a service is down", {
  res <- check_services(
    services = c("svc-a", "svc-b"),
    shiny_url = "http://shiny",
    receiver_url = "http://receiver/health",
    systemctl_check = function(unit) unit != "svc-b",
    http_check = function(url) TRUE
  )
  expect_equal(res$status, "fail")
  expect_match(res$message, "svc-b")
})

test_that("check_services fails when Shiny does not respond", {
  # Discriminate by URL so only the Shiny probe fails.
  res <- check_services(
    services = "svc-a",
    shiny_url = "http://shiny:8423/",
    receiver_url = "http://receiver:8421/health",
    systemctl_check = function(unit) TRUE,
    http_check = function(url) grepl("receiver", url)
  )
  expect_equal(res$status, "fail")
  expect_match(res$message, "Shiny")
  expect_no_match(res$message, "receiver did not respond")
})

test_that("check_services fails when receiver is active but not serving", {
  # systemctl reports the unit up, but the /health probe does not
  # answer — the active-but-wedged failure mode.
  res <- check_services(
    services = "traning-receiver",
    shiny_url = "http://shiny",
    receiver_url = "http://receiver:8421/health",
    systemctl_check = function(unit) TRUE,
    http_check = function(url) !grepl("receiver", url)
  )
  expect_equal(res$status, "fail")
  expect_match(res$message, "receiver did not respond")
  expect_false(res$details$receiver_ok)
})

test_that(".receiver_health_url honours env and normalises wildcard bind", {
  withr::with_envvar(
    c(TRANING_RECEIVER_HOST = "100.93.126.68", TRANING_RECEIVER_PORT = "8421"),
    expect_equal(.receiver_health_url(),
                 "http://100.93.126.68:8421/health")
  )
  withr::with_envvar(
    c(TRANING_RECEIVER_HOST = "0.0.0.0", TRANING_RECEIVER_PORT = "8421"),
    expect_equal(.receiver_health_url(),
                 "http://127.0.0.1:8421/health")
  )
  # Present-but-empty port must fall back to the default, not yield
  # an invalid "http://host:/health".
  withr::with_envvar(
    c(TRANING_RECEIVER_HOST = "100.93.126.68", TRANING_RECEIVER_PORT = ""),
    expect_equal(.receiver_health_url(),
                 "http://100.93.126.68:8421/health")
  )
})

# --- check_configs -------------------------------------------------------

test_that("check_configs is OK when files match pinned digests", {
  tmp <- withr::local_tempfile()
  writeLines("hello world", tmp)
  sha <- unname(digest::digest(file = tmp, algo = "sha256"))
  res <- check_configs(setNames(list(sha), tmp))
  expect_equal(res$status, "ok")
})

test_that("check_configs warns on digest mismatch", {
  tmp <- withr::local_tempfile()
  writeLines("hello world", tmp)
  res <- check_configs(setNames(list("0000000000000000"), tmp))
  expect_equal(res$status, "warn")
  expect_match(res$message, "mismatch")
})

test_that("check_configs fails when a file is missing", {
  res <- check_configs(list("/nonexistent/path/xyz" = "abc"))
  expect_equal(res$status, "fail")
  expect_match(res$message, "missing")
})

test_that("check_configs warns when present but digest unpinned (NA)", {
  tmp <- withr::local_tempfile()
  writeLines("hello world", tmp)
  res <- check_configs(setNames(list(NA_character_), tmp))
  expect_equal(res$status, "warn")
  expect_match(res$message, "no digest pinned")
})

# --- check_data_freshness ------------------------------------------------

freshness_now <- as.POSIXct("2026-07-21 21:30:00", tz = "")

# `workouts` is the last successful workout import (the arrival signal);
# `import_ok` defaults to it and is overridden only for a wedge.
freshness_payload <- function(received = NULL, workouts = NULL,
                               now = freshness_now, pending_workouts = 0,
                               import_ok = workouts) {
  iso <- function(h) format(now - as.difftime(h, units = "hours"),
                             "%Y-%m-%dT%H:%M:%S")
  list(last_received = if (is.null(received)) NULL else iso(received),
       last_workouts_import = if (is.null(workouts)) NULL else iso(workouts),
       last_workouts_import_ok = if (is.null(import_ok)) NULL else iso(import_ok),
       pending_workouts = pending_workouts)
}

# Pin the inbox directories away from the real data root so the check
# is hermetic on a dev box that has one.
check_freshness <- function(...) {
  args <- list(...)
  if (is.null(args$receiver_configured)) args$receiver_configured <- TRUE
  do.call(check_data_freshness,
          c(list(now = freshness_now, data_dir = "",
                 metrics_dir = tempfile(), canonical_dir = tempfile(),
                 workouts_dir = tempfile()),
            args))
}

test_that("check_data_freshness is ok on two live flows", {
  res <- check_freshness(status_payload = freshness_payload(2, 3),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble())
  expect_equal(res$status, "ok")
  expect_equal(res$details$flows$metrics$status, "ok")
  expect_equal(res$details$flows$workouts$status, "ok")
})

test_that("check_data_freshness fails on the workouts-only outage", {
  # Services, packages and configs would all be green here.
  res <- check_freshness(status_payload = freshness_payload(2, 24 * 30),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble())
  expect_equal(res$status, "fail")
  expect_equal(res$details$worst_flow, "workouts")
  expect_true(res$details$asymmetric)
  expect_equal(res$details$flows$metrics$status, "ok")
  expect_match(res$message, "workouts: silent for")
})

test_that("check_data_freshness fails on a stuck workout import", {
  # A non-empty queue that is not moving must alarm, not read as fresh —
  # the P1 the queue-as-evidence model reintroduced.
  res <- check_freshness(
    status_payload = freshness_payload(2, 24 * 30, pending_workouts = 12),
    health_daily = tibble::tibble(),
    summaries = tibble::tibble())
  expect_equal(res$status, "fail")
  expect_equal(res$details$flows$workouts$queue_state, "stuck")
  expect_match(res$message, "queue stuck")
})

test_that("check_data_freshness fails on a poison-message wedge", {
  # Fresh arrivals, a growing queue, but no successful import: the feed
  # looks alive by arrival alone. Doctor must still alarm.
  res <- check_freshness(
    status_payload = freshness_payload(2, 2, import_ok = 24 * 6,
                                        pending_workouts = 40),
    health_daily = tibble::tibble(),
    summaries = tibble::tibble())
  expect_equal(res$status, "fail")
  expect_equal(res$details$flows$workouts$queue_state, "stuck")
  expect_equal(res$details$flows$workouts$source, "receiver_import_ok")
})

test_that("check_data_freshness stays ok while a backfill drains", {
  res <- check_freshness(
    status_payload = freshness_payload(2, 2, import_ok = 1,
                                        pending_workouts = 216),
    health_daily = tibble::tibble(),
    summaries = tibble::tibble())
  expect_equal(res$status, "ok")
  expect_equal(res$details$flows$workouts$queue_state, "in_progress")
})

test_that("check_data_freshness does not alarm on a queue resumed after restart", {
  # The mirror of the wedge: a receiver just restarted with a persisted
  # queue and no successful import yet, and (as on a remote host) no
  # inbox to read. The arrival verdict is null, but a queue being worked
  # is a live feed — doctor must stay green. This fails against code
  # that left in_progress carrying the raw arrival verdict.
  res <- check_freshness(
    status_payload = list(last_received = format(
                            freshness_now - as.difftime(2, units = "hours"),
                            "%Y-%m-%dT%H:%M:%S"),
                          last_workouts_import_ok = NULL,
                          pending_workouts = 40,
                          uptime_seconds = 300),
    health_daily = tibble::tibble(),
    summaries = tibble::tibble())
  expect_equal(res$details$flows$workouts$queue_state, "in_progress")
  expect_equal(res$details$flows$workouts$status, "ok")
})

test_that("check_data_freshness warns past the metric threshold", {
  res <- check_freshness(status_payload = freshness_payload(48, 3),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble())
  expect_equal(res$status, "warn")
  expect_equal(res$details$worst_flow, "metrics")
})

test_that("check_data_freshness reports unmeasurable freshness as warn", {
  # Receiver unreachable, caches empty, inboxes absent: we cannot prove
  # the feed is alive, so the check must not pass green.
  res <- check_freshness(health_daily = tibble::tibble(),
                          summaries = tibble::tibble(),
                          status_fetch = function() NULL)
  expect_equal(res$status, "warn")
  expect_equal(res$details$freshness_status, "unknown")
})

test_that("check_data_freshness falls back to caches when receiver is down", {
  health <- tibble::tibble(
    date = as.Date("2026-07-11"), metric = "restingHeartRate",
    value = 48, source = "hae")
  res <- check_freshness(health_daily = health,
                          summaries = tibble::tibble(),
                          status_fetch = function() NULL)
  expect_equal(res$status, "fail")
  expect_equal(res$details$flows$metrics$source, "health_cache")
  expect_false(res$details$receiver_reachable)
})

test_that("an unconfigured receiver downgrades fail to a clear warn", {
  # On a dev box the local copy is as old as the last `git pull`, so
  # judging it by file age alone would report a red pipeline on a
  # healthy one.
  health <- tibble::tibble(
    date = as.Date("2026-05-18"), metric = "restingHeartRate",
    value = 48, source = "hae")
  res <- check_freshness(health_daily = health,
                          summaries = tibble::tibble(),
                          status_fetch = function() NULL,
                          receiver_configured = FALSE)
  expect_equal(res$status, "warn")
  expect_match(res$message, "TRANING_API_KEY not set")
  expect_false(res$details$receiver_configured)
  # The underlying verdict is still reported honestly.
  expect_equal(res$details$freshness_status, "fail")
})

test_that("a configured receiver that is down still fails", {
  # The downgrade must not soften the real alarm on kailash, where the
  # key is present and an unreachable receiver is a genuine problem.
  health <- tibble::tibble(
    date = as.Date("2026-05-18"), metric = "restingHeartRate",
    value = 48, source = "hae")
  res <- check_freshness(health_daily = health,
                          summaries = tibble::tibble(),
                          status_fetch = function() NULL,
                          receiver_configured = TRUE)
  expect_equal(res$status, "fail")
})

test_that("an answering receiver is never downgraded", {
  res <- check_freshness(status_payload = freshness_payload(240, 240),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble(),
                          receiver_configured = FALSE)
  expect_equal(res$status, "fail")
})

test_that("check_data_freshness thresholds are overridable", {
  res <- check_freshness(status_payload = freshness_payload(2, 60),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble(),
                          workout_asym_warn_hours = 100,
                          workout_asym_fail_hours = 200)
  expect_equal(res$status, "ok")
})

test_that("check_data_freshness details survive JSON serialisation", {
  # traning-doctor.service writes the JSON form to the journal —
  # POSIXct fields must already be strings or toJSON drops the class.
  res <- check_freshness(status_payload = freshness_payload(2, 3),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble())
  json <- jsonlite::toJSON(res, auto_unbox = TRUE, null = "null",
                            na = "string")
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_equal(parsed$details$flows$workouts$last_data,
               "2026-07-21 18:30:00")
})

# --- doctor_run ----------------------------------------------------------

test_that("doctor_run reports ok=FALSE when any check fails", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "rlang", LibPath = "/home/user/R/library",
         Built = "R 4.5.3; x86_64-pc-linux-gnu; 2025-12-01 12:00:00 UTC; unix")
  ))
  # Inject all external probes so the test is hermetic — no real
  # systemctl/curl/installed.packages reads.
  res <- doctor_run(
    checks = c("packages", "services"),
    installed_pkgs = pkgs,
    r_version = "4.6",
    services = "svc-a",
    shiny_url = "http://invalid",
    systemctl_check = function(unit) TRUE,
    http_check = function(url) TRUE,
    expected_configs = list(),
    marker_file = tempfile()
  )
  statuses <- vapply(res$results, `[[`, character(1), "status")
  expect_false(res$ok)
  expect_equal(res$results$packages$status, "fail")
  expect_equal(res$results$services$status, "ok")
})

test_that("doctor_run only runs the checks requested", {
  res <- doctor_run(
    checks = "configs",
    expected_configs = list()
  )
  expect_equal(names(res$results), "configs")
})

test_that("doctor_run rejects unknown check names", {
  expect_error(doctor_run(checks = "packges"), "Unknown doctor check")
})

test_that("doctor_run treats warn as not-ok (so timer notifies on drift)", {
  tmp <- withr::local_tempfile()
  writeLines("hello", tmp)
  # Wrong digest → check_configs returns warn; doctor_run must report ok=FALSE.
  res <- doctor_run(
    checks = "configs",
    expected_configs = setNames(list("00deadbeef"), tmp)
  )
  expect_equal(res$results$configs$status, "warn")
  expect_false(res$ok)
})

test_that("doctor_run runs the freshness check and reports ok=FALSE when stale", {
  res <- doctor_run(
    checks = "freshness",
    now = freshness_now,
    freshness_status_payload = freshness_payload(240, 240),
    freshness_args = list(data_dir = "", metrics_dir = tempfile(),
                          workouts_dir = tempfile(),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble())
  )
  expect_equal(names(res$results), "freshness")
  expect_equal(res$results$freshness$status, "fail")
  expect_false(res$ok)
})

test_that("doctor_run passes freshness_args through to the check", {
  # The check name must also stay in sync with inst/cli.R's
  # --doctor-check parsing.
  expect_true("freshness" %in% .VALID_DOCTOR_CHECKS)
  res <- doctor_run(
    checks = "freshness",
    now = freshness_now,
    freshness_status_payload = freshness_payload(1, 1),
    freshness_args = list(data_dir = "", metrics_dir = tempfile(),
                          workouts_dir = tempfile(),
                          health_daily = tibble::tibble(),
                          summaries = tibble::tibble())
  )
  expect_equal(res$results$freshness$status, "ok")
  expect_true(res$ok)
})

test_that("doctor_run uses injected r_version end-to-end", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "foo", LibPath = "/usr/lib/R/library",
         Built = "R 4.5.0; x86_64-pc-linux-gnu; 2025-12-01 12:00:00 UTC; unix")
  ))
  # Same matrix is OK against R 4.5 and stale against R 4.6 — proves
  # r_version is propagated to check_stale_builds and to the report.
  ok_res <- doctor_run(checks = "packages", installed_pkgs = pkgs,
                        r_version = "4.5", marker_file = tempfile())
  fail_res <- doctor_run(checks = "packages", installed_pkgs = pkgs,
                          r_version = "4.6", marker_file = tempfile())
  expect_equal(ok_res$results$packages$status, "ok")
  expect_equal(ok_res$r_version, "4.5")
  expect_equal(fail_res$results$packages$status, "fail")
  expect_equal(fail_res$r_version, "4.6")
})

test_that("format_doctor_json round-trips via jsonlite::fromJSON", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "foo", LibPath = "/usr/lib/R/library",
         Built = "R 4.6.0; x86_64-pc-linux-gnu; 2026-04-01 12:00:00 UTC; unix")
  ))
  res <- doctor_run(
    checks = "packages",
    installed_pkgs = pkgs,
    r_version = "4.6",
    expected_configs = list(),
    marker_file = tempfile()
  )
  parsed <- jsonlite::fromJSON(format_doctor_json(res), simplifyVector = FALSE)
  expect_true(parsed$ok)
  expect_equal(parsed$results$packages$status, "ok")
})

test_that("format_doctor_human produces a human-readable summary", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "foo", LibPath = "/usr/lib/R/library",
         Built = "R 4.6.0; x86_64-pc-linux-gnu; 2026-04-01 12:00:00 UTC; unix")
  ))
  res <- doctor_run(
    checks = "packages",
    installed_pkgs = pkgs,
    r_version = "4.6",
    expected_configs = list(),
    marker_file = tempfile()
  )
  txt <- format_doctor_human(res)
  expect_match(txt, "traning doctor")
  expect_match(txt, "All checks passed")
})
