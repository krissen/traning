#!/usr/bin/env Rscript

# notify_helper.R — called by the FastAPI receiver after debouncing
# HAE health pushes. Imports new files, computes the appropriate insight
# (state-based readiness for the first flush of the day, update otherwise),
# and writes a JSON result to stdout for the Python caller to act on.
#
# Usage:
#   Rscript inst/notify_helper.R --files=a.json,b.json --prev-state=/tmp/state.json
#
# --prev-state may be empty / missing → first flush of the day.

# Bootstrap relative to this script's location
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) == 0) script_path <- "inst/notify_helper.R"
pkg_root <- normalizePath(file.path(dirname(script_path), ".."))
suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))

library(optparse)

opts <- parse_args(OptionParser(option_list = list(
  make_option("--files", type = "character", default = "",
              help = "Comma-separated paths of HAE JSON files to import"),
  make_option(c("--prev-state", "-p"), type = "character", default = "",
              dest = "prev_state",
              help = "Path to previous notify state JSON (empty = morning)")
)))

files <- if (nchar(opts$files) == 0) {
  character()
} else {
  strsplit(opts$files, ",", fixed = TRUE)[[1]]
}

prev_state <- NULL
if (nchar(opts$prev_state) > 0 && file.exists(opts$prev_state)) {
  prev_state <- tryCatch(
    jsonlite::fromJSON(opts$prev_state, simplifyVector = FALSE),
    error = function(e) NULL
  )
}

emit <- function(x) {
  cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null",
                       Date = "ISO8601"))
}

emit_error <- function(msg) {
  emit(list(kind = "error", error = msg, prosa = "",
            trigger = "", components_present = list()))
  quit(status = 1, save = "no")
}

result <- tryCatch({
  # Import files if provided. Failure here aborts.
  if (length(files) > 0) {
    invisible(import_health_export(path = files, verbose = FALSE))
  }

  td <- Sys.getenv("TRANING_DATA")
  tl <- my_dbs_load(file.path(td, "cache", "summaries.RData"),
                     file.path(td, "cache", "myruns.RData"))
  h <- load_health_data()

  is_morning <- is.null(prev_state) || !isTRUE(prev_state$morning_sent)

  if (is_morning) {
    res <- health_insight_readiness(h, tl[["summaries"]])
    res$kind <- "readiness"
    res
  } else {
    res <- health_insight_update(h, tl[["summaries"]], prev_state)
    res$kind <- "update"
    res
  }
}, error = function(e) {
  list(kind = "error", error = conditionMessage(e), prosa = "",
       trigger = "", components_present = list())
})

emit(result)
