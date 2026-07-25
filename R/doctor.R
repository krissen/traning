# Health checks for the traning deployment.
#
# Triggered daily via traning-doctor.timer on kailash and on demand via
# `traning doctor run`. Designed to detect the failure modes from the
# 2026-05-14 R 4.5→4.6 ABI incident: stale R-package builds that load
# only against the previous R minor, downed services that broke the
# HAE pipeline silently, and missing pacman/caddy config files that
# explain why a fresh boot didn't recover automatically.
#
# These are internal deployment-ops helpers, not part of the public
# `library(traning)` API — none carry an @export tag, so roxygen2
# leaves them out of NAMESPACE. Only inst/cli.R (loaded via
# devtools::load_all()) calls them; constants and small helpers are
# additionally dot-prefixed to stay internal within this file.

.REBUILD_MARKER <- "/var/lib/traning/needs-rebuild"

# Pinned SHA-256 digests for config files that live outside the repo.
# Update via scripts/compute_config_digests.R when the canonical source
# changes — the manual step is intentional, it forces an explicit
# acknowledgement that production config has drifted.
.EXPECTED_CONFIG_DIGESTS <- list(
  "/etc/pacman.d/hooks/traning-r-postupgrade.hook" =
    "80eb31f98204fbf20d651e8e5bbe392ad113d276487687691b42298c0e195ee6",
  "/etc/systemd/system/caddy.service.d/override.conf" =
    "e01f5fa7cfdbbed5ef6be22068d4805095f04caa78078d98290d68227b0348db"
)

.VALID_DOCTOR_CHECKS <- c("packages", "services", "configs", "freshness")

# --- Built-tag parsing ---------------------------------------------------

.r_xy <- function(version = NULL) {
  if (is.null(version)) {
    return(paste(R.version$major,
                  strsplit(R.version$minor, "\\.")[[1]][1],
                  sep = "."))
  }
  # Normalise caller-supplied versions ("4.6", "4.6.0", "R 4.6.0",
  # even "R 4.6.0; ...") down to "X.Y" so equality compares against
  # .parse_built_xy() output without surprise mismatches.
  s <- trimws(sub("^R\\s+", "", as.character(version)))
  s <- strsplit(s, "[;\\s]")[[1]][1]
  bits <- strsplit(s, "\\.")[[1]]
  if (length(bits) >= 2L) paste(bits[1], bits[2], sep = ".") else s
}

.parse_built_xy <- function(built) {
  if (is.na(built) || !nzchar(built)) return(NA_character_)
  first <- trimws(strsplit(built, ";", fixed = TRUE)[[1]][1])
  parts <- strsplit(first, "\\s+")[[1]]
  if (length(parts) < 2L) return(NA_character_)
  ver <- parts[[2]]
  bits <- strsplit(ver, "\\.")[[1]]
  if (length(bits) < 2L) return(NA_character_)
  paste(bits[1], bits[2], sep = ".")
}

# --- Checks --------------------------------------------------------------

.check_result <- function(name, status, message, details = NULL) {
  list(name = name, status = status, message = message, details = details)
}

check_stale_builds <- function(installed_pkgs = NULL,
                                r_version = NULL,
                                marker_file = .REBUILD_MARKER) {
  current <- .r_xy(r_version)
  if (is.null(installed_pkgs)) {
    installed_pkgs <- utils::installed.packages(
      lib.loc = .libPaths(), fields = "Built")
  }
  if (nrow(installed_pkgs) == 0L) {
    return(.check_result("packages", "ok",
      sprintf("No packages installed (R %s).", current)))
  }

  built_xy <- vapply(installed_pkgs[, "Built"],
                     .parse_built_xy, character(1))
  pkg_names <- installed_pkgs[, "Package"]
  lib_paths <- installed_pkgs[, "LibPath"]

  unknown <- is.na(built_xy)
  stale <- !unknown & built_xy != current

  details <- list(
    current_r = current,
    stale = unname(Map(list,
                        package = as.list(pkg_names[stale]),
                        lib = as.list(lib_paths[stale]),
                        built = as.list(built_xy[stale]))),
    unknown = unname(Map(list,
                          package = as.list(pkg_names[unknown]),
                          lib = as.list(lib_paths[unknown])))
  )

  marker_present <- file.exists(marker_file)
  if (any(stale)) {
    msg <- sprintf("%d package(s) built against R != %s.",
                    sum(stale), current)
    if (marker_present) {
      msg <- paste(msg,
        "Marker", marker_file,
        "exists — run `traning doctor rebuild-stale`.")
    }
    return(.check_result("packages", "fail", msg, details))
  }
  if (any(unknown)) {
    return(.check_result("packages", "warn",
      sprintf("%d package(s) have an unparseable Built tag.",
              sum(unknown)), details))
  }

  msg <- sprintf("All %d package(s) built against R %s.",
                  nrow(installed_pkgs), current)
  if (marker_present) {
    msg <- paste(msg, "Marker", marker_file,
                  "is present but no stale builds found.")
  }
  .check_result("packages", "ok", msg, details)
}

