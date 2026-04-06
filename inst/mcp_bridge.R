#!/usr/bin/env Rscript

# Vayu MCP bridge — called by the Python MCP server.
# Takes a function name + JSON args, returns JSON to stdout.
#
# Usage:
#   Rscript inst/mcp_bridge.R --func=report_monthstatus --args='{"n":5}'
#   Rscript inst/mcp_bridge.R --func=fetch.plot.ef --args='{}' --plot

# --- Bootstrap ---
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) == 0) script_path <- "inst/mcp_bridge.R"
pkg_root <- normalizePath(file.path(dirname(script_path), ".."))
suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))

library(optparse)

options <- parse_args(OptionParser(option_list = list(
  make_option("--func", type = "character", default = NULL,
              help = "Function name to call"),
  make_option("--args", type = "character", default = "{}",
              help = "JSON-encoded arguments"),
  make_option("--plot", type = "logical", action = "store_true",
              default = FALSE, help = "Return plot as PNG")
)))

func_name <- options$func
func_args <- jsonlite::fromJSON(options$args, simplifyVector = FALSE)
do_plot   <- options$plot

# --- Output helpers ---
emit_json <- function(x) {
  cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null",
                       dataframe = "rows", Date = "ISO8601"),
      "\n", file = stdout())
}

emit_error <- function(msg) {
  emit_json(list(type = "error", message = msg))
  quit(status = 1, save = "no")
}

# --- Function whitelist ---
# Each entry maps to: list of required data sources
# s = summaries, m = myruns, h = health_daily, g = garmin augmentation,
# z = zone cache, d = decoupling cache
func_registry <- list(
  # Basic reports (summaries only)
  report_monthtop        = "s",
  report_runs_year_month = "s",
  report_monthlast       = "s",
  report_yearstop        = "s",
  report_yearstatus      = "s",
  report_monthstatus     = "s",
  report_datesum         = "s",
  report_ef              = "s",
  report_hre             = "s",
  report_acwr            = "s",
  report_monotony        = "s",
  report_pmc             = "s",
  # Garmin-augmented reports
  report_recovery_hr     = "sg",
  report_hr_zones        = "smgz",
  report_decoupling      = "smgd",
  # Health reports
  report_readiness       = "sh",
  # Basic plots (summaries only)
  plot_monthtop          = "s",
  plot_runs_month        = "s",
  plot_monthstatus       = "s",
  plot_monthlast         = "s",
  plot_yearstatus        = "s",
  plot_yearstop          = "s",
  plot_datesum           = "s",
  # Advanced plots (summaries only)
  fetch.plot.ef          = "s",
  fetch.plot.hre         = "s",
  fetch.plot.acwr        = "s",
  fetch.plot.monotony    = "s",
  fetch.plot.pmc         = "s",
  # Garmin-augmented plots
  fetch.plot.recovery_hr = "sg",
  fetch.plot.hr_zones    = "sgz",
  fetch.plot.decoupling  = "smgd",
  # Health plots
  fetch.plot.resting_hr  = "sh",
  fetch.plot.hrv         = "h",
  fetch.plot.sleep       = "h",
  fetch.plot.vo2max      = "h",
  fetch.plot.readiness_score = "sh"
)

if (is.null(func_name) || !func_name %in% names(func_registry)) {
  emit_error(paste0("Unknown or missing function: ", func_name))
}

# --- Data paths ---
traning_data <- Sys.getenv("TRANING_DATA")
if (traning_data == "") {
  emit_error("TRANING_DATA is not set")
}
db_summaries <- file.path(traning_data, "cache", "summaries.RData")
db_myruns    <- file.path(traning_data, "cache", "myruns.RData")
gc_json_dir  <- file.path(traning_data, "kristian", "filer", "gconnect")

# --- Conditional data loading ---
deps <- func_registry[[func_name]]
needs <- function(ch) grepl(ch, deps, fixed = TRUE)

summaries <- NULL
myruns <- NULL
health_daily <- NULL
zone_data <- NULL
decoupling_data <- NULL

if (needs("s") || needs("m")) {
  my_templist <- my_dbs_load(db_summaries, db_myruns)
  summaries <- my_templist[["summaries"]]
  if (needs("m")) myruns <- my_templist[["myruns"]]
  rm(my_templist)
}

