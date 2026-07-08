# Data I/O: load, save, and import workout data

# Workaround for trackeR 1.6.1 bug: change_units() uses get() to find
# unit conversion functions by name in the calling environment, but they
# are not exported from the trackeR namespace. Copy all conversion
# functions into this package's namespace so get() can find them.
.onLoad <- function(libname, pkgname) {
  ns <- asNamespace("trackeR")
  pkg_env <- parent.env(environment())
  for (fn_name in ls(ns, pattern = "2")) {
    obj <- get(fn_name, envir = ns)
    if (is.function(obj)) {
      assign(fn_name, obj, envir = pkg_env)
    }
  }

  # S7 packages must call methods_register() on load so that methods for
  # external generics (e.g. base::print, base::format for the S7 classes
  # in R/traning_data.R) are registered correctly. See ?S7::methods_register.
  S7::methods_register()

  # Load the shared metric taxonomy (inst/metric_taxonomy.json, shared
  # with the Python side) once per session rather than re-reading the
  # JSON on every call. .sum_metrics is used throughout R/health_export.R
  # via `%in% .sum_metrics`.
  taxonomy <- .load_metric_taxonomy()
  .sum_metrics <<- taxonomy$sum_metrics
}

#' Save summaries and myruns to RData files
#' @param db_summaries Path to summaries.RData
#' @param db_myruns Path to myruns.RData
#' @param summaries Data frame of workout summaries
#' @param myruns List of trackeR run objects
#' @export
my_dbs_save <- function(db_summaries, db_myruns, summaries, myruns) {
  summaries <- dplyr::arrange(summaries, sessionStart)
  # Dedup within a source (exact-second match). Cross-source dedup runs
  # at import time (with a tolerance window) — see import_hae_workouts().
  if ("source" %in% names(summaries)) {
    summaries <- dplyr::distinct(summaries, sessionStart, source,
                                 .keep_all = TRUE)
  } else {
    summaries <- dplyr::distinct(summaries, sessionStart, .keep_all = TRUE)
  }
  save_atomic(myruns, file = db_myruns)
  save_atomic(summaries, file = db_summaries)
}

#' Load summaries and myruns from RData files
#' @param db_summaries Path to summaries.RData
#' @param db_myruns Path to myruns.RData
#' @return List with elements "summaries" and "myruns"
#' @export
my_dbs_load <- function(db_summaries, db_myruns) {
  if (file.exists(db_summaries)) {
    load(db_summaries)
  } else {
    summaries <- data.frame()
  }
  if (file.exists(db_myruns)) {
    load(db_myruns)
  } else {
    myruns <- list()
  }

  # Strip trackeRdataSummary class — its [ method conflicts with dplyr
  if (inherits(summaries, "trackeRdataSummary")) {
    class(summaries) <- "data.frame"
  }

  # Backfill source column for caches predating multi-source support.
  if (is.data.frame(summaries) && nrow(summaries) > 0 &&
      !"source" %in% names(summaries)) {
    summaries$source <- "tcx"
  }

  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
  return(my_templist)
}

#' List all TCX files in a directory
#' @param mytcxpath Path to directory containing TCX files
#' @return Character vector of full file paths
#' @export
get_my_files <- function(mytcxpath) {
  files <- list.files(
    path = mytcxpath,
    recursive = TRUE,
    pattern = "*.tcx",
    ignore.case = TRUE,
    full.names = TRUE
  )
  return(files)
}