.systemctl_active <- function(unit) {
  status <- suppressWarnings(system2("systemctl",
    c("is-active", "--quiet", unit), stdout = FALSE, stderr = FALSE))
  identical(as.integer(status), 0L)
}

.receiver_health_url <- function() {
  # The receiver binds TRANING_RECEIVER_HOST:PORT (a Tailscale IP on
  # kailash), so probe that interface — not localhost, which the
  # receiver does not listen on. Host/port resolution lives in
  # .receiver_base_url() (R/freshness.R), shared with the /v1/status
  # probe.
  paste0(.receiver_base_url(), "/health")
}

.http_ok <- function(url, timeout = 5L, expected_status = "200") {
  # `curl -f` accepts any status < 400 (including 302 redirects), but
  # we want to assert that Shiny is genuinely serving — capture the
  # actual status and compare. `--max-time` covers connect+transfer.
  out <- suppressWarnings(system2("curl",
    c("-s", "--max-time", as.character(timeout),
      "-o", "/dev/null",
      "-w", "%{http_code}", url),
    stdout = TRUE, stderr = FALSE))
  identical(as.character(out)[1], expected_status)
}

check_services <- function(services = c("traning-receiver",
                                          "traning-shiny",
                                          "traning-vayu",
                                          "caddy"),
                            shiny_url = "http://127.0.0.1:8423/",
                            receiver_url = .receiver_health_url(),
                            systemctl_check = .systemctl_active,
                            http_check = .http_ok) {
  active <- vapply(services, systemctl_check, logical(1))
  shiny_ok <- http_check(shiny_url)
  # systemd is-active only proves the unit didn't exit — a receiver
  # that is up but wedged (or bound to the wrong interface) still
  # answers is-active TRUE. Probe /health so an active-but-not-serving
  # receiver — the failure mode that reads as "the pipeline is down" —
  # actually fails the check.
  receiver_ok <- http_check(receiver_url)

  details <- list(
    services = setNames(as.list(active), services),
    shiny_url = shiny_url,
    shiny_ok = shiny_ok,
    receiver_url = receiver_url,
    receiver_ok = receiver_ok
  )

  down <- services[!active]
  problems <- character(0)
  if (length(down) > 0L) {
    problems <- c(problems,
      sprintf("inactive: %s", paste(down, collapse = ", ")))
  }
  if (!shiny_ok) {
    problems <- c(problems,
      sprintf("Shiny did not respond at %s", shiny_url))
  }
  if (!receiver_ok) {
    problems <- c(problems,
      sprintf("receiver did not respond at %s", receiver_url))
  }

  if (length(problems) > 0L) {
    return(.check_result("services", "fail",
      paste(problems, collapse = "; "), details))
  }
  .check_result("services", "ok",
    sprintf("All %d service(s) active; Shiny and receiver responding.",
            length(services)), details)
}

check_configs <- function(expected = .EXPECTED_CONFIG_DIGESTS) {
  if (length(expected) == 0L) {
    return(.check_result("configs", "ok",
      "No config digests pinned."))
  }

  results <- lapply(names(expected), function(path) {
    want <- expected[[path]]
    if (!file.exists(path)) {
      return(list(path = path, state = "missing",
                   want = want, got = NA_character_))
    }
    if (is.na(want)) {
      return(list(path = path, state = "unpinned",
                   want = NA_character_,
                   got = unname(digest::digest(file = path,
                                                 algo = "sha256"))))
    }
    got <- unname(digest::digest(file = path, algo = "sha256"))
    state <- if (identical(got, want)) "ok" else "mismatch"
    list(path = path, state = state, want = want, got = got)
  })

  states <- vapply(results, `[[`, character(1), "state")
  details <- list(entries = results)

  if (any(states == "missing")) {
    missing_paths <- vapply(results[states == "missing"],
                              `[[`, character(1), "path")
    return(.check_result("configs", "fail",
      sprintf("missing: %s", paste(missing_paths, collapse = ", ")),
      details))
  }
  if (any(states == "mismatch")) {
    bad <- vapply(results[states == "mismatch"],
                    `[[`, character(1), "path")
    return(.check_result("configs", "warn",
      sprintf("digest mismatch: %s", paste(bad, collapse = ", ")),
      details))
  }
  if (any(states == "unpinned")) {
    unpinned <- vapply(results[states == "unpinned"],
                         `[[`, character(1), "path")
    return(.check_result("configs", "warn",
      sprintf("present but no digest pinned: %s",
              paste(unpinned, collapse = ", ")),
      details))
  }
  .check_result("configs", "ok",
    sprintf("All %d config digest(s) match.", length(expected)),
    details)
}

