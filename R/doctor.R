# Health checks for the traning deployment.
#
# Triggered daily via traning-doctor.timer on kailash and on demand via
# `traning doctor run`. Designed to detect the failure modes from the
# 2026-05-14 R 4.5→4.6 ABI incident: stale R-package builds that load
# only against the previous R minor, downed services that broke the
# HAE pipeline silently, and missing pacman/caddy config files that
# explain why a fresh boot didn't recover automatically.
#
# Functions here are exported via NAMESPACE's exportPattern("^[^\\.]")
# alongside the rest of the package; constants and small helpers are
# dot-prefixed to stay internal.

.REBUILD_MARKER <- "/var/lib/traning/needs-rebuild"

# Pinned SHA-256 digests for config files that live outside the repo.
# Update via scripts/compute_config_digests.R when the canonical source
# changes — the manual step is intentional, it forces an explicit
# acknowledgement that production config has drifted.
.EXPECTED_CONFIG_DIGESTS <- list(
  "/etc/pacman.d/hooks/traning-r-postupgrade.hook" =
    "80eb31f98204fbf20d651e8e5bbe392ad113d276487687691b42298c0e195ee6",
  "/etc/systemd/system/caddy.service.d/override.conf" =
    "f247bfc5ea105114cc9a1a6d99de5ce7f10779cb9819fefb317a7d734a04cbd1"
)

.VALID_DOCTOR_CHECKS <- c("packages", "services", "configs")

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
                                          "caddy"),
                            shiny_url = "http://127.0.0.1:8423/",
                            systemctl_check = .systemctl_active,
                            http_check = .http_ok) {
  active <- vapply(services, systemctl_check, logical(1))
  shiny_ok <- http_check(shiny_url)

  details <- list(
    services = setNames(as.list(active), services),
    shiny_url = shiny_url,
    shiny_ok = shiny_ok
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

  if (length(problems) > 0L) {
    return(.check_result("services", "fail",
      paste(problems, collapse = "; "), details))
  }
  .check_result("services", "ok",
    sprintf("All %d service(s) active and Shiny responding.",
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

# --- Orchestration -------------------------------------------------------

doctor_run <- function(checks = .VALID_DOCTOR_CHECKS,
                        installed_pkgs = NULL,
                        services = NULL,
                        shiny_url = "http://127.0.0.1:8423/",
                        expected_configs = .EXPECTED_CONFIG_DIGESTS,
                        marker_file = .REBUILD_MARKER,
                        r_version = NULL,
                        systemctl_check = NULL,
                        http_check = NULL) {
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
    if (!is.null(systemctl_check))  args$systemctl_check <- systemctl_check
    if (!is.null(http_check))       args$http_check <- http_check
    results$services <- do.call(check_services, args)
  }
  if ("configs" %in% checks) {
    results$configs <- check_configs(expected = expected_configs)
  }

  statuses <- vapply(results, `[[`, character(1), "status")
  ok <- !any(statuses == "fail")
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
