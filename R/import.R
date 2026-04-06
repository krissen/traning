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
}

#' Save summaries and myruns to RData files
#' @param db_summaries Path to summaries.RData
#' @param db_myruns Path to myruns.RData
#' @param summaries Data frame of workout summaries
#' @param myruns List of trackeR run objects
#' @export
my_dbs_save <- function(db_summaries, db_myruns, summaries, myruns) {
  save(myruns, file = db_myruns)
  save(summaries, file = db_summaries)
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
get_new_workouts <- function(files, summaries, myruns, verbose = FALSE) {
  # Match on basename to handle relative vs absolute path mismatches
  existing_basenames <- basename(summaries$file[!is.na(summaries$file)])
  for (i in 1:length(files)) {
    thefile <- files[[i]]
    if (basename(thefile) %in% existing_basenames) {
      if (verbose) {
        cat("Redan inläst: ", basename(thefile), "\n", sep = "")
      }
    } else {
      if (verbose) {
        cat("Läser in ", basename(files[[i]]), " ... ", sep = "")
      }
      myruns[[i]] <- tryCatch({
        trackeR::read_container(files[[i]])
      }, error = function(e) {
        warning("Kunde inte läsa: ", basename(files[[i]]),
                " (", conditionMessage(e), ")", call. = FALSE)
        NULL
      })
      if (is.null(myruns[[i]])) next
      if (verbose) cat("OK\n")
      run_summary <- summary(myruns[[i]])
      run_summary <- add_my_columns(run_summary)
      summaries <- rbind(summaries, run_summary,
                         deparse.level = 0,
                         make.row.names = FALSE)
    }
  }
  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
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