# Load just the summaries cache — the doctor only needs the newest
# sessionStart, so skip load_traning_data()'s myruns/decoupling slots
# and its legacy Garmin-augment fallback.
.freshness_load_summaries <- function(data_dir = Sys.getenv("TRANING_DATA")) {
  if (!nzchar(data_dir)) return(NULL)
  path <- file.path(data_dir, "cache", "summaries.RData")
  if (!file.exists(path)) return(NULL)
  env <- new.env(parent = emptyenv())
  load(path, envir = env)
  s <- env$summaries
  if (!inherits(s, "data.frame")) return(NULL)
  # trackeRdataSummary's [ method conflicts with dplyr; we only read
  # one column here, but strip it for consistency with my_dbs_load().
  if (inherits(s, "trackeRdataSummary")) class(s) <- "data.frame"
  s
}

# A dead HAE feed is invisible to every other check: services are up,
# packages are current, configs match — the pipeline simply has nothing
# to carry. Age of the newest data per flow is the only signal that
# separates "no training" from "no delivery", and the 2026-06-02 outage
# hit one flow while the other kept running, so a single aggregate
# would have stayed green.
#
# `...` is passed to data_freshness() — thresholds, inbox directories.
check_data_freshness <- function(health_daily = NULL,
                                  summaries = NULL,
                                  now = Sys.time(),
                                  status_payload = NULL,
                                  status_fetch = .receiver_status,
                                  receiver_configured = .receiver_key_present(),
                                  ...) {
  if (is.null(status_payload) && is.function(status_fetch)) {
    status_payload <- tryCatch(status_fetch(), error = function(e) NULL)
  }
  # The cache reads are the expensive part; the inbox mtimes and
  # /v1/status are cheap. Skip the summaries load when the receiver
  # already reported a workout import, and the health load when the
  # metrics inbox alone answers the question.
  if (is.null(health_daily)) {
    health_daily <- tryCatch(load_health_data(), error = function(e) NULL)
  }
  if (is.null(summaries) &&
      is.na(.parse_iso_time(status_payload[["last_workouts_import"]]))) {
    summaries <- tryCatch(.freshness_load_summaries(), error = function(e) NULL)
  }

  fresh <- data_freshness(health_daily = health_daily, summaries = summaries,
                           now = now,
                           status_payload = status_payload,
                           status_fetch = NULL, ...)

  # "unknown" means we could not measure at all — report it as warn so
  # the timer's OnFailure= path fires rather than passing green on a
  # blind spot.
  status <- if (identical(fresh$status, "unknown")) "warn" else fresh$status
  message <- fresh$message

  # Without an API key the receiver was never asked, and the only
  # evidence left is the age of this machine's copy of the data. On a
  # dev box that is the age of the last `git pull`, not the health of
  # the pipeline — reporting `fail` there teaches the reader to ignore
  # the check. Say plainly that it could not be assessed from here
  # instead; kailash has the key, so this never softens the real alarm.
  unqueryable <- !isTRUE(receiver_configured) && is.null(status_payload)
  if (unqueryable && status == "fail") {
    status <- "warn"
    message <- paste(
      "Receiver not queried (TRANING_API_KEY not set) — pipeline freshness",
      "cannot be assessed from this host; judged on local files only.",
      message)
  }

  details <- c(
    list(freshness_status = fresh$status,
         worst_flow = fresh$worst_flow,
         asymmetric = fresh$asymmetric,
         receiver_configured = isTRUE(receiver_configured),
         prose = fresh$prose,
         flows = lapply(fresh$flows, .freshness_flow_details)),
    fresh$details
  )
  .check_result("freshness", status, message, details)
}

.receiver_key_present <- function() {
  nzchar(trimws(Sys.getenv("TRANING_API_KEY")))
}

# POSIXct fields must be strings before format_doctor_json() serialises
# the result — toJSON drops the class otherwise.
.freshness_flow_details <- function(flow) {
  list(
    flow = flow$flow,
    status = flow$status,
    source = flow$source,
    age_hours = flow$age_hours,
    last_data = if (is.na(flow$last_data)) NA_character_
                else format(flow$last_data, "%Y-%m-%d %H:%M:%S"),
    warn_hours = flow$warn_hours,
    fail_hours = flow$fail_hours,
    tightened = flow$tightened,
    queue_state = flow$queue_state %||% "clear",
    in_flight = isTRUE(flow$in_flight)
  )
}

# --- Orchestration -------------------------------------------------------

