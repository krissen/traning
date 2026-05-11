# R-side wrapper around the `traning` Python CLI.
#
# Shiny + other R code needs to invoke backfill / import flows that
# live in the Python package. Rather than bundling a Python runtime
# inside R (reticulate adds non-trivial weight), we shell out via
# system2() to the same CLI users run from a terminal.

#' Locate the `traning` Python CLI executable
#'
#' Resolution order:
#' \enumerate{
#'   \item \code{TRANING_CLI} environment variable, if it points at an
#'     executable file.
#'   \item Bundled venv at \code{<repo>/python/.venv/bin/traning}
#'     (the layout produced by \code{python/setup_venv.sh}).
#'   \item \code{Sys.which("traning")}.
#' }
#'
#' @return Absolute path to the CLI binary, or \code{NA_character_}
#'   if none of the candidates are found.
#' @export
traning_cli_path <- function() {
  env_path <- Sys.getenv("TRANING_CLI", unset = "")
  if (nzchar(env_path) && file.exists(env_path)) {
    return(normalizePath(env_path, mustWork = FALSE))
  }

  # Find the bundled venv. The package may be loaded via
  # devtools::load_all() (development) or installed; in both cases
  # the venv lives at <repo-root>/python/.venv/bin/traning when the
  # standard setup_venv.sh has been run.
  pkg_root <- tryCatch(
    normalizePath(system.file(package = "traning"), mustWork = FALSE),
    error = function(e) ""
  )
  if (nzchar(pkg_root)) {
    candidates <- c(
      file.path(pkg_root, "..", "python", ".venv", "bin", "traning"),
      file.path(pkg_root, "..", "..", "python", ".venv", "bin", "traning")
    )
    for (cand in candidates) {
      if (file.exists(cand)) {
        return(normalizePath(cand, mustWork = FALSE))
      }
    }
  }

  which_path <- Sys.which("traning")
  if (nzchar(which_path)) {
    return(unname(which_path))
  }

  NA_character_
}


#' Run `traning backfill <zip>` and capture the result
#'
#' @param zip_path Path to the archive to backfill from.
#' @param dry_run Logical. If TRUE, passes \code{--dry-run} so the
#'   CLI reports what it *would* write without touching disk. Useful
#'   for upload-preview flows.
#' @param cli_path Optional explicit binary path. Defaults to
#'   \code{traning_cli_path()}.
#' @return A list with elements:
#'   \describe{
#'     \item{success}{Logical: did the subprocess exit cleanly?}
#'     \item{exit_code}{Integer exit code.}
#'     \item{counts}{Named integer vector: metric → n new files.
#'       Empty when the CLI reports nothing or when parsing fails.}
#'     \item{stdout}{Character vector, raw stdout lines.}
#'     \item{stderr}{Character vector, raw stderr lines.}
#'   }
#' @export
traning_backfill <- function(zip_path, dry_run = FALSE, cli_path = NULL) {
  if (is.null(cli_path)) cli_path <- traning_cli_path()
  if (is.na(cli_path)) {
    return(list(
      success = FALSE, exit_code = -1L, counts = integer(0),
      stdout = character(0),
      stderr = "Could not locate the `traning` CLI. Set TRANING_CLI."
    ))
  }
  if (!file.exists(zip_path)) {
    return(list(
      success = FALSE, exit_code = -1L, counts = integer(0),
      stdout = character(0),
      stderr = paste0("Archive does not exist: ", zip_path)
    ))
  }

  args <- c("backfill", zip_path)
  if (isTRUE(dry_run)) args <- c("backfill", "--dry-run", zip_path)

  stderr_file <- tempfile("traning_backfill_stderr_")
  on.exit(unlink(stderr_file), add = TRUE)
  out <- suppressWarnings(system2(cli_path, args = shQuote(args),
                                   stdout = TRUE, stderr = stderr_file))
  exit_code <- attr(out, "status")
  if (is.null(exit_code)) exit_code <- 0L
  stderr_lines <- if (file.exists(stderr_file)) {
    readLines(stderr_file, warn = FALSE)
  } else character(0)

  counts <- .parse_backfill_counts(out)

  list(
    success   = exit_code == 0L,
    exit_code = as.integer(exit_code),
    counts    = counts,
    stdout    = as.character(out),
    stderr    = stderr_lines
  )
}


# Internal: parse the `traning backfill` stdout lines into a named
# integer vector. Format produced by main.py:backfill():
#   "  weight_body_mass: Wrote 12 new files"
#   "  body_fat_percentage: Would write 0 new files"
.parse_backfill_counts <- function(lines) {
  if (length(lines) == 0) return(integer(0))
  re <- "^\\s*([A-Za-z0-9_]+):\\s+(?:Wrote|Would write)\\s+(\\d+)\\s+new files"
  matched <- regmatches(lines, regexec(re, lines))
  counts <- integer(0)
  for (m in matched) {
    if (length(m) == 3L) {
      metric <- m[[2]]
      n <- suppressWarnings(as.integer(m[[3]]))
      if (!is.na(n)) counts[metric] <- n
    }
  }
  counts
}