if (needs("g") && dir.exists(gc_json_dir)) {
  garmin_data <- load_garmin_json(gc_json_dir)
  summaries <- augment_summaries(summaries, garmin_data)
  rm(garmin_data)
}

if (needs("h")) {
  health_daily <- load_health_data()
}

if (needs("z")) {
  zone_data <- load_zone_distribution(summaries, myruns)
}

if (needs("d")) {
  decoupling_data <- load_decoupling(summaries, myruns)
}

# --- Build function arguments ---
# Map JSON args to R function arguments.  Common patterns:
#   n, from, to — date range / limit
#   Other args vary by function.
build_call_args <- function(func_name, func_args) {
  a <- list()

  # Standard args present on most functions
  if (!is.null(func_args$n))      a$n      <- as.integer(func_args$n)
  if (!is.null(func_args$from))   a$from   <- as.Date(func_args$from)
  if (!is.null(func_args$to))     a$to     <- as.Date(func_args$to)
  if (!is.null(func_args$hr_max)) a$hr_max <- as.numeric(func_args$hr_max)
  if (!is.null(func_args$hr_rest)) a$hr_rest <- as.numeric(func_args$hr_rest)

  # Inject required data objects
  d <- func_registry[[func_name]]

  # Functions that take summaries as first arg
  summaries_funcs <- c(
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_ef", "report_hre", "report_acwr", "report_monotony",
    "report_pmc", "report_recovery_hr",
    "plot_monthtop", "plot_runs_month", "plot_monthstatus",
    "plot_monthlast", "plot_yearstatus", "plot_yearstop",
    "fetch.plot.ef", "fetch.plot.hre", "fetch.plot.acwr",
    "fetch.plot.monotony", "fetch.plot.pmc", "fetch.plot.recovery_hr"
  )
  if (func_name %in% summaries_funcs) {
    a <- c(list(summaries = summaries), a)
  }

  # report_datesum / plot_datesum: special positional args
  if (func_name %in% c("report_datesum", "plot_datesum")) {
    dr_from <- if (!is.null(func_args$from)) as.Date(func_args$from) else as.Date("1970-01-01")
    dr_to   <- if (!is.null(func_args$to))   as.Date(func_args$to)   else Sys.Date() + 1
    a <- list(summaries = summaries,
              do_datesum_from = dr_from,
              do_datesum_to = dr_to)
  }

  # Functions with zone_data
  if (func_name == "report_hr_zones") {
    a <- c(list(summaries = summaries), a, list(zone_data = zone_data))
  }
  if (func_name == "fetch.plot.hr_zones") {
    a <- c(list(summaries = summaries), a, list(zone_data = zone_data))
  }

  # Decoupling functions
  if (func_name == "report_decoupling") {
    a <- c(a, list(decoupling_data = decoupling_data))
  }
  if (func_name == "fetch.plot.decoupling") {
    a <- c(list(summaries = summaries, myruns = myruns), a,
           list(decoupling_data = decoupling_data))
  }

  # Health functions
  if (func_name == "report_readiness") {
    a <- c(list(health_daily = health_daily, summaries = summaries), a)
  }
  if (func_name == "fetch.plot.readiness_score") {
    a <- c(list(health_daily = health_daily, summaries = summaries), a)
  }
  if (func_name == "fetch.plot.resting_hr") {
    a <- c(list(health_daily = health_daily, summaries = summaries), a)
  }
  if (func_name %in% c("fetch.plot.hrv", "fetch.plot.sleep", "fetch.plot.vo2max")) {
    a <- c(list(health_daily = health_daily), a)
  }

  a
}

call_args <- build_call_args(func_name, func_args)

# --- Execute ---
tryCatch({
  result <- do.call(func_name, call_args)

  if (do_plot || inherits(result, "gg") || inherits(result, "patchwork")) {
    # Save plot to temp PNG
    tmp <- tempfile(pattern = "vayu_", fileext = ".png")
    ggplot2::ggsave(tmp, plot = result, width = 10, height = 6,
                    dpi = 150, bg = "white")
    emit_json(list(type = "plot", path = tmp))
  } else if (is.data.frame(result)) {
    emit_json(list(
      type = "data",
      rows = nrow(result),
      data = result
    ))
  } else {
    emit_json(list(type = "data", data = result))
  }
}, error = function(e) {
  emit_error(paste0("R error in ", func_name, ": ", conditionMessage(e)))
})
