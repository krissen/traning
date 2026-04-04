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
  make_option("--acwr",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Acute:Chronic Workload Ratio (last 365 days)"),
  make_option("--monotony",
    type = "logical", action = "store_true", default = FALSE,
    help = "Plot Training Monotony and Strain (last 365 days)")
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
do_acwr         <- options$acwr
do_monotony     <- options$monotony

# Parse date range
if (!is.null(options$datesum)) {
  dates <- strsplit(options$datesum, "--")[[1]]
  do_datesum_from <- as.Date(dates[1])
  if (length(dates) == 2) {
    do_datesum_to <- as.Date(dates[2]) + 1
  } else {
    do_datesum_to <- Sys.Date()
  }
} else {
  do_datesum_from <- NULL
  do_datesum_to <- NULL
}

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

# --- Reports ---
if (do_month_top) {
  print(report_monthtop(summaries))
}

if (do_month_running) {
  print(report_monthstatus(summaries))
}

if (do_month_this) {
  my_month_word <- format(Sys.time(), "%b")
  my_month <- format(Sys.time(), "%m")
  my_year <- format(Sys.time(), "%Y")
  month_summaries_this <- report_runs_year_month(summaries)
  my_month_km <- round(sum(month_summaries_this$Km), digits = 2)
  my_month_pace <- round(mean(month_summaries_this$Pace), digits = 2)
  my_month_runs <- nrow(month_summaries_this)
  print(month_summaries_this)
  print(paste("Totalt ", my_month_runs, " springturer ",
              "under ", my_month_word, " ", my_year, "; ",
              my_month_km, " km, ", my_month_pace,
              " min/km.", sep = ""))
}

if (do_month_last) {
  print(report_monthlast(summaries))
}

if (do_year_running) {
  print(report_yearstatus(summaries))
}

if (do_year_top) {
  print(report_yearstop(summaries))
}

if (!is.null(do_datesum_from) && !is.null(do_datesum_to)) {
  print(report_datesum(summaries, do_datesum_from, do_datesum_to))
}

if (do_total_pace) {
  print(fetch.my.mean.pace(summaries))
}

if (do_ef) {
  print(fetch.plot.ef(summaries))
}

if (do_acwr) {
  print(fetch.plot.acwr(summaries))
}

if (do_monotony) {
  print(fetch.plot.monotony(summaries))
}

# vim: ts=2 sw=2 et
