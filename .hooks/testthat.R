# Full testthat suite, run by the system R at pre-push (not pre-commit —
# too slow for every commit; see .pre-commit-config.yaml).
#
# The suite itself lives in scripts/run_testthat.R so the hook and
# `make check` share one entry point. That runner points TRANING_DATA at
# an isolated copy of the data directory for the duration, so an
# automatic suite run cannot mutate live cached data (krissen/traning#91).
args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args, value = TRUE)
script_dir <- if (length(file_arg) > 0) {
  dirname(normalizePath(sub("^--file=", "", file_arg[1])))
} else {
  getwd()
}
repo_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)

source(file.path(repo_root, "scripts", "run_testthat.R"), local = FALSE)

if (!isTRUE(run_traning_tests_cli())) quit(status = 1)
