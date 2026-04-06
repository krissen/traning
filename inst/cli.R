#!/usr/bin/env Rscript

# Thin CLI wrapper for the traning package.
# Usage: Rscript inst/cli.R --month-running

# Find package root from script location
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) == 0) script_path <- "inst/cli.R"
pkg_root <- normalizePath(file.path(dirname(script_path), ".."))
suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))

library(optparse)

# --- Argument parsing ---
my_options <- list(
  make_option(c("-g", "--graphs"),
    type = "logical", action = "store_true", default = FALSE,
    help = "Print graphs (default %default)"),
  make_option(c("-v", "--verbose"),
    type = "logical", action = "store_true", default = FALSE,
    help = "Verbose output"),
  make_option(c("-n", "--no_means"),
    type = "logical", action = "store_false", default = TRUE,
    help = "Print table of means (default TRUE)"),
  make_option("--import",
    type = "logical", action = "store_true", default = FALSE,
    help = "Import new workouts (and save)"),
  make_option("--repair",
    type = "logical", action = "store_true", default = FALSE,
    help = "Repair myruns entries with NULL data (re-parse TCX files)"),
  make_option("--repair-hr",
    type = "logical", action = "store_true", default = FALSE,
    help = "Repair myruns entries with missing per-second HR (re-parse TCX)"),
  make_option("--total-pace",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of pace (all-time)"),
  make_option("--month-top",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of top 10 months"),
  make_option("--month-this",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of runs this month"),
  make_option("--month-last",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of last month over the years"),
  make_option("--month-running",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of current running month"),
  make_option("--year-top",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of top year"),
  make_option("--year-running",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print summarization of current running year"),
  make_option(c("--datesum"),
    type = "character", default = NULL,
    help = "Date summary in format 'YYYY-MM-DD--YYYY-MM-DD'"),
  make_option("--ef",
    type = "logical", action = "store_true", default = FALSE,
    help = "Efficiency Factor trend over time"),
  make_option("--hre",
    type = "logical", action = "store_true", default = FALSE,
    help = "Heart Rate Efficiency (beats/km, Votyakov)"),
  make_option("--acwr",
    type = "logical", action = "store_true", default = FALSE,
    help = "Acute:Chronic Workload Ratio (last 365 days)"),
  make_option("--monotony",
    type = "logical", action = "store_true", default = FALSE,
    help = "Training Monotony and Strain (last 365 days)"),
  make_option("--pmc",
    type = "logical", action = "store_true", default = FALSE,
    help = "Performance Management Chart (TRIMP/CTL/ATL/TSB)"),
  make_option("--recovery-hr",
    type = "logical", action = "store_true", default = FALSE,
    help = "Recovery Heart Rate trend (requires Garmin JSON import)"),
  make_option("--decoupling",
    type = "logical", action = "store_true", default = FALSE,
    help = "Aerobic decoupling trend (pace:HR drift, requires per-second data)"),
  make_option("--hr-zones",
    type = "logical", action = "store_true", default = FALSE,
    help = "HR zone distribution and Polarization Index (Seiler 3-zone)"),
  make_option("--readiness",
    type = "logical", action = "store_true", default = FALSE,
    help = "Daily readiness score (Apple Watch + Garmin fusion)"),
  make_option("--import-health",
    type = "logical", action = "store_true", default = FALSE,
    help = "Import Apple Watch health data from Health Auto Export JSON"),
  make_option("--force",
    type = "logical", action = "store_true", default = FALSE,
    help = "Force re-import of all files (bypass manifest)"),
  # --- Date range flags ---
  make_option("--after",
    type = "character", default = NULL,
    help = "Start of date range (inclusive). Formats: YYYY, YYYY-MM, YYYY-MM-DD, -Nw/-Nm/-Ny/-Nd"),
  make_option("--before",
    type = "character", default = NULL,
    help = "End of date range (exclusive). Same formats as --after"),
  make_option("--span",
    type = "character", default = NULL,
    help = "Duration from --after point (e.g. 3m, 1y). Requires --after, incompatible with --before"),
  # --- Output mode ---
  make_option("--plot",
    type = "logical", action = "store_true", default = FALSE,
    help = "Show plot instead of table"),
  make_option("--output",
    type = "character", default = NULL,
    help = "Save output to file (plot or table). Format from extension or --format"),
  make_option("--format",
    type = "character", default = NULL,
    help = "Output format. Plots: pdf, png. Tables: csv, json, jsonl, xlsx"),
  make_option("--no-open",
    type = "logical", action = "store_true", default = FALSE,
    help = "Don't open output file after saving (default: open)"),
  make_option("--limit",
    type = "integer", default = NULL,
    help = "Limit table rows (default varies per command)")
)

opt_parser <- OptionParser(option_list = my_options)
options <- parse_args(opt_parser)

do_import       <- options$import
do_repair       <- options$repair
do_verbose      <- options$verbose
do_month_top    <- options$`month-top`
do_month_last   <- options$`month-last`
do_month_this   <- options$`month-this`
do_month_running <- options$`month-running`
do_year_running <- options$`year-running`
do_year_top     <- options$`year-top`
do_total_pace   <- options$`total-pace`
do_ef           <- options$ef
do_hre          <- options$hre
do_acwr         <- options$acwr
do_monotony     <- options$monotony
do_pmc          <- options$pmc
do_recovery_hr  <- options$`recovery-hr`
do_decoupling   <- options$decoupling
do_hr_zones     <- options$`hr-zones`
do_readiness    <- options$readiness
do_import_health <- options$`import-health`
do_force        <- options$force
do_plot         <- options$plot
do_output       <- options$output
do_format       <- options$format
do_no_open      <- options$`no-open`
do_limit        <- options$limit

# --- Build date range ---
# Handle legacy --datesum format as syntactic sugar for --after/--before
if (!is.null(options$datesum)) {
  dates <- strsplit(options$datesum, "--")[[1]]
  if (is.null(options$after)) options$after <- dates[1]
  if (length(dates) == 2 && is.null(options$before)) {
    # Legacy format used exclusive end +1 day; new format is already exclusive
    options$before <- as.character(as.Date(dates[2]) + 1)
  }
}

date_range <- build_date_range(
  after  = options$after,
  before = options$before,
  span   = options$span
)

# Determine if --datesum was triggered (via legacy format or --after/--before)
do_datesum <- !is.null(options$datesum) ||
  (!is.null(options$after) || !is.null(options$before) || !is.null(options$span))

# --- Data paths ---
traning_data <- Sys.getenv("TRANING_DATA")
if (traning_data == "") {
  stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
}
db_summaries <- file.path(traning_data, "cache", "summaries.RData")
db_myruns    <- file.path(traning_data, "cache", "myruns.RData")
mytcxpath    <- file.path(traning_data, "kristian", "filer", "tcx")
gc_json_dir  <- file.path(traning_data, "kristian", "filer", "gconnect")

# --- Load data ---
my_templist <- my_dbs_load(db_summaries, db_myruns)
summaries <- my_templist[["summaries"]]
myruns <- my_templist[["myruns"]]
rm(my_templist)

# --- Import ---
if (do_import) {
  files <- get_my_files(mytcxpath)
  summaries_oldlength <- dplyr::count(summaries)
  my_templist <- get_new_workouts(files, summaries, myruns, verbose = do_verbose,
                                  db_summaries = db_summaries, db_myruns = db_myruns)
  summaries <- my_templist[["summaries"]]
  myruns <- my_templist[["myruns"]]
  rm(my_templist)
  summaries_newlength <- dplyr::count(summaries)
  summaries_lengthdiff <- as.numeric(summaries_newlength - summaries_oldlength)

  if (summaries_oldlength != summaries_newlength) {
    my_dbs_save(db_summaries, db_myruns, summaries, myruns)
    summaries_mostrecent <- utils::tail(summaries, n = summaries_lengthdiff)
    report_mostrecent(summaries_mostrecent, summaries_lengthdiff)
  }
}

# --- Repair myruns ---
if (do_repair) {
  files <- get_my_files(mytcxpath)
  my_templist <- repair_myruns(files, summaries, myruns, verbose = do_verbose)
  myruns <- my_templist[["myruns"]]
  rm(my_templist)
  my_dbs_save(db_summaries, db_myruns, summaries, myruns)
}

do_repair_hr <- options$`repair-hr`
if (do_repair_hr) {
  files <- get_my_files(mytcxpath)
  my_templist <- repair_myruns_hr(files, summaries, myruns, verbose = do_verbose)
  myruns <- my_templist[["myruns"]]
  rm(my_templist)
  my_dbs_save(db_summaries, db_myruns, summaries, myruns)
}

# --- Augment with Garmin JSON data (if needed) ---
needs_garmin <- do_recovery_hr || do_decoupling || do_hr_zones
if (needs_garmin && dir.exists(gc_json_dir)) {
  garmin_data <- load_garmin_json(gc_json_dir)
  summaries <- augment_summaries(summaries, garmin_data)
}

has_daterange <- !is.null(date_range$from) || !is.null(date_range$to)

# --- Helpers: emit plot or table ---
do_open <- if (do_no_open) FALSE else NULL  # NULL = use env default

emit_plot <- function(p, default_name = "plot") {
  save_plot(p, output = do_output, default_name = default_name,
            format = do_format, open = do_open)
}

emit_table <- function(tbl, default_name = "table") {
  if (!is.null(do_output) || !is.null(do_format)) {
    save_table(tbl, output = do_output, default_name = default_name,
               format = do_format, open = do_open)
  } else {
    print(tbl)
  }
}

# --- Reports: basic commands ---
if (do_month_top) {
  if (do_plot) {
    emit_plot(plot_monthtop(summaries, from = date_range$from, to = date_range$to), "month-top")
  } else {
    emit_table(report_monthtop(summaries, n = do_limit %||% 10L, from = date_range$from, to = date_range$to), "month-top")
  }
}

if (do_month_running) {
  if (do_plot) {
    emit_plot(plot_monthstatus(summaries, from = date_range$from, to = date_range$to), "month-running")
  } else {
    emit_table(report_monthstatus(summaries, n = do_limit, from = date_range$from, to = date_range$to), "month-running")
  }
}

if (do_month_this) {
  if (do_plot) {
    emit_plot(plot_runs_month(summaries, from = date_range$from, to = date_range$to), "month-this")
  } else {
    month_summaries_this <- report_runs_year_month(summaries, n = do_limit, from = date_range$from, to = date_range$to)
    emit_table(month_summaries_this, "month-this")
    if (is.null(do_output) && is.null(do_format)) {
      my_month_km <- round(sum(month_summaries_this$Km), digits = 2)
      my_month_pace <- round(mean(month_summaries_this$Pace), digits = 2)
      cat(sprintf("Totalt %d springturer under %s %s; %s km, %s min/km.\n",
          nrow(month_summaries_this), format(Sys.time(), "%b"),
          format(Sys.time(), "%Y"), my_month_km, my_month_pace))
    }
  }
}

if (do_month_last) {
  if (do_plot) {
    emit_plot(plot_monthlast(summaries, from = date_range$from, to = date_range$to), "month-last")
  } else {
    emit_table(report_monthlast(summaries, n = do_limit, from = date_range$from, to = date_range$to), "month-last")
  }
}

if (do_year_running) {
  if (do_plot) {
    emit_plot(plot_yearstatus(summaries, from = date_range$from, to = date_range$to), "year-running")
  } else {
    emit_table(report_yearstatus(summaries, n = do_limit, from = date_range$from, to = date_range$to), "year-running")
  }
}

if (do_year_top) {
  if (do_plot) {
    emit_plot(plot_yearstop(summaries, from = date_range$from, to = date_range$to), "year-top")
  } else {
    emit_table(report_yearstop(summaries, n = do_limit, from = date_range$from, to = date_range$to), "year-top")
  }
}

# Date summary: triggered by --datesum OR standalone --after/--before/--span
# Only runs if no other report command was given (to avoid double output)
any_report <- do_month_top || do_month_running || do_month_this ||
  do_month_last || do_year_running || do_year_top || do_total_pace ||
  do_ef || do_hre || do_acwr || do_monotony || do_pmc || do_recovery_hr ||
  do_decoupling || do_readiness || do_hr_zones

if (!is.null(options$datesum) || (has_daterange && !any_report)) {
  dr_from <- date_range$from
  dr_to   <- date_range$to
  # Default boundaries when only one end is specified
  if (is.null(dr_from)) dr_from <- as.Date("1970-01-01")
  if (is.null(dr_to))   dr_to   <- Sys.Date() + 1

  if (do_plot) {
    emit_plot(plot_datesum(summaries, dr_from, dr_to), "datesum")
  } else {
    emit_table(report_datesum(summaries, dr_from, dr_to), "datesum")
  }
}

if (do_total_pace) {
  pace_data <- if (has_daterange) filter_by_daterange(summaries, date_range) else summaries
  if (do_plot) {
    emit_plot(fetch.plot.mean.pace(fetch.my.mean.pace(pace_data)), "total-pace")
  } else {
    emit_table(fetch.my.mean.pace(pace_data), "total-pace")
  }
}

# --- Reports: time-series metrics (use FULL data, filter output) ---
# These commands always receive unfiltered summaries so that rolling-window
# computations (28-day means, EWMA, etc.) have complete history.
# The date range is applied to the computed output for display.

if (do_ef) {
  if (do_plot) {
    emit_plot(fetch.plot.ef(summaries, from = date_range$from, to = date_range$to), "ef")
  } else {
    emit_table(report_ef(summaries, n = do_limit %||% 28L,
                    from = date_range$from, to = date_range$to), "ef")
  }
}

if (do_hre) {
  if (do_plot) {
    emit_plot(fetch.plot.hre(summaries, from = date_range$from, to = date_range$to), "hre")
  } else {
    emit_table(report_hre(summaries, n = do_limit %||% 28L,
                     from = date_range$from, to = date_range$to), "hre")
  }
}

if (do_acwr) {
  if (do_plot) {
    emit_plot(fetch.plot.acwr(summaries, from = date_range$from, to = date_range$to), "acwr")
  } else {
    emit_table(report_acwr(summaries, n = do_limit %||% 28L,
                      from = date_range$from, to = date_range$to), "acwr")
  }
}

if (do_monotony) {
  if (do_plot) {
    emit_plot(fetch.plot.monotony(summaries, from = date_range$from, to = date_range$to), "monotony")
  } else {
    emit_table(report_monotony(summaries, n = do_limit %||% 28L,
                          from = date_range$from, to = date_range$to), "monotony")
  }
}

if (do_pmc) {
  if (do_plot) {
    emit_plot(fetch.plot.pmc(summaries, from = date_range$from, to = date_range$to), "pmc")
  } else {
    emit_table(report_pmc(summaries, n = do_limit %||% 28L,
                     from = date_range$from, to = date_range$to), "pmc")
  }
}

# --- Health data import ---
if (do_import_health) {
  import_health_export(force = do_force, verbose = TRUE)
}

# --- Readiness (requires health data) ---
if (do_readiness) {
  health_daily <- load_health_data()
  if (nrow(health_daily) == 0) {
    cat("Ingen hälsodata hittades. Kör --import-health först.\n")
  } else {
    if (do_plot) {
      emit_plot(fetch.plot.readiness_score(health_daily, summaries,
                  from = date_range$from, to = date_range$to), "readiness")
    } else {
      emit_table(report_readiness(health_daily, summaries,
                    n = do_limit %||% 14L,
                    from = date_range$from, to = date_range$to), "readiness")
    }
  }
}

if (do_hr_zones) {
  # Per-second zone computation with caching (accurate VT1/VT2 thresholds)
  zone_data <- load_zone_distribution(summaries, myruns, force = do_force)
  if (do_plot) {
    emit_plot(fetch.plot.hr_zones(summaries,
                from = date_range$from, to = date_range$to,
                zone_data = zone_data), "hr-zones")
  } else {
    emit_table(report_hr_zones(summaries, n = do_limit %||% 12L,
                  from = date_range$from, to = date_range$to,
                  zone_data = zone_data), "hr-zones")
  }
}

if (do_recovery_hr) {
  if (do_plot) {
    emit_plot(fetch.plot.recovery_hr(summaries, from = date_range$from, to = date_range$to), "recovery-hr")
  } else {
    emit_table(report_recovery_hr(summaries, n = do_limit %||% 28L,
                             from = date_range$from, to = date_range$to), "recovery-hr")
  }
}

if (do_decoupling) {
  decoupling_data <- load_decoupling(summaries, myruns, force = do_force)
  if (do_plot) {
    emit_plot(fetch.plot.decoupling(summaries, myruns,
                from = date_range$from, to = date_range$to,
                decoupling_data = decoupling_data), "decoupling")
  } else {
    emit_table(report_decoupling(n = do_limit %||% 28L,
                  from = date_range$from, to = date_range$to,
                  decoupling_data = decoupling_data), "decoupling")
  }
}

# vim: ts=2 sw=2 et
