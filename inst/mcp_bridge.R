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

# .load_traning(), func_registry, build_call_args() and run_dispatch()
# are shared with the warm server (inst/mcp_bridge_server.R) — see
# mcp_bridge_shared.R's header comment. Pure definitions only; safe to
# source unconditionally.
source(file.path(pkg_root, "inst", "mcp_bridge_shared.R"), local = FALSE)

.load_traning(pkg_root)

library(optparse)

options <- parse_args(OptionParser(option_list = list(
  make_option("--func", type = "character", default = NULL,
              help = "Function name to call"),
  make_option("--args", type = "character", default = "{}",
              help = "JSON-encoded arguments"),
  make_option("--plot", type = "logical", action = "store_true",
              default = FALSE, help = "Return plot as PNG"),
  make_option("--plot_path", type = "character", default = NULL,
              help = paste("Target PNG path supplied by the caller.",
                           "Used so the file outlives this R subprocess;",
                           "without it, fall back to tempfile() and risk",
                           "the path being wiped on exit."))
)))

func_name <- options$func
func_args <- jsonlite::fromJSON(options$args, simplifyVector = FALSE)
do_plot   <- options$plot
plot_path <- options$plot_path

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
# func_registry is defined in mcp_bridge_shared.R (sourced above) — s =
# summaries, m = myruns, h = health_daily, g = garmin augmentation, z =
# zone cache, d = decoupling cache.
if (is.null(func_name) || !func_name %in% names(func_registry)) {
  emit_error(paste0("Unknown or missing function: ", func_name))
}

# S7 data-model migration (see R/traning_data.R, docs/dev migration plan):
# every func_registry entry now takes a single `data = <traning_data>`
# argument (the last legacy-signature holdouts were migrated in PR 6).
# PR 7 collapses the bridge's arg-marshalling accordingly: a single
# bundle is built per request (see the "Build the traning_data bundle"
# block below) and passed as `data =` to every dispatched function.
# cli.R is unaffected — it calls positionally, which `.as_traning_data()`
# already handles for any remaining legacy call sites there.

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

# Resolve sport early so cache loaders can scope by sport. Both
# load_zone_distribution() and load_decoupling() use sport as a cache
# key — without forwarding it here, zone/decoupling caches built for
# running would be silently reused for a cycling request.
sport_arg <- if (!is.null(func_args$sport)) {
  as.character(func_args$sport)
} else {
  "running"
}

if (needs("z")) {
  zone_data <- load_zone_distribution(summaries, myruns, sport = sport_arg)
}

if (needs("d")) {
  decoupling_data <- load_decoupling(summaries, myruns, sport = sport_arg)
}

# --- Build the traning_data bundle ---
# Every func_registry entry now takes a single `data =` traning_data
# bundle (PR 6 migrated the last legacy-signature holdouts). Build ONE
# bundle per request from whatever the dep-driven loading above
# populated; unloaded slots stay NULL/empty and are harmless for
# functions that don't use them (e.g. report_ef's "s"-only bundle
# carries myruns = list(), never touched by its body).
#
# When `summaries` wasn't loaded (pure "h"-dep functions like
# report_metric), traning_data()'s validator still requires a
# `sessionStart` column — not any rows — so an empty stub satisfies it
# without lying about there being session data.
#
# `traning_data(...)` is a direct call, not `do.call(traning_data, ...)`
# — this script also binds a top-level variable `traning_data` to the
# TRANING_DATA path string (see below). A direct call in function
# position resolves via R's function-position lookup, which skips the
# non-function `traning_data` string binding and finds the S7 class
# constructor. `do.call()` with the bare symbol would NOT skip it (it
# resolves the symbol to the string first) — do.call("traning_data", ...)
# with the string form would still work, but the direct call is simpler
# and is what's used here.
bundle <- traning_data(
  summaries = if (!is.null(summaries)) {
    summaries
  } else {
    tibble::tibble(sessionStart = as.POSIXct(character()))
  },
  myruns = if (!is.null(myruns)) myruns else list(),
  health_daily = health_daily,
  zone_data = zone_data,
  decoupling_data = decoupling_data,
  sport = if (!is.null(sport_arg) && nzchar(sport_arg)) sport_arg else "running",
  augmented = !is.null(summaries) && "garmin_matched" %in% names(summaries)
)

# --- Build function arguments ---
# build_call_args() and run_dispatch() are defined in
# mcp_bridge_shared.R (sourced above).
call_args <- build_call_args(func_name, func_args, bundle)

# --- Execute ---
resp <- run_dispatch(func_name, call_args, do_plot, plot_path)
if (identical(resp$type, "error")) {
  emit_error(resp$message)
} else {
  emit_json(resp)
}
