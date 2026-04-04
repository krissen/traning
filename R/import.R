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
