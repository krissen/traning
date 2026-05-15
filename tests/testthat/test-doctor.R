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

test_that("check_services is OK when all services active and Shiny responds", {
  res <- check_services(
    services = c("svc-a", "svc-b"),
    shiny_url = "http://invalid",
    systemctl_check = function(unit) TRUE,
    http_check = function(url) TRUE
  )
  expect_equal(res$status, "ok")
})

test_that("check_services fails when a service is down", {
  res <- check_services(
    services = c("svc-a", "svc-b"),
    shiny_url = "http://invalid",
    systemctl_check = function(unit) unit != "svc-b",
    http_check = function(url) TRUE
  )
  expect_equal(res$status, "fail")
  expect_match(res$message, "svc-b")
})

test_that("check_services fails when Shiny does not respond", {
  res <- check_services(
    services = "svc-a",
    shiny_url = "http://invalid:8423/",
    systemctl_check = function(unit) TRUE,
    http_check = function(url) FALSE
  )
  expect_equal(res$status, "fail")
  expect_match(res$message, "Shiny")
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

# --- doctor_run ----------------------------------------------------------

test_that("doctor_run reports ok=FALSE when any check fails", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "rlang", LibPath = "/home/user/R/library",
         Built = "R 4.5.3; x86_64-pc-linux-gnu; 2025-12-01 12:00:00 UTC; unix")
  ))
  res <- doctor_run(
    checks = c("packages", "services"),
    installed_pkgs = pkgs,
    services = "svc-a",
    shiny_url = "http://invalid",
    expected_configs = list(),
    marker_file = tempfile()
  )
  # packages is fail, services depends on env — just assert ok mirrors
  # the underlying statuses.
  statuses <- vapply(res$results, `[[`, character(1), "status")
  expect_false(res$ok)
  expect_true("fail" %in% statuses)
})

test_that("doctor_run only runs the checks requested", {
  res <- doctor_run(
    checks = "configs",
    expected_configs = list()
  )
  expect_equal(names(res$results), "configs")
})

test_that("format_doctor_json round-trips via jsonlite::fromJSON", {
  pkgs <- make_pkg_matrix(list(
    list(Package = "foo", LibPath = "/usr/lib/R/library",
         Built = "R 4.6.0; x86_64-pc-linux-gnu; 2026-04-01 12:00:00 UTC; unix")
  ))
  res <- doctor_run(
    checks = "packages",
    installed_pkgs = pkgs,
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
    expected_configs = list(),
    marker_file = tempfile()
  )
  txt <- format_doctor_human(res)
  expect_match(txt, "traning doctor")
  expect_match(txt, "All checks passed")
})
