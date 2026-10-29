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
# The fix is deliberately *not* to redirect TRANING_DATA at a temp dir:
# the suite's integration tests gate on `Sys.getenv("TRANING_DATA") == ""`,
# so an empty-but-set value turns "skip" into "run and fail" and changes
# which tests execute. Instead the cache directory is snapshotted before
# the suite and restored afterwards, so every test sees exactly the same
# TRANING_DATA it would otherwise have seen.

.traning_cache_dir <- function() {
  td <- Sys.getenv("TRANING_DATA", unset = "")
  if (!nzchar(td)) {
    return(NULL)
  }
  cache <- file.path(td, "cache")
  if (!dir.exists(cache)) {
    return(NULL)
  }
  normalizePath(cache, mustWork = TRUE)
}

.traning_rel_files <- function(dir) {
  list.files(
    dir,
    recursive = TRUE,
    all.files = TRUE,
    no.. = TRUE,
    full.names = FALSE
  )
}

.traning_rel_dirs <- function(dir) {
  # list.dirs() includes the root as "", which callers skip.
  list.dirs(dir, recursive = TRUE, full.names = FALSE)
}

.traning_cache_backup <- function(cache) {
  backup <- tempfile("traning-cache-backup-")
  dir.create(backup, recursive = TRUE)
  dirs <- .traning_rel_dirs(cache)
  for (d in dirs[nzchar(dirs)]) {
    dir.create(file.path(backup, d), recursive = TRUE, showWarnings = FALSE)
  }
  files <- .traning_rel_files(cache)
  for (f in files) {
    ok <- file.copy(
      file.path(cache, f),
      file.path(backup, f),
      overwrite = TRUE,
      copy.mode = TRUE,
      copy.date = TRUE
    )
    if (!isTRUE(ok)) {
      stop("could not back up cache file: ", f, call. = FALSE)
    }
  }
  backup
}

.traning_cache_restore <- function(cache, backup) {
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
  backup_files <- .traning_rel_files(backup)
  backup_dirs <- .traning_rel_dirs(backup)
  current_files <- .traning_rel_files(cache)
  current_dirs <- .traning_rel_dirs(cache)

  # Files the tests created (and directories they created) go away.
  new_files <- setdiff(current_files, backup_files)
  if (length(new_files) > 0) {
    unlink(file.path(cache, new_files), force = TRUE)
  }

  # Restore every backed-up directory, then every backed-up file.
  for (d in backup_dirs[nzchar(backup_dirs)]) {
    dir.create(file.path(cache, d), recursive = TRUE, showWarnings = FALSE)
  }
  for (f in backup_files) {
    ok <- file.copy(
      file.path(backup, f),
      file.path(cache, f),
      overwrite = TRUE,
      copy.mode = TRUE,
      copy.date = TRUE
    )
    if (!isTRUE(ok)) {
      warning("could not restore cache file: ", f, call. = FALSE)
    }
  }

  # Drop directories the tests created, now that their files are gone.
  new_dirs <- setdiff(current_dirs, backup_dirs)
  for (d in new_dirs[nzchar(new_dirs)]) {
    unlink(file.path(cache, d), recursive = TRUE)
  }

  unlink(backup, recursive = TRUE)
  invisible(TRUE)
}

# Run `expr` with $TRANING_DATA/cache snapshotted and restored. When
# TRANING_DATA is unset/empty, or there is no cache directory, this is a
# no-op and `expr` runs against whatever environment the caller has.
with_protected_cache <- function(expr) {
  cache <- .traning_cache_dir()
  if (is.null(cache)) {
    return(eval(expr, envir = parent.frame()))
  }

  backup <- .traning_cache_backup(cache)
  on.exit(
    tryCatch(
      .traning_cache_restore(cache, backup),
      error = function(e) {
        warning(
          "could not restore $TRANING_DATA/cache after the test run: ",
          conditionMessage(e),
          "\nBackup kept at: ", backup,
          call. = FALSE
        )
      }
    ),
    add = TRUE
  )
  eval(expr, envir = parent.frame())
}

run_traning_tests <- function() {
  with_protected_cache({
    devtools::test(stop_on_failure = TRUE)
    TRUE
  })
}

# Returns TRUE on a green suite, FALSE otherwise. Shared entry point so
# the hook and a direct `Rscript scripts/run_testthat.R` behave alike.
run_traning_tests_cli <- function() {
  if (!requireNamespace("devtools", quietly = TRUE)) {
    message(
      "testthat: the 'devtools' package is required to run the ",
      "test suite — install it: install.packages('devtools')"
    )
    return(FALSE)
  }
  suppressMessages(library(devtools))

  tryCatch(
    run_traning_tests(),
    error = function(e) {
      message("testthat: ", conditionMessage(e))
      FALSE
    }
  )
}

if (sys.nframe() == 0L) {
  if (!isTRUE(run_traning_tests_cli())) quit(status = 1)
}
