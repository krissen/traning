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

# .load_traning(): load the `traning` package for this bridge invocation.
#
# Production default is `library(traning)` against the INSTALLED package —
# ~0.45s faster per call than devtools::load_all() (measured: ~0.47s vs
# ~0.92s), which matters because the bridge is spawned fresh per MCP tool
# call. The tradeoff is that library() serves whatever was installed at the
# last `deploy.sh code` run, not the live checkout — see the deploy.sh
# change in this same PR, which now runs `R CMD INSTALL` on every code
# deploy so the installed package can't go stale.
#
# Two escape hatches:
#   - TRANING_BRIDGE_LOADER=load_all forces devtools::load_all(pkg_root) —
#     used by tests/testthat/test-mcp-bridge.R so the bridge always
#     exercises the current branch's source, not a possibly-stale install.
#   - If library(traning) fails outright (package never installed on this
#     box), fall back to load_all so the bridge still works out of a bare
#     checkout; a warning is written to stderr so the fallback is visible
#     without corrupting the stdout JSON channel.
#
# All diagnostic output from this function goes to stderr via message() —
# stdout is reserved for the single JSON response emitted at the end of
# this script.
.load_traning <- function(pkg_root) {
  use_load_all <- identical(Sys.getenv("TRANING_BRIDGE_LOADER"), "load_all")

  if (use_load_all) {
    suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))
    message("mcp_bridge: loaded traning via load_all (TRANING_BRIDGE_LOADER=load_all)")
    return(invisible("load_all"))
  }

  loaded <- tryCatch({
    suppressMessages(library(traning, character.only = FALSE))
    TRUE
  }, error = function(e) FALSE)

  if (loaded) {
    message(sprintf(
      "mcp_bridge: loaded traning via library() (version %s)",
      as.character(utils::packageVersion("traning"))
    ))
    return(invisible("library"))
  }

  message("mcp_bridge: library(traning) failed (package not installed?); falling back to load_all")
  suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))
  invisible("load_all_fallback")
}

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
  # ACWR / PMC need health_daily so the multi-sport (TRIMP-mode) paths
  # can fold in background-activity TRIMP from steps/walking distance.
  report_acwr            = "sh",
  report_monotony        = "s",
  report_pmc             = "sh",
  # Garmin-augmented reports
  report_recovery_hr     = "sg",
  report_hr_zones        = "smgz",
  report_decoupling      = "smgd",
  # Health reports
  report_readiness       = "sh",
  report_metric          = "h",
  health_insight_readiness = "sh",
  health_insight_update    = "sh",
  recent_data_dump         = "sh",
  latest_known_metrics     = "h",
  # Basic plots (summaries only)
  plot_monthtop          = "s",
  plot_runs_month        = "s",
  plot_monthstatus       = "s",
  plot_monthlast         = "s",
  plot_yearstop          = "s",
  plot_datesum           = "s",
  # Löpprofil — yearly characterization plots
  fetch.plot.pace_year          = "s",
  fetch.plot.pace_year_ridges   = "s",
  fetch.plot.pace_tertile_share = "s",
  fetch.plot.longest_runs_year  = "s",
  fetch.plot.season_pace        = "s",
  fetch.plot.heatmap_km         = "s",
  fetch.plot.cumulative_km      = "s",
  fetch.plot.distance_pace_era  = "s",
  # Advanced plots (summaries only)
  fetch.plot.ef          = "s",
  fetch.plot.hre         = "s",
  # ACWR / PMC plots need health_daily so multi-sport (TRIMP-mode)
  # paths render background-activity TRIMP in the volume panel.
  fetch.plot.acwr        = "sh",
  fetch.plot.monotony    = "s",
  fetch.plot.pmc         = "sh",
  # Garmin-augmented plots
  fetch.plot.recovery_hr = "sg",
  fetch.plot.hr_zones    = "sgz",
  fetch.plot.decoupling  = "smgd",
  # Health plots
  fetch.plot.resting_hr  = "sh",
  fetch.plot.hrv         = "h",
  fetch.plot.sleep       = "h",
  fetch.plot.vo2max      = "shg",
  fetch.plot.readiness_score = "sh",
  # Multi-sport plots
  plot_sport_mix         = "s",
  plot_sport_ctl_overlay = "s",
  plot_sport_calendar    = "s",
  # Phase 5d — race
  compute_taper_plan       = "s",
  compute_race_readiness   = "sh"
)

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
# Map JSON args to R function arguments.  Common patterns:
#   n, from, to — date range / limit
#   Other args vary by function.
build_call_args <- function(func_name, func_args) {
  a <- list()

  # Functions that accept 'n' parameter (report functions, not plot functions)
  n_funcs <- c(
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_ef", "report_hre", "report_acwr", "report_monotony",
    "report_pmc", "report_recovery_hr", "report_hr_zones",
    "report_decoupling", "report_readiness", "report_metric"
  )

  # Functions that accept a 'sport' parameter (for sport-agnostic
  # filtering — running, cycling, walking, ...). Plot wrappers inherit
  # via their underlying report_* / compute_* call.
  sport_funcs <- c(
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_datesum", "report_ef", "report_hre", "report_acwr",
    "report_monotony", "report_pmc", "report_recovery_hr",
    "report_hr_zones", "report_decoupling",
    "plot_monthtop", "plot_runs_month", "plot_monthstatus",
    "plot_monthlast", "plot_yearstop", "plot_datesum",
    "fetch.plot.ef", "fetch.plot.hre", "fetch.plot.acwr",
    "fetch.plot.monotony", "fetch.plot.pmc", "fetch.plot.recovery_hr",
    "fetch.plot.hr_zones", "fetch.plot.decoupling",
    # Löpprofil
    "fetch.plot.pace_year", "fetch.plot.pace_year_ridges",
    "fetch.plot.pace_tertile_share", "fetch.plot.longest_runs_year",
    "fetch.plot.season_pace", "fetch.plot.heatmap_km",
    "fetch.plot.cumulative_km", "fetch.plot.distance_pace_era",
    # Multi-sport plots that accept `sport=` as a population filter
    # (default NULL = all sports). plot_sport_ctl_overlay is omitted
    # because it takes a `sports` vector instead of a single bucket;
    # see the multi-sport extras block below.
    "plot_sport_mix", "plot_sport_calendar"
  )

  if (!is.null(func_args$n) && func_name %in% n_funcs)
    a$n <- as.integer(func_args$n)
  # Date args can arrive as ISO strings (YYYY, YYYY-MM, YYYY-MM-DD) or
  # relative expressions like "-2w" / "-1y" — Python's _build_args
  # passes them through verbatim, except for absolute ISO `before`
  # values where +1 day is already added so the user-facing
  # "inclusive" boundary becomes our exclusive `to`. parse_date_expr()
  # handles both forms; for relative `to` we apply the same +1 day
  # shift here so a "-2w" boundary day still gets included.
  .is_relative_date <- function(x) {
    is.character(x) && length(x) == 1 && grepl("^-\\d+[dwmy]$", x)
  }
  if (!is.null(func_args$from))    a$from   <- parse_date_expr(func_args$from)
  if (!is.null(func_args$to)) {
    a$to <- parse_date_expr(func_args$to)
    if (.is_relative_date(func_args$to)) a$to <- a$to + 1L
  }
  if (!is.null(func_args$hr_max))  a$hr_max <- as.numeric(func_args$hr_max)
  if (!is.null(func_args$hr_rest)) a$hr_rest <- as.numeric(func_args$hr_rest)
  if (!is.null(func_args$metric))  a$metric <- func_args$metric
  if (!is.null(func_args$sport) && func_name %in% sport_funcs)
    a$sport <- as.character(func_args$sport)
  if (!is.null(func_args$recent) && func_name == "report_runs_year_month")
    a$recent <- isTRUE(func_args$recent)

  # Every func_registry function takes a single `data =` traning_data
  # bundle (see the "Build the traning_data bundle" block above). `a` is
  # built here from JSON args only; `bundle` is injected once,
  # generically, at the end of this function (see below) — everything
  # from here down is purely per-function SCALAR argument extraction.

  # Phase 5d: race tools.
  if (func_name == "compute_taper_plan") {
    if (!is.null(func_args$race_date))
      a$race_date <- as.Date(func_args$race_date)
    if (!is.null(func_args$distance_km))
      a$distance_km <- as.numeric(func_args$distance_km)
    if (!is.null(func_args$taper_weeks))
      a$taper_weeks <- as.integer(func_args$taper_weeks)
  }
  if (func_name == "compute_race_readiness") {
    if (!is.null(func_args$target_date))
      a$target_date <- as.Date(func_args$target_date)
    if (!is.null(func_args$taper_weeks))
      a$taper_weeks <- as.integer(func_args$taper_weeks)
  }

  # Multi-sport plot extras
  if (func_name == "plot_sport_mix") {
    if (!is.null(func_args$period)) a$period <- as.character(func_args$period)
    if (!is.null(func_args$min_value)) {
      a$min_value <- as.numeric(func_args$min_value)
    } else if (!is.null(func_args$min_km)) {
      # Backward-compat: pre-2026-05 MCP clients sent `min_km`. Map it
      # to the renamed `min_value` so they keep working until they
      # upgrade. `min_value` (when both are sent) wins.
      a$min_value <- as.numeric(func_args$min_km)
    }
    # `metric` is already injected above (it's a generic forwarded arg);
    # plot_sport_mix accepts "distance" / "duration" / "trimp".
  }
  if (func_name == "plot_sport_ctl_overlay") {
    if (!is.null(func_args$sports)) {
      # JSON arrays arrive as a list under simplifyVector = FALSE, so
      # as.character() on the list itself would error. Coerce each
      # element to a scalar string explicitly.
      a$sports <- vapply(func_args$sports,
                          function(x) as.character(x)[[1]],
                          character(1))
    }
  }

  # report_datesum / plot_datesum: special positional args
  if (func_name %in% c("report_datesum", "plot_datesum")) {
    dr_from <- if (!is.null(func_args$from)) parse_date_expr(func_args$from)
               else as.Date("1970-01-01")
    dr_to   <- if (!is.null(func_args$to))   parse_date_expr(func_args$to)
               else Sys.Date() + 1
    # report_datesum/plot_datesum take do_datesum_from/do_datesum_to, not
    # the generic from/to that the date handler above stashed into `a` —
    # drop those so they don't reach the (from/to-less) function formals.
    a$from <- NULL
    a$to   <- NULL
    a <- c(list(do_datesum_from = dr_from, do_datesum_to = dr_to), a)
    if (!is.null(func_args$sport)) {
      a$sport <- as.character(func_args$sport)
    }
  }

  if (func_name == "recent_data_dump" && !is.null(func_args$hours)) {
    a$hours <- as.numeric(func_args$hours)
  }
  if (func_name == "health_insight_readiness" && !is.null(func_args$on_date)) {
    a$on_date <- as.Date(func_args$on_date)
  }
  if (func_name == "health_insight_update") {
    if (!is.null(func_args$prev_state)) {
      a$prev_state <- func_args$prev_state
    }
    if (!is.null(func_args$on_date)) {
      a$on_date <- as.Date(func_args$on_date)
    }
  }

  # Every func_registry function takes `data` as its first formal —
  # inject the single bundle built above (per the dep-driven loading at
  # the top of this script) generically, for every call.
  c(list(data = bundle), a)
}

call_args <- build_call_args(func_name, func_args)

# --- Execute ---
tryCatch({
  result <- do.call(func_name, call_args)

  if (do_plot || inherits(result, "gg") || inherits(result, "patchwork")) {
    # Prefer the path Python passed in (--plot_path) so the PNG survives
    # this subprocess's exit. tempfile() lives under R's per-process
    # tempdir, which gets removed on quit() before Python can read it.
    out_path <- if (!is.null(plot_path) && nzchar(plot_path)) {
      plot_path
    } else {
      tempfile(pattern = "vayu_", fileext = ".png")
    }
    dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
    ggplot2::ggsave(out_path, plot = result, width = 10, height = 6,
                    dpi = 150, bg = "white")
    emit_json(list(type = "plot", path = out_path))
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