#' Import new TCX workouts not already in summaries
#' @param files Character vector of TCX file paths
#' @param summaries Existing summaries data frame
#' @param myruns Existing myruns list
#' @param verbose Logical, print progress messages (default FALSE)
#' @return List with elements "summaries" and "myruns"
#' @export
get_new_workouts <- function(files, summaries, myruns, verbose = FALSE,
                             batch_size = 500,
                             db_summaries = NULL, db_myruns = NULL) {
  # Match on basename to handle relative vs absolute path mismatches
  existing_basenames <- if ("file" %in% names(summaries))
    basename(summaries$file[!is.na(summaries$file)]) else character(0)
  existing_starts <- if ("sessionStart" %in% names(summaries))
    summaries$sessionStart else as.POSIXct(character(0))
  n_imported <- 0
  n_updated <- 0
  for (i in seq_along(files)) {
    thefile <- files[[i]]
    if (basename(thefile) %in% existing_basenames) {
      if (verbose) {
        cat("Redan inläst: ", basename(thefile), "\n", sep = "")
      }
    } else {
      if (verbose) {
        cat("Läser in ", basename(files[[i]]), " ... ", sep = "")
      }
      parsed <- tryCatch({
        trackeR::read_container(files[[i]])
      }, error = function(e) {
        warning("Kunde inte läsa: ", basename(files[[i]]),
                " (", conditionMessage(e), ")", call. = FALSE)
        NULL
      })
      if (is.null(parsed)) next

      run_summary <- summary(parsed)
      class(run_summary) <- "data.frame"

      # Dedup by sessionStart: same activity may exist under a different
      # filename (renamed TCX, symlink mismatch, etc.). If the timestamp
      # matches within 2 s, skip the file. Only update the cached filename
      # if the old file no longer exists (actual rename vs. two copies).
      ss <- run_summary$sessionStart
      dup_idx <- which(abs(difftime(existing_starts, ss, units = "secs")) < 2)
      if (length(dup_idx) > 0) {
        existing_basenames <- c(existing_basenames, basename(thefile))
        old_path <- summaries$file[dup_idx[1]]
        if (!file.exists(old_path)) {
          summaries$file[dup_idx[1]] <- thefile
          n_updated <- n_updated + 1
          if (verbose) {
            cat("dublett av ", basename(old_path),
                " (saknas), uppdaterar filnamn\n", sep = "")
          }
        } else if (verbose) {
          cat("dublett av ", basename(old_path), ", hoppar över\n", sep = "")
        }
        next
      }

      if (verbose) cat("OK\n")
      # Strip trackeRdataSummary class before dplyr operations —
      # its [ method conflicts with dplyr::mutate() and causes
      # row expansion (1 row becomes 28)
      run_summary <- add_my_columns(run_summary)
      run_summary$source <- "tcx"
      # If summaries is empty we may not yet have the same columns; align.
      if (nrow(summaries) == 0) {
        summaries <- run_summary
      } else {
        summaries <- .rbind_align(summaries, run_summary)
      }
      # Assign myruns by the row position this session actually landed
      # on in `summaries` (nrow(summaries) after the append above), not
      # by the loop index over `files`. `files` enumerates every file on
      # disk while duplicates/parse failures are skipped via `next`
      # without touching summaries, so the loop index drifts away from
      # the summaries row count — indexing by it here silently paired
      # myruns[[i]] with the wrong summaries row (or clobbered an
      # unrelated existing entry) once any file in the batch was skipped.
      myruns[[nrow(summaries)]] <- parsed
      existing_basenames <- c(existing_basenames, basename(thefile))
      existing_starts <- c(existing_starts, ss)
      n_imported <- n_imported + 1

      # Checkpoint: save every batch_size imports
      if (n_imported %% batch_size == 0 &&
          !is.null(db_summaries) && !is.null(db_myruns)) {
        if (verbose) cat("  Checkpoint: ", n_imported, " importerade, sparar...\n", sep = "")
        my_dbs_save(db_summaries, db_myruns, summaries, myruns)
      }
    }
  }
  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
  my_templist[["n_updated"]] <- n_updated
  return(my_templist)
}

