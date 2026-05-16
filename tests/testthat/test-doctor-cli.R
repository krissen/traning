# Smoke-tests for the `--doctor` CLI dispatch path in inst/cli.R.
#
# Keeps assumptions minimal: only the packages-check is exercised so
# the test does not depend on systemctl / curl / config files being
# present in the test environment. The JSON shape is the contract
# that `traning-doctor.service` writes to the journal and that any
# downstream JSON consumers parse.

run_doctor <- function(json = TRUE, check = "packages") {
  cli <- file.path(testthat::test_path("..", ".."), "inst", "cli.R")
  args <- c(cli, "--doctor", paste0("--doctor-check=", check))
  if (json) args <- c(args, "--doctor-json")
  out <- suppressWarnings(
    system2("Rscript", args = args, stdout = TRUE, stderr = NULL))
  list(
    text = paste(out, collapse = "\n"),
    exit = attr(out, "status") %||% 0L
  )
}

`%||%` <- function(a, b) if (is.null(a)) b else a

test_that("--doctor --doctor-json --doctor-check=packages returns valid JSON", {
  # Doctor dispatches before TRANING_DATA validation in inst/cli.R, so
  # this must work even with TRANING_DATA unset. Clear it explicitly
  # here to lock that contract — a regression where doctor starts
  # depending on TRANING_DATA would silently make the test pass on
  # dev boxes and fail in minimal environments.
  withr::local_envvar(TRANING_DATA = "")
  out <- run_doctor(json = TRUE, check = "packages")
  parsed <- jsonlite::fromJSON(out$text, simplifyVector = FALSE)
  expect_named(parsed,
    c("ok", "timestamp", "r_version", "results", "summary"),
    ignore.order = TRUE)
  expect_named(parsed$results, "packages")
  expect_true(parsed$results$packages$status %in% c("ok", "warn", "fail"))
})

test_that("--doctor (human) prints a summary line", {
  withr::local_envvar(TRANING_DATA = "")
  out <- run_doctor(json = FALSE, check = "packages")
  expect_match(out$text, "traning doctor")
  expect_match(out$text, "packages")
})