doctor_run <- function(checks = .VALID_DOCTOR_CHECKS,
                        installed_pkgs = NULL,
                        services = NULL,
                        shiny_url = "http://127.0.0.1:8423/",
                        receiver_url = NULL,
                        expected_configs = .EXPECTED_CONFIG_DIGESTS,
                        marker_file = .REBUILD_MARKER,
                        r_version = NULL,
                        systemctl_check = NULL,
                        http_check = NULL,
                        freshness_status_payload = NULL,
                        freshness_status_fetch = .receiver_status,
                        freshness_args = list(),
                        now = Sys.time()) {
  invalid <- setdiff(checks, .VALID_DOCTOR_CHECKS)
  if (length(invalid) > 0L) {
    stop("Unknown doctor check(s): ", paste(invalid, collapse = ", "),
         ". Valid: ", paste(.VALID_DOCTOR_CHECKS, collapse = ", "))
  }

  results <- list()
  if ("packages" %in% checks) {
    results$packages <- check_stale_builds(installed_pkgs = installed_pkgs,
                                            r_version = r_version,
                                            marker_file = marker_file)
  }
  if ("services" %in% checks) {
    args <- list(shiny_url = shiny_url)
    if (!is.null(services))         args$services <- services
    if (!is.null(receiver_url))     args$receiver_url <- receiver_url
    if (!is.null(systemctl_check))  args$systemctl_check <- systemctl_check
    if (!is.null(http_check))       args$http_check <- http_check
    results$services <- do.call(check_services, args)
  }
  if ("configs" %in% checks) {
    results$configs <- check_configs(expected = expected_configs)
  }
  if ("freshness" %in% checks) {
    results$freshness <- do.call(check_data_freshness, c(
      list(now = now,
           status_payload = freshness_status_payload,
           status_fetch = freshness_status_fetch),
      freshness_args))
  }

  statuses <- vapply(results, `[[`, character(1), "status")
  # Treat warn as not-ok so the systemd unit's OnFailure= path notifies
  # on config-digest drift and on a data feed that has gone quiet,
  # instead of silently passing the timer green.
  ok <- !any(statuses %in% c("fail", "warn"))
  list(
    ok = ok,
    timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"),
    r_version = .r_xy(r_version),
    results = results,
    summary = sprintf("%d ok, %d warn, %d fail",
                       sum(statuses == "ok"),
                       sum(statuses == "warn"),
                       sum(statuses == "fail"))
  )
}

# --- Formatters ----------------------------------------------------------

.status_glyph <- function(status) {
  switch(status, ok = "OK  ", warn = "WARN", fail = "FAIL", "??  ")
}

format_doctor_human <- function(result) {
  lines <- c(
    sprintf("traning doctor — %s", result$timestamp),
    sprintf("R %s — %s", result$r_version, result$summary),
    ""
  )
  for (r in result$results) {
    lines <- c(lines,
      sprintf("[%s] %s: %s", .status_glyph(r$status), r$name, r$message))
  }
  lines <- c(lines, "",
    if (result$ok) "All checks passed." else "Some checks failed.")
  paste0(paste(lines, collapse = "\n"), "\n")
}

format_doctor_json <- function(result) {
  jsonlite::toJSON(result, auto_unbox = TRUE, null = "null",
                    na = "string", pretty = TRUE)
}

# --- Rebuild -------------------------------------------------------------

rebuild_stale_userlib <- function(lib = Sys.getenv("R_LIBS_USER",
                                                     "~/R/library"),
                                   r_version = NULL,
                                   marker_file = .REBUILD_MARKER) {
  lib <- path.expand(lib)
  if (!dir.exists(lib)) {
    message("User library does not exist: ", lib)
    return(invisible(NULL))
  }
  current <- .r_xy(r_version)
  installed <- utils::installed.packages(lib.loc = lib, fields = "Built")
  if (nrow(installed) == 0L) {
    message("No packages in ", lib)
    return(invisible(NULL))
  }
  built_xy <- vapply(installed[, "Built"], .parse_built_xy, character(1))
  stale <- !is.na(built_xy) & built_xy != current
  pkgs <- installed[stale, "Package"]

  if (length(pkgs) == 0L) {
    message("No stale builds in ", lib, " (R ", current, ").")
    if (file.exists(marker_file)) {
      message("Removing marker ", marker_file, ".")
      unlink(marker_file)
    }
    return(invisible(character(0)))
  }

  message("Rebuilding ", length(pkgs), " package(s) into ", lib, ":")
  for (p in pkgs) message("  - ", p)
  utils::install.packages(pkgs, lib = lib)

  if (file.exists(marker_file)) {
    message("Removing marker ", marker_file, ".")
    unlink(marker_file)
  }
  invisible(pkgs)
}