#' Repair myruns entries that are NULL despite having a summaries row
#'
#' Goes through all summaries rows and, for each one where the
#' corresponding myruns entry is NULL or missing, attempts to re-parse
#' the original TCX file.  This repairs the gap left when files were
#' added to summaries but failed to parse into myruns on first import.
#'
#' @param files Character vector of TCX file paths (from \code{get_my_files()}).
#' @param summaries Existing summaries data frame.
#' @param myruns Existing myruns list.
#' @param verbose Logical. Print progress messages.
#' @return List with elements "summaries" and "myruns" (summaries unchanged,
#'   myruns with repaired entries).
#' @export
repair_myruns <- function(files, summaries, myruns, verbose = FALSE) {
  n_summaries <- nrow(summaries)
  file_basenames <- basename(files)

  # Hitta alla rader med saknad myruns
  null_indices <- which(vapply(seq_len(n_summaries), function(i) {
    i > length(myruns) || is.null(myruns[[i]])
  }, logical(1)))

  n_null <- length(null_indices)
  if (n_null == 0) {
    message("myruns: inga saknade poster att reparera.")
    return(list(summaries = summaries, myruns = myruns))
  }

  message("myruns-reparation: ", n_null, " saknade poster, f\u00f6rs\u00f6ker reparera ...")
  n_repaired <- 0L
  n_failed <- 0L
  n_no_file <- 0L

  for (idx in seq_along(null_indices)) {
    i <- null_indices[idx]

    if (idx %% 200 == 0 || idx == 1) {
      message("  ", idx, " / ", n_null, " ...")
    }

    # HAE rows have no on-disk TCX to re-parse; skip silently.
    if ("source" %in% names(summaries) &&
        isTRUE(summaries$source[i] == "hae")) next

    summary_file <- summaries$file[i]
    if (is.na(summary_file) || nchar(summary_file) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    match_idx <- which(file_basenames == basename(summary_file))
    if (length(match_idx) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    file_path <- files[match_idx[1]]

    myruns[[i]] <- tryCatch({
      trackeR::read_container(file_path)
    }, error = function(e) {
      n_failed <<- n_failed + 1L
      NULL
    })

    if (!is.null(myruns[[i]])) {
      n_repaired <- n_repaired + 1L
    }
  }

  message("myruns-reparation klar: ", n_repaired, " reparerade, ",
          n_failed, " misslyckade, ", n_no_file, " utan matchande fil.")

  list(summaries = summaries, myruns = myruns)
}

#' Repair myruns entries with missing per-second heart rate data
#'
#' Finds sessions where summaries has avgHeartRateMoving > 0 but the
#' corresponding myruns entry has no usable HR values (all NA or zero).
#' Re-parses the original TCX file to recover the data.
#'
#' This addresses a historical issue where trackeR silently dropped HR
#' data during import (likely a bug in an older trackeR version or a
#' TCX format variant it didn't handle well at the time).
#'
#' @param files Character vector of TCX file paths.
#' @param summaries Summaries data frame.
#' @param myruns List of trackeRdata objects.
#' @param verbose Logical.  Print progress messages.
#' @return Named list with \code{$summaries} (unchanged) and \code{$myruns}
#'   (repaired entries).
#' @export
repair_myruns_hr <- function(files, summaries, myruns, verbose = FALSE) {
  n_summaries <- nrow(summaries)
  file_basenames <- basename(files)

  # Find sessions with summary HR but no per-second HR
  has_source <- "source" %in% names(summaries)
  problem_indices <- which(vapply(seq_len(n_summaries), function(i) {
    # HAE rows have no on-disk TCX to re-parse; skip.
    if (has_source && isTRUE(summaries$source[i] == "hae")) return(FALSE)
    has_summary_hr <- !is.na(summaries$avgHeartRateMoving[[i]]) &&
                      as.numeric(summaries$avgHeartRateMoving[[i]]) > 0
    if (!has_summary_hr) return(FALSE)
    if (i > length(myruns) || is.null(myruns[[i]])) return(FALSE)
    df <- tryCatch(as.data.frame(myruns[[i]]), error = function(e) NULL)
    if (is.null(df) || !"heart_rate" %in% names(df)) return(TRUE)
    n_hr <- sum(!is.na(df$heart_rate) & df$heart_rate > 0)
    n_hr == 0
  }, logical(1)))

  n_problem <- length(problem_indices)
  if (n_problem == 0) {
    message("myruns HR: inga sessioner att reparera.")
    return(list(summaries = summaries, myruns = myruns))
  }

  message("myruns HR-reparation: ", n_problem,
          " sessioner med summary-HR men saknar per-sekund-HR ...")
  n_repaired <- 0L
  n_failed <- 0L
  n_no_file <- 0L

  for (idx in seq_along(problem_indices)) {
    i <- problem_indices[idx]

    if (idx %% 100 == 0 || idx == 1) {
      message("  ", idx, " / ", n_problem, " ...")
    }

    summary_file <- summaries$file[i]
    if (is.na(summary_file) || nchar(summary_file) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    match_idx <- which(file_basenames == basename(summary_file))
    if (length(match_idx) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    file_path <- files[match_idx[1]]

    new_data <- tryCatch(
      trackeR::read_container(file_path),
      error = function(e) NULL
    )

    if (is.null(new_data)) {
      n_failed <- n_failed + 1L
      next
    }

    # Verify the re-parsed data actually has HR
    new_df <- tryCatch(as.data.frame(new_data), error = function(e) NULL)
    if (!is.null(new_df) && "heart_rate" %in% names(new_df) &&
        sum(!is.na(new_df$heart_rate) & new_df$heart_rate > 0) > 0) {
      myruns[[i]] <- new_data
      n_repaired <- n_repaired + 1L
    } else {
      n_failed <- n_failed + 1L
    }
  }

  message("myruns HR-reparation klar: ", n_repaired, " reparerade, ",
          n_failed, " misslyckade, ", n_no_file, " utan matchande fil.")

  list(summaries = summaries, myruns = myruns)
}
