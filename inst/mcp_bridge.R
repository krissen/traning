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
# functions in this list have had their first formal renamed from
# `summaries` to `data` (still accepting a bare summaries data.frame via
# the `.as_traning_data()` shim — only the argument NAME changed, not
# what's accepted). do.call() dispatches by exact/partial name match, not
# position, so any such function must be called here with `data = ...`
# instead of `summaries = ...` or dispatch fails with "unused argument".
# cli.R is unaffected — it calls positionally, which the shim already
# handles.
#
# This vector grows by one migration PR's worth of names at a time (PR 3
# added the "s"-bucket names below) and is deleted entirely in PR 7,
# where the whole bridge's arg-marshalling is unified around `data`.
.migrated_to_data <- c(
  # PR 3 — "s" bucket (summaries-only reports/plots)
  "report_monthtop", "report_runs_year_month", "report_monthlast",
  "report_yearstop", "report_yearstatus", "report_monthstatus",
  "report_datesum", "report_ef", "report_hre", "report_monotony",
  "plot_monthtop", "plot_runs_month", "plot_monthstatus",
  "plot_monthlast", "plot_yearstop", "plot_datesum",
  "plot_sport_mix", "plot_sport_ctl_overlay", "plot_sport_calendar",
  "fetch.plot.pace_year", "fetch.plot.pace_year_ridges",
  "fetch.plot.pace_tertile_share", "fetch.plot.longest_runs_year",
  "fetch.plot.season_pace", "fetch.plot.heatmap_km",
  "fetch.plot.cumulative_km", "fetch.plot.distance_pace_era",
  "fetch.plot.ef", "fetch.plot.hre", "fetch.plot.monotony",
  # PR 4 — health group ("h"-dep functions: report_acwr/pmc/readiness/
  # metric, the health-insight + data-inspection helpers, and the
  # health plot wrappers). These take a `traning_data` bundle, not
  # separate summaries/health_daily args — see the "Health functions"
  # block in build_call_args() below.
  "report_acwr", "report_pmc", "report_readiness", "report_metric",
  "health_insight_readiness", "health_insight_update", "recent_data_dump",
  "latest_known_metrics",
  "fetch.plot.acwr", "fetch.plot.pmc", "fetch.plot.resting_hr",
  "fetch.plot.hrv", "fetch.plot.sleep", "fetch.plot.vo2max",
  "fetch.plot.readiness_score",
  # PR 5 — derived-cache / garmin group ("sg"/"smgz"/"sgz"/"smgd" buckets).
  # These take a `traning_data` bundle carrying Garmin-augmented
  # summaries and, for the zone/decoupling pair, the sport-keyed
  # zone_data/decoupling_data caches — see the "Derived-cache / garmin
  # functions" block in build_call_args() below.
  "report_recovery_hr", "report_hr_zones", "report_decoupling",
  "fetch.plot.recovery_hr", "fetch.plot.hr_zones", "fetch.plot.decoupling"
)

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

  # Inject required data objects
  d <- func_registry[[func_name]]

  # Functions that take summaries as first arg. report_acwr, report_pmc,
  # fetch.plot.acwr and fetch.plot.pmc are deliberately excluded here
  # even though they were previously summaries-first: they're
  # S7-migrated (PR 4) and need a full traning_data bundle (summaries +
  # health_daily), not a bare summaries data.frame — see the "PMC /
  # ACWR" block below, which injects their `data =` arg instead.
  summaries_funcs <- c(
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_ef", "report_hre", "report_monotony",
    "plot_monthtop", "plot_runs_month", "plot_monthstatus",
    "plot_monthlast", "plot_yearstop",
    "fetch.plot.ef", "fetch.plot.hre",
    "fetch.plot.monotony",
    "plot_sport_mix", "plot_sport_ctl_overlay", "plot_sport_calendar",
    "compute_taper_plan",
    # Löpprofil
    "fetch.plot.pace_year", "fetch.plot.pace_year_ridges",
    "fetch.plot.pace_tertile_share", "fetch.plot.longest_runs_year",
    "fetch.plot.season_pace", "fetch.plot.heatmap_km",
    "fetch.plot.cumulative_km", "fetch.plot.distance_pace_era"
  )
  if (func_name %in% summaries_funcs) {
    # Migrated functions' first formal is `data`, not `summaries` — see
    # .migrated_to_data above. do.call() matches by name, so the key
    # must track the target formal even though the value (the bare
    # summaries data.frame) is unchanged.
    summaries_arg <- if (func_name %in% .migrated_to_data) "data" else "summaries"
    a <- c(stats::setNames(list(summaries), summaries_arg), a)
  }

  # Phase 5d: race tools
  if (func_name == "compute_taper_plan") {
    if (!is.null(func_args$race_date))
      a$race_date <- as.Date(func_args$race_date)
    if (!is.null(func_args$distance_km))
      a$distance_km <- as.numeric(func_args$distance_km)
    if (!is.null(func_args$taper_weeks))
      a$taper_weeks <- as.integer(func_args$taper_weeks)
  }
  if (func_name == "compute_race_readiness") {
    a <- c(list(summaries = summaries, health_daily = health_daily), a)
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
    # Both are in .migrated_to_data (PR 3); see comment above.
    summaries_arg <- if (func_name %in% .migrated_to_data) "data" else "summaries"
    a <- c(stats::setNames(list(summaries), summaries_arg),
           list(do_datesum_from = dr_from, do_datesum_to = dr_to))
    if (!is.null(func_args$sport)) {
      a$sport <- as.character(func_args$sport)
    }
  }

  # Generic bundle builder — S7-migrated functions (PR 4 health group, PR 5
  # derived-cache/garmin group) each take a single `data =` traning_data
  # bundle instead of separate summaries/myruns/health_daily/zone_data/
  # decoupling_data args (see .migrated_to_data above). .bundle() folds
  # whatever this request already loaded (per func_registry's dep string)
  # into one bundle; when `summaries` wasn't loaded (pure "h"-dep
  # functions), it substitutes a minimal but valid empty summaries stub —
  # traning_data's validator only requires a `sessionStart` column, not
  # any rows.
  #
  # `sport_in` threads `sport_arg` (resolved above, before the zone_data/
  # decoupling_data cache loads) into the bundle's @sport so the
  # validator's sport-keying guard is satisfied whenever a zone_data/
  # decoupling_data cache is attached — those caches are only valid for
  # the sport they were computed for.
  .augmented_flag <- !is.null(summaries) && "garmin_matched" %in% names(summaries)
  .bundle <- function(myruns_in = NULL, zone_data_in = NULL,
                       decoupling_data_in = NULL, sport_in = NULL) {
    s <- if (!is.null(summaries)) {
      summaries
    } else {
      tibble::tibble(sessionStart = as.POSIXct(character()))
    }
    bundle_args <- list(summaries = s, health_daily = health_daily,
                        augmented = .augmented_flag)
    if (!is.null(myruns_in)) bundle_args$myruns <- myruns_in
    if (!is.null(zone_data_in)) bundle_args$zone_data <- zone_data_in
    if (!is.null(decoupling_data_in)) bundle_args$decoupling_data <- decoupling_data_in
    if (!is.null(sport_in)) bundle_args$sport <- sport_in
    # `do.call()`'s first argument must be the *function name string*
    # here, not the bare symbol `traning_data` — this script also binds
    # a top-level variable `traning_data` to the TRANING_DATA path
    # (see below), which would shadow the S7 class constructor if
    # evaluated as a symbol. `do.call("traning_data", ...)` resolves via
    # match.fun(mode = "function"), which skips the non-function
    # variable and finds the constructor.
    do.call("traning_data", bundle_args)
  }
  .health_bundle <- function() .bundle()

  # Derived-cache / garmin functions (PR 5). report_recovery_hr /
  # fetch.plot.recovery_hr only need Garmin-augmented summaries ("sg"),
  # but are bundled here too (rather than left as bare-summaries via
  # summaries_funcs) so @augmented and @sport are carried consistently
  # with the zone/decoupling pair.
  if (func_name %in% c("report_recovery_hr", "fetch.plot.recovery_hr")) {
    a <- c(list(data = .bundle(sport_in = sport_arg)), a)
  }
  if (func_name %in% c("report_hr_zones", "fetch.plot.hr_zones")) {
    a <- c(list(data = .bundle(myruns_in = myruns, zone_data_in = zone_data,
                               sport_in = sport_arg)), a)
  }
  if (func_name %in% c("report_decoupling", "fetch.plot.decoupling")) {
    a <- c(list(data = .bundle(myruns_in = myruns,
                               decoupling_data_in = decoupling_data,
                               sport_in = sport_arg)), a)
  }

  if (func_name %in% c("report_readiness", "fetch.plot.readiness_score",
                        "fetch.plot.resting_hr", "fetch.plot.vo2max",
                        "fetch.plot.hrv", "fetch.plot.sleep",
                        "report_metric")) {
    a <- c(list(data = .health_bundle()), a)
  }

  # New health-insight + data-dump functions
  if (func_name %in% c("health_insight_readiness", "recent_data_dump")) {
    a <- c(list(data = .health_bundle()), a)
    if (func_name == "recent_data_dump" && !is.null(func_args$hours)) {
      a$hours <- as.numeric(func_args$hours)
    }
    if (func_name == "health_insight_readiness" &&
        !is.null(func_args$on_date)) {
      a$on_date <- as.Date(func_args$on_date)
    }
  }
  if (func_name == "health_insight_update") {
    a <- c(list(data = .health_bundle()), a)
    if (!is.null(func_args$prev_state)) {
      a$prev_state <- func_args$prev_state
    }
    if (!is.null(func_args$on_date)) {
      a$on_date <- as.Date(func_args$on_date)
    }
  }
  if (func_name == "latest_known_metrics") {
    a <- c(list(data = .health_bundle()), a)
  }

  # PMC / ACWR — S7-migrated (PR 4): pass a bundle carrying
  # health_daily so the multi-sport (TRIMP-mode) paths can fold in
  # background-activity TRIMP; when sport is sport-specific the
  # downstream code ignores it, so passing here is safe regardless.
  # These two are deliberately excluded from summaries_funcs above, so
  # this is the only place their `data =` arg gets set.
  if (func_name %in% c("report_pmc", "report_acwr",
                        "fetch.plot.pmc", "fetch.plot.acwr")) {
    a <- c(list(data = .health_bundle()), a)
  }

  a
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
