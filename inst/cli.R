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
    help = "Plot Efficiency Factor trend over time"),
  make_option("--hre",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Heart Rate Efficiency (beats/km, Votyakov)"),
  make_option("--acwr",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Acute:Chronic Workload Ratio (last 365 days)"),
  make_option("--monotony",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Training Monotony and Strain (last 365 days)"),
  make_option("--pmc",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Performance Management Chart (TRIMP/CTL/ATL/TSB)"),
  make_option("--recovery-hr",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Recovery Heart Rate trend (requires Garmin JSON import)"),
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
    help = "Show plot instead of table")
)

opt_parser <- OptionParser(option_list = my_options)
options <- parse_args(opt_parser)

do_import       <- options$import
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
do_plot         <- options$plot

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

# --- Load data ---
my_templist <- my_dbs_load(db_summaries, db_myruns)
summaries <- my_templist[["summaries"]]
myruns <- my_templist[["myruns"]]
rm(my_templist)

# --- Import ---
if (do_import) {
  files <- get_my_files(mytcxpath)
  summaries_oldlength <- dplyr::count(summaries)
  my_templist <- get_new_workouts(files, summaries, myruns, verbose = do_verbose)
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

# --- Pre-filter by date range ---
# Filtering happens upstream: report/plot functions receive already-filtered data.
# For commands with inherent date logic (month/year comparisons), the filter limits
# which years are included while preserving the function's internal comparison logic.
has_daterange <- !is.null(date_range$from) || !is.null(date_range$to)
summaries_filtered <- if (has_daterange) {
  filter_by_daterange(summaries, date_range)
} else {
  summaries
}

# --- Reports ---
if (do_month_top) {
  if (do_plot) {
    print(plot_monthtop(summaries_filtered))
  } else {
    print(report_monthtop(summaries_filtered))
  }
}

if (do_month_running) {
  if (do_plot) {
    print(plot_monthstatus(summaries_filtered))
  } else {
    print(report_monthstatus(summaries_filtered))
  }
}

if (do_month_this) {
  if (do_plot) {
    print(plot_runs_month(summaries_filtered))
  } else {
    my_month_word <- format(Sys.time(), "%b")
    my_month <- format(Sys.time(), "%m")
    my_year <- format(Sys.time(), "%Y")
    month_summaries_this <- report_runs_year_month(summaries_filtered)
    my_month_km <- round(sum(month_summaries_this$Km), digits = 2)
    my_month_pace <- round(mean(month_summaries_this$Pace), digits = 2)
    my_month_runs <- nrow(month_summaries_this)
    print(month_summaries_this)
    print(paste("Totalt ", my_month_runs, " springturer ",
                "under ", my_month_word, " ", my_year, "; ",
                my_month_km, " km, ", my_month_pace,
                " min/km.", sep = ""))
  }
}

if (do_month_last) {
  if (do_plot) {
    print(plot_monthlast(summaries_filtered))
  } else {
    print(report_monthlast(summaries_filtered))
  }
}

if (do_year_running) {
  if (do_plot) {
    print(plot_yearstatus(summaries_filtered))
  } else {
    print(report_yearstatus(summaries_filtered))
  }
}

if (do_year_top) {
  if (do_plot) {
    print(plot_yearstop(summaries_filtered))
  } else {
    print(report_yearstop(summaries_filtered))
  }
}

# Date summary: triggered by --datesum OR standalone --after/--before/--span
# Only runs if no other report command was given (to avoid double output)
any_report <- do_month_top || do_month_running || do_month_this ||
  do_month_last || do_year_running || do_year_top || do_total_pace ||
  do_ef || do_hre || do_acwr || do_monotony || do_pmc || do_recovery_hr

if (!is.null(options$datesum) || (has_daterange && !any_report)) {
  dr_from <- date_range$from
  dr_to   <- date_range$to
  # Default boundaries when only one end is specified
  if (is.null(dr_from)) dr_from <- as.Date("1970-01-01")
  if (is.null(dr_to))   dr_to   <- Sys.Date() + 1

  if (do_plot) {
    print(plot_datesum(summaries, dr_from, dr_to))
  } else {
    print(report_datesum(summaries, dr_from, dr_to))
  }
}

if (do_total_pace) {
  if (do_plot) {
    mean_pace_data <- fetch.my.mean.pace(summaries_filtered)
    print(fetch.plot.mean.pace(mean_pace_data))
  } else {
    print(fetch.my.mean.pace(summaries_filtered))
  }
}

if (do_ef) {
  print(fetch.plot.ef(summaries_filtered))
}

if (do_hre) {
  print(fetch.plot.hre(summaries_filtered))
}

if (do_acwr) {
  print(fetch.plot.acwr(summaries_filtered))
}

if (do_monotony) {
  print(fetch.plot.monotony(summaries_filtered))
}

if (do_pmc) {
  print(fetch.plot.pmc(summaries_filtered))
}

if (do_recovery_hr) {
  print(fetch.plot.recovery_hr(summaries_filtered))
}

# vim: ts=2 sw=2 et
