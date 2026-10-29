# Full testthat suite runner, shared by the pre-push hook
# (.hooks/testthat.R) and `make check`.
#
# Why this file exists (krissen/traning#91): R auto-sources .Renviron at
# startup, so on a developer machine TRANING_DATA usually points at the
# live data directory. A handful of tests write cache files under
# $TRANING_DATA/cache (load_zone_distribution(), load_decoupling()), and
# once the suite runs automatically on every `git push`, that makes a
# push a possible mutation of real cached data.
#
# The fix is to run the suite against an isolated, populated copy of the
# data directory:
#
#   * every top-level entry except `cache` is symlinked into a temp
#     sandbox (reads behave exactly as against the live directory),
#   * `cache` is copied (the directory tests write to),
#   * TRANING_DATA points at the sandbox for the run and is restored
#     afterwards.
#
# Redirecting TRANING_DATA at an *empty* temp directory would not work:
# the integration tests gate on `Sys.getenv("TRANING_DATA") == ""`, so an
# empty-but-set value turns "skip" into "run and fail" and changes which
# tests execute. A populated copy keeps that distinction and also avoids
# restoring over live files: a receiver import that lands during the run
# writes to the real cache and is never rolled back.

.traning_live_data_dir <- function() {
  td <- Sys.getenv("TRANING_DATA", unset = "")
  if (!nzchar(td) || !dir.exists(td)) {
    return(NULL)
  }
  normalizePath(td, mustWork = TRUE)
}

.traning_copy_dir <- function(from, to) {
  ok <- file.copy(
    from,
    to,
    recursive = TRUE,
    copy.mode = TRUE,
    copy.date = TRUE
  )
  if (!isTRUE(ok)) {
    stop("could not copy data directory entry: ", from, call. = FALSE)
  }
  invisible(TRUE)
}

.traning_make_sandbox <- function(live) {
  sandbox <- tempfile("traning-test-data-")
  dir.create(sandbox, recursive = TRUE)

  entries <- list.files(
    live,
    all.files = TRUE,
    no.. = TRUE,
    full.names = FALSE
  )
  for (entry in entries) {
    src <- file.path(live, entry)
    dst <- file.path(sandbox, entry)
    if (entry == "cache") {
      # Tests write here, so it must be a real copy, not a link.
      if (dir.exists(src)) {
        dir.create(dst)
        inner <- list.files(src, all.files = TRUE, no.. = TRUE, full.names = FALSE)
        for (item in inner) {
          .traning_copy_dir(file.path(src, item), dst)
        }
      }
    } else if (!isTRUE(file.symlink(src, dst))) {
      # Platforms without symlink support get a real copy. Slower, but
      # still isolated from the live tree.
      .traning_copy_dir(src, sandbox)
    }
  }
  sandbox
}

# Run `expr` with TRANING_DATA pointing at an isolated copy of the live
# data directory. When TRANING_DATA is unset/empty or does not exist,
# this is a no-op and `expr` sees the caller's environment unchanged.
with_isolated_data <- function(expr) {
  live <- .traning_live_data_dir()
  if (is.null(live)) {
    return(eval(expr, envir = parent.frame()))
  }

  sandbox <- .traning_make_sandbox(live)
  old <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  Sys.setenv(TRANING_DATA = sandbox)
  on.exit(
    {
      if (is.na(old)) {
        Sys.unsetenv("TRANING_DATA")
      } else {
        Sys.setenv(TRANING_DATA = old)
      }
      unlink(sandbox, recursive = TRUE)
    },
    add = TRUE
  )

  eval(expr, envir = parent.frame())
}

run_traning_tests <- function(pkg = ".") {
  with_isolated_data({
    devtools::test(pkg, stop_on_failure = TRUE)
    TRUE
  })
}

# Returns TRUE on a green suite, FALSE otherwise. Shared entry point so
# the hook and a direct `Rscript scripts/run_testthat.R` behave alike.
run_traning_tests_cli <- function(pkg = ".") {
  if (!requireNamespace("devtools", quietly = TRUE)) {
    message(
      "testthat: the 'devtools' package is required to run the ",
      "test suite — install it: install.packages('devtools')"
    )
    return(FALSE)
  }
  suppressMessages(library(devtools))

  tryCatch(
    run_traning_tests(pkg),
    error = function(e) {
      message("testthat: ", conditionMessage(e))
      FALSE
    }
  )
}

if (sys.nframe() == 0L) {
  if (!isTRUE(run_traning_tests_cli(.traning_runner_repo_root()))) {
    quit(status = 1)
  }
}
