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
  make_option("--dedup",
    type = "logical", action = "store_true", default = FALSE,
    help = paste0("List Apple Watch rows that duplicate a Garmin session. ",
                  "Reports only; add --apply to remove them")),
  make_option("--apply",
    type = "logical", action = "store_true", default = FALSE,
    help = paste0("With --dedup: actually remove the rows listed. ",
                  "Ignored when --dry-run is also given")),
  make_option("--dry-run",
    type = "logical", action = "store_true", default = FALSE,
    help = paste0("Report only. This is already the default; passing it ",
                  "alongside --apply keeps the run harmless")),
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
    help = "Acute:Chronic Workload Ratio (use --after to limit, default full history)"),
  make_option("--monotony",
    type = "logical", action = "store_true", default = FALSE,
    help = "Training Monotony and Strain (use --after to limit, default full history)"),
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
  make_option("--overview-cache",
    type = "logical", action = "store_true", default = FALSE,
    help = "Rebuild the Shiny overview-page precache (PMC/ACWR/readiness)"),
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
    help = "Limit table rows (default varies per command)"),
  make_option("--day-summary",
    type = "logical", action = "store_true", default = FALSE,
    help = "Print qualitative end-of-day summary (Garmin + HAE)"),
  make_option("--date",
    type = "character", default = NULL,
    help = "Reference date (YYYY-MM-DD) for --day-summary (default today)"),
  # --- Sport filter ---
  make_option("--sport",
    type = "character", default = NULL,
    help = paste0(
      "Sport bucket to filter on. Defaults vary by command: 'running' ",
      "for legacy reports (month-top, year-running, --acwr) and for ",
      "running-specific metrics (--ef, --hre, --decoupling); 'all' for ",
      "the whole-system PMC (--pmc). Examples: 'cycling', 'walking', ",
      "'strength', 'all' (no filter), 'endurance' ",
      "(running+cycling+walking+swimming). Swedish aliases ",
      "('löpning', 'cykling', 'gång') also accepted."
    )),
  # --- Health checks ---
  make_option("--doctor",
    type = "logical", action = "store_true", default = FALSE,
    help = "Run deployment health checks"),
  make_option("--doctor-check",
    type = "character", default = "all",
    help = paste0("Comma-separated subset: all|packages|services|configs",
                  "|freshness (default %default)")),
  make_option("--doctor-json",
    type = "logical", action = "store_true", default = FALSE,
    help = "Emit doctor results as JSON instead of human-readable text"),
  make_option("--rebuild-stale",
    type = "logical", action = "store_true", default = FALSE,
    help = "Rebuild user-lib R packages built against a previous R version")
)

opt_parser <- OptionParser(option_list = my_options)
options <- parse_args(opt_parser)

# --- Doctor / rebuild-stale (no data load required) ---
# Run before TRANING_DATA validation so doctor works on hosts where the
# data repo is not configured (or to diagnose why it isn't).
if (isTRUE(options$`rebuild-stale`)) {
  rebuild_stale_userlib()
  quit(status = 0L, save = "no")
}
if (isTRUE(options$doctor)) {
  raw_checks <- options$`doctor-check`
  checks <- if (identical(raw_checks, "all"))
              .VALID_DOCTOR_CHECKS
            else trimws(strsplit(raw_checks, ",")[[1]])
  invalid <- setdiff(checks, .VALID_DOCTOR_CHECKS)
  if (length(invalid) > 0L) {
    message("Unknown --doctor-check value(s): ",
            paste(invalid, collapse = ", "),
            ". Valid: all, ", paste(.VALID_DOCTOR_CHECKS, collapse = ", "))
    quit(status = 2L, save = "no")
  }
  res <- doctor_run(checks = checks)
  cat(if (isTRUE(options$`doctor-json`))
        as.character(format_doctor_json(res))
      else format_doctor_human(res))
  quit(status = if (isTRUE(res$ok)) 0L else 1L, save = "no")
}

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
do_overview_cache <- options$`overview-cache`
do_force        <- options$force
do_plot         <- options$plot
do_output       <- options$output
do_format       <- options$format
do_no_open      <- options$`no-open`
do_limit        <- options$limit
# Legacy reports (month-top, year-running, …) keep the historical
# "running" default. PMC and ACWR pick "all" / mode-aware defaults
# at their call sites below by reading options$sport directly.
do_sport        <- options$sport %||% "running"
do_day_summary  <- options$`day-summary`
do_date_ref     <- options$date

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

# --- Retroactive dedup -------------------------------------------------------
# Handled before the shared load below so the Garmin auto-augment block
# doesn't rewrite the cache underneath a maintenance run.
if (isTRUE(options$dedup)) {
  # Reporting is the default and removal is opt-in: this command deletes
  # rows from the only copy of the cache, so the safe outcome is the one
  # you get by forgetting a flag. `--dry-run` is still accepted and means
  # what it says, it is simply no longer needed.
  # --dry-run wins over --apply, matching the Python layer. Between two
  # contradictory flags the harmless reading is the right one, and a
  # command with no undo should not be talked into writing by an
  # ambiguous invocation.
  dedup_summaries(db_summaries, db_myruns,
                  dry_run = isTRUE(options$`dry-run`) || !isTRUE(options$apply),
                  verbose = TRUE)
  quit(status = 0L, save = "no")
}

# --- Load data ---
my_templist <- my_dbs_load(db_summaries, db_myruns)
summaries <- my_templist[["summaries"]]
myruns <- my_templist[["myruns"]]
rm(my_templist)

# Auto-upgrade legacy caches missing the garmin_* columns. Before this
# block existed the cache held only raw TCX/HAE rows and each consumer
# (Shiny, MCP, R-tests) had to re-augment in memory — and they often
# did so differently. After this block, garmin_* columns are guaranteed
# present whenever Garmin JSON data is available, so every downstream
# command (--pmc, --acwr, --ef, --decoupling, ...) operates on the same
# enriched view. The upgrade is persisted so subsequent invocations
# (and other processes reading the same cache) skip the augment step.
# Decide whether the JSON cache has grown since the last augmentation
# pass — if so, re-run augment_summaries() with force=TRUE so rows
# that were "no match yet" at the time get a fresh look. Garmin
# Connect occasionally delivers JSON for an activity hours or days
# after its TCX file, and without this comparison those rows would
# stay garmin_matched=TRUE / metrics=NA forever.
gc_json_cache <- file.path(traning_data, "cache", "garmin_json.RData")
augmented_at <- attr(summaries, "garmin_augmented_at")
# Missing attribute (legacy cache from before attr-tracking) is treated
# as "infinitely old" so the next augment will refresh under force=TRUE
# and stamp the cache correctly going forward.
if (is.null(augmented_at)) augmented_at <- as.POSIXct("1970-01-01", tz = "UTC")
json_cache_newer <-
  file.exists(gc_json_cache) &&
  file.mtime(gc_json_cache) > augmented_at

# This block runs before any import, so the import counters that gate the
# equivalent decisions further down do not exist yet and cannot apply
# here. See the --import block for the enumeration.
if ((!("garmin_matched" %in% names(summaries)) || json_cache_newer) &&
    dir.exists(gc_json_dir)) {
  # Presence of `garmin_matched` is the canonical "this cache has been
  # augmented" signal; the mtime comparison handles JSON-backfill.
  # augment_summaries() creates the marker even when garmin_data is
  # empty, so this block fires exactly once per cache for a given
  # JSON-cache state.
  if (json_cache_newer) {
    message("Auto-upgrading cache: Garmin JSON-cachen är nyare än senaste augmentation — kör om med force=TRUE …")
  } else {
    message("Auto-upgrading cache: lägger till garmin_*-kolumner från Garmin JSON …")
  }
  garmin_data <- tryCatch(load_garmin_json(gc_json_dir),
                           error = function(e) {
                             warning("load_garmin_json failed: ",
                                     conditionMessage(e))
                             NULL
                           })
  if (!is.null(garmin_data)) {
    # Call augment_summaries even on an empty garmin_data tibble; it
    # still creates the garmin_* columns and the garmin_matched
    # marker, which makes the cache canonically structured so this
    # upgrade block fires exactly once instead of on every invocation.
    augmented <- tryCatch(
      augment_summaries(summaries, garmin_data, force = json_cache_newer),
      error = function(e) {
        warning("augment_summaries failed: ", conditionMessage(e))
        NULL
      })
    if (!is.null(augmented)) {
      summaries <- augmented
      my_dbs_save(db_summaries, db_myruns, summaries, myruns)
    }
  }
}

# --- Import ---
if (do_import) {
  files <- get_my_files(mytcxpath)
  # nrow() gives an integer scalar; dplyr::count() returned a 1-row
  # tibble which propagated through the arithmetic below and only
  # happened to coerce cleanly via as.numeric() because of dplyr's
  # tibble subtraction behaviour. Plain nrow() is the right primitive.
  summaries_oldlength <- nrow(summaries)
  my_templist <- get_new_workouts(files, summaries, myruns, verbose = do_verbose,
                                  db_summaries = db_summaries, db_myruns = db_myruns)
  summaries <- my_templist[["summaries"]]
  myruns <- my_templist[["myruns"]]
  n_imported <- my_templist[["n_imported"]] %||% 0
  n_updated <- my_templist[["n_updated"]]
  n_hae_removed <- my_templist[["n_hae_removed"]] %||% 0
  n_hae_fragment_swaps <- 0L
  rm(my_templist)
  if (n_hae_removed > 0) {
    cat("Ersatte ", n_hae_removed,
        " Apple Watch-rad(er) med Garmin-inläsningen.\n", sep = "")
  }

  # Then import HAE workouts (Apple Watch via Health Auto Export)
  hae_workouts_dir <- file.path(Sys.getenv("TRANING_DATA"),
                                "kristian", "health_export", "workouts")
  if (dir.exists(hae_workouts_dir)) {
    hae_res <- import_hae_workouts(hae_workouts_dir, summaries, myruns,
                                   verbose = do_verbose)
    summaries <- hae_res$summaries
    myruns <- hae_res$myruns
    # A Garmin fragment replaced by the Apple Watch row: one row out, one
    # row in, so the row count alone cannot tell that the cache changed.
    n_hae_fragment_swaps <- hae_res$n_garmin_fragments %||% 0L
    if (n_hae_fragment_swaps > 0) {
      cat("Ersatte ", n_hae_fragment_swaps,
          " Garmin-fragment med Apple Watch-raden.\n", sep = "")
    }
    if (hae_res$n_imported > 0 || hae_res$n_skipped_dup > 0 ||
        hae_res$n_skipped_dup_hae > 0) {
      cat("HAE-workouts: ", hae_res$n_imported, " importerade, ",
          hae_res$n_skipped_dup, " deduppade mot Garmin",
          if (hae_res$n_skipped_dup_hae > 0)
            paste0(", ", hae_res$n_skipped_dup_hae, " dubbla HAE-filer") else "",
          if (hae_res$n_skipped_invalid > 0)
            paste0(", ", hae_res$n_skipped_invalid, " ogiltiga") else "",
          "\n", sep = "")
      if (hae_res$n_imported > 0 && length(hae_res$by_sport) > 0) {
        cat("  per sport: ",
            paste(names(hae_res$by_sport), hae_res$by_sport,
                  sep = "=", collapse = ", "),
            "\n", sep = "")
      }
      # New Apple activity types get neither a Swedish label nor a
      # bucket until they are added to .HAE_SPORT_NAMES — say so on the
      # first import instead of letting them show up as raw slugs later.
      if (hae_res$n_unmapped_sports > 0) {
        cat("  okänd aktivitetstyp: ",
            paste(hae_res$unmapped_names, collapse = ", "),
            " (saknar etikett och bucket)\n", sep = "")
      }
    }
  }

  summaries_newlength <- nrow(summaries)
  summaries_lengthdiff <- summaries_newlength - summaries_oldlength

  # Re-augment when either:
  #   (a) new TCX/HAE rows were imported above (need garmin_* match), or
  #   (b) the Garmin JSON cache has grown since the last augment (a
  #       delayed JSON arrived for an activity we imported earlier).
  # augment_summaries() is incremental, so the (a)-only path stays
  # cheap; (b) triggers force=TRUE further down so previously
  # unmatched rows get a fresh look.
  #
  # (a) cannot be read off the row count. The three import counters,
  # and whether each belongs in this gate:
  #   n_hae_removed        yes — a Garmin row was appended and an Apple
  #                        Watch row dropped, so the count stands still
  #                        while a brand-new row needs its garmin_*
  #                        columns filled in.
  #   n_hae_fragment_swaps yes — same shape from the other side: an HAE
  #                        row replaced a Garmin fragment.
  #   n_garmin_fragments   no  — that branch declines to add a row, so
  #   (from get_new_workouts)   there is nothing new to augment. It is
  #                        also non-zero on every import, which would
  #                        make this block run forever for nothing.
  # Without the first two the swapped-in row was saved with garmin_* =
  # NA until some later run happened to backfill it, and a combined
  # invocation such as `--import --pmc` read the stale values.
  augmented_at <- attr(summaries, "garmin_augmented_at")
  if (is.null(augmented_at)) augmented_at <- as.POSIXct("1970-01-01", tz = "UTC")
  json_cache_newer <-
    file.exists(gc_json_cache) &&
    file.mtime(gc_json_cache) > augmented_at
  if ((summaries_lengthdiff > 0 || json_cache_newer ||
       n_hae_removed > 0 || n_hae_fragment_swaps > 0) &&
      dir.exists(gc_json_dir)) {
    garmin_data <- tryCatch(load_garmin_json(gc_json_dir),
                             error = function(e) {
                               warning("load_garmin_json failed: ",
                                       conditionMessage(e))
                               NULL
                             })
    if (!is.null(garmin_data)) {
      # Empty garmin_data is still passed through so newly imported
      # rows acquire garmin_* columns and garmin_matched in the
      # canonical shape; without this the new rows would carry NA
      # marker values that break the NA-safe incremental check.
      summaries <- tryCatch(
        augment_summaries(summaries, garmin_data, force = json_cache_newer),
        error = function(e) {
          warning("augment_summaries failed: ", conditionMessage(e))
          summaries
        })
    }
  }

  # Save when anything changed: new rows, filename corrections, or a
  # backfill-driven re-augment refreshed the garmin_* / matched state.
  #
  # Row *count* is not enough on its own. Two of the dedup outcomes swap
  # one row for another and leave the total untouched: a Garmin import
  # that evicts the Apple Watch row for the same session, and an HAE
  # import that replaces a Garmin fragment. Without the counters below
  # those edits lived only in memory and the duplicate returned on the
  # next run.
  #
  # get_new_workouts()'s own fragment counter is deliberately *not* here.
  # That branch declines to add a row and changes nothing, and the seven
  # fragment files are re-read on every import, so keying the save on it
  # would rewrite the whole cache — myruns included — every single run
  # with nothing to show for it.
  if (summaries_lengthdiff > 0 || n_updated > 0 || json_cache_newer ||
      n_hae_removed > 0 || n_hae_fragment_swaps > 0) {
    my_dbs_save(db_summaries, db_myruns, summaries, myruns)
  }
  # What to print is a fourth decision in the same family, and it needs
  # yet another quantity: the number of rows appended, which is neither
  # the change in row count nor any of the dedup counters. A session that
  # evicted its Apple Watch twin is a new session worth reporting even
  # though the cache is the same size. Imported rows sit at the end of
  # `summaries` in append order, so tail() still selects them.
  if (n_imported > 0) {
    summaries_mostrecent <- utils::tail(summaries, n = n_imported)
    report_mostrecent(summaries_mostrecent, n_imported)
  } else if (n_updated > 0) {
    cat("Inget att importera (", n_updated, " filnamn uppdaterade).\n", sep = "")
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

# Note: the cache-load block at the top of this file now guarantees
# that garmin_* columns are present whenever Garmin JSON data is
# available, regardless of which command was invoked. The previous
# command-specific augment block here was therefore both incomplete
# (only covered --recovery-hr / --decoupling / --hr-zones, missing
# --pmc which also uses get_hr_max()) and redundant.

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
    emit_plot(plot_monthtop(summaries, from = date_range$from, to = date_range$to,
                            sport = do_sport), "month-top")
  } else {
    emit_table(report_monthtop(summaries, n = do_limit %||% 10L,
                               from = date_range$from, to = date_range$to,
                               sport = do_sport), "month-top")
  }
}

if (do_month_running) {
  if (do_plot) {
    emit_plot(plot_monthstatus(summaries, from = date_range$from, to = date_range$to,
                               sport = do_sport), "month-running")
  } else {
    emit_table(report_monthstatus(summaries, n = do_limit,
                                  from = date_range$from, to = date_range$to,
                                  sport = do_sport), "month-running")
  }
}

if (do_month_this) {
  if (do_plot) {
    emit_plot(plot_runs_month(summaries, from = date_range$from, to = date_range$to,
                              sport = do_sport), "month-this")
  } else {
    month_summaries_this <- report_runs_year_month(summaries, n = do_limit,
                                                    from = date_range$from,
                                                    to = date_range$to,
                                                    sport = do_sport)
    emit_table(month_summaries_this, "month-this")
    if (is.null(do_output) && is.null(do_format)) {
      my_month_km <- fmt_dec_sv(sum(month_summaries_this$Km), digits = 2,
                                trim_zero = TRUE)
      my_month_pace <- fmt_dec_sv(mean(month_summaries_this$Pace), digits = 2,
                                  trim_zero = TRUE)
      cat(sprintf("Totalt %d springturer under %s %s; %s km, %s min/km.\n",
          nrow(month_summaries_this), format(Sys.time(), "%b"),
          format(Sys.time(), "%Y"), my_month_km, my_month_pace))
    }
  }
}

if (do_month_last) {
  if (do_plot) {
    emit_plot(plot_monthlast(summaries, from = date_range$from, to = date_range$to,
                             sport = do_sport), "month-last")
  } else {
    emit_table(report_monthlast(summaries, n = do_limit,
                                from = date_range$from, to = date_range$to,
                                sport = do_sport), "month-last")
  }
}

if (do_year_running) {
  if (do_plot) {
    emit_plot(fetch.plot.cumulative_km(summaries,
                                        from = date_range$from,
                                        to = date_range$to,
                                        sport = do_sport), "year-running")
  } else {
    emit_table(report_yearstatus(summaries, n = do_limit,
                                 from = date_range$from, to = date_range$to,
                                 sport = do_sport), "year-running")
  }
}

if (do_year_top) {
  if (do_plot) {
    emit_plot(plot_yearstop(summaries, from = date_range$from, to = date_range$to,
                            sport = do_sport), "year-top")
  } else {
    emit_table(report_yearstop(summaries, n = do_limit,
                               from = date_range$from, to = date_range$to,
                               sport = do_sport), "year-top")
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
    emit_plot(plot_datesum(summaries, dr_from, dr_to,
                           sport = do_sport), "datesum")
  } else {
    emit_table(report_datesum(summaries, dr_from, dr_to,
                              sport = do_sport), "datesum")
  }
}

if (do_total_pace) {
  pace_data <- if (has_daterange) filter_by_daterange(summaries, date_range) else summaries
  if (do_plot) {
    emit_plot(fetch.plot.pace_year(pace_data, sport = do_sport),
              "total-pace")
  } else {
    emit_table(report_yearstop(pace_data, sport = do_sport), "total-pace")
  }
}

# --- Reports: time-series metrics (use FULL data, filter output) ---
# These commands always receive unfiltered summaries so that rolling-window
# computations (28-day means, EWMA, etc.) have complete history.
# The date range is applied to the computed output for display.

if (do_ef) {
  if (do_plot) {
    emit_plot(fetch.plot.ef(summaries, from = date_range$from, to = date_range$to,
                            sport = do_sport), "ef")
  } else {
    emit_table(report_ef(summaries, n = do_limit %||% 28L,
                    from = date_range$from, to = date_range$to,
                    sport = do_sport), "ef")
  }
}

if (do_hre) {
  if (do_plot) {
    emit_plot(fetch.plot.hre(summaries, from = date_range$from, to = date_range$to,
                             sport = do_sport), "hre")
  } else {
    emit_table(report_hre(summaries, n = do_limit %||% 28L,
                     from = date_range$from, to = date_range$to,
                     sport = do_sport), "hre")
  }
}

if (do_acwr) {
  # When the user requests whole-system ACWR (--sport all) the auto-
  # mode resolves to TRIMP, which can fold in background activity if
  # health_daily is threaded through. Load it unconditionally so
  # --acwr --sport all matches the Shiny / MCP behaviour; the
  # running-default path ignores it and stays km-mode.
  hd_for_acwr <- tryCatch(load_health_data(), error = function(e) NULL)
  td_for_acwr <- traning_data(summaries = summaries, health_daily = hd_for_acwr,
                               augmented = "garmin_matched" %in% names(summaries))
  if (do_plot) {
    emit_plot(fetch.plot.acwr(td_for_acwr, from = date_range$from, to = date_range$to,
                              sport = do_sport), "acwr")
  } else {
    emit_table(report_acwr(td_for_acwr, n = do_limit %||% 28L,
                      from = date_range$from, to = date_range$to,
                      sport = do_sport), "acwr")
  }
}

if (do_monotony) {
  if (do_plot) {
    emit_plot(fetch.plot.monotony(summaries, from = date_range$from, to = date_range$to,
                                  sport = do_sport), "monotony")
  } else {
    emit_table(report_monotony(summaries, n = do_limit %||% 28L,
                          from = date_range$from, to = date_range$to,
                          sport = do_sport), "monotony")
  }
}

if (do_pmc) {
  # PMC is a whole-system load metric; default to "all" so the rendered
  # PMC matches readiness / overview KPIs. Users can still pass
  # --sport=running for a running-only PMC.
  sport_for_pmc <- options$sport %||% "all"
  hd_for_pmc <- tryCatch(load_health_data(), error = function(e) NULL)
  td_for_pmc <- traning_data(summaries = summaries, health_daily = hd_for_pmc,
                              augmented = "garmin_matched" %in% names(summaries))
  if (do_plot) {
    emit_plot(fetch.plot.pmc(td_for_pmc, from = date_range$from, to = date_range$to,
                             sport = sport_for_pmc), "pmc")
  } else {
    emit_table(report_pmc(td_for_pmc, n = do_limit %||% 28L,
                     from = date_range$from, to = date_range$to,
                     sport = sport_for_pmc), "pmc")
  }
}

# --- Health data import ---
if (do_import_health) {
  import_health_export(force = do_force, verbose = TRUE)
}

if (do_overview_cache) {
  health_daily_for_overview <- tryCatch(load_health_data(), error = function(e) NULL)
  load_overview_metrics(summaries, health_daily_for_overview, force = TRUE)
  cat("Overview-cache ombyggd.\n")
}

# --- Readiness (requires health data) ---
if (do_day_summary) {
  td <- Sys.getenv("TRANING_DATA")
  tl <- my_dbs_load(file.path(td, "cache", "summaries.RData"),
                     file.path(td, "cache", "myruns.RData"))
  ref_date <- if (!is.null(do_date_ref)) as.Date(do_date_ref) else Sys.Date()
  cat(day_summary_prose(tl[["summaries"]], date = ref_date), "\n", sep = "")
  return_code <- 0L
}

if (do_readiness) {
  health_daily <- load_health_data()
  if (nrow(health_daily) == 0) {
    cat("Ingen hälsodata hittades. Kör --import-health först.\n")
  } else {
    td_for_readiness <- traning_data(summaries = summaries, health_daily = health_daily,
                                      augmented = "garmin_matched" %in% names(summaries))
    if (do_plot) {
      emit_plot(fetch.plot.readiness_score(td_for_readiness,
                  from = date_range$from, to = date_range$to), "readiness")
    } else {
      emit_table(report_readiness(td_for_readiness,
                    n = do_limit %||% 14L,
                    from = date_range$from, to = date_range$to), "readiness")
    }
  }
}

if (do_hr_zones) {
  # Per-second zone computation with caching (accurate VT1/VT2 thresholds).
  # The cache is sport-keyed, so pass do_sport through — both to the cache
  # loader AND to the bundle's @sport, so the traning_data validator's
  # sport-keying guard is satisfied.
  zone_data <- load_zone_distribution(summaries, myruns, force = do_force,
                                      sport = do_sport)
  td_for_zones <- traning_data(summaries = summaries, myruns = myruns,
                                zone_data = zone_data, sport = do_sport,
                                augmented = "garmin_matched" %in% names(summaries))
  if (do_plot) {
    emit_plot(fetch.plot.hr_zones(td_for_zones,
                from = date_range$from, to = date_range$to,
                sport = do_sport), "hr-zones")
  } else {
    emit_table(report_hr_zones(td_for_zones, n = do_limit %||% 12L,
                  from = date_range$from, to = date_range$to,
                  sport = do_sport), "hr-zones")
  }
}

if (do_recovery_hr) {
  td_for_rhr <- traning_data(summaries = summaries, sport = do_sport,
                              augmented = "garmin_matched" %in% names(summaries))
  if (do_plot) {
    emit_plot(fetch.plot.recovery_hr(td_for_rhr, from = date_range$from, to = date_range$to,
                                     sport = do_sport), "recovery-hr")
  } else {
    emit_table(report_recovery_hr(td_for_rhr, n = do_limit %||% 28L,
                             from = date_range$from, to = date_range$to,
                             sport = do_sport), "recovery-hr")
  }
}

if (do_decoupling) {
  decoupling_data <- load_decoupling(summaries, myruns, force = do_force,
                                     sport = do_sport)
  td_for_decoupling <- traning_data(summaries = summaries, myruns = myruns,
                                     decoupling_data = decoupling_data, sport = do_sport,
                                     augmented = "garmin_matched" %in% names(summaries))
  if (do_plot) {
    emit_plot(fetch.plot.decoupling(td_for_decoupling,
                from = date_range$from, to = date_range$to,
                sport = do_sport), "decoupling")
  } else {
    emit_table(report_decoupling(td_for_decoupling, n = do_limit %||% 28L,
                  from = date_range$from, to = date_range$to,
                  sport = do_sport), "decoupling")
  }
}

# --- Warm the Shiny overview-page precache after an import ------------------
# Every Python import entrypoint (garmin, health, backfill, "import all")
# funnels through --import and/or --import-health, so warming here covers
# all of them without touching the Python side. Reuses the `summaries`
# already loaded/updated above rather than re-reading from disk. In
# `import all`, --import-health runs last (summaries already reflect the
# --import pass), so this fires exactly once per invocation, not once per
# flag.
if (do_import || do_import_health) {
  hd_for_overview_warm <- tryCatch(load_health_data(), error = function(e) NULL)
  tryCatch(load_overview_metrics(summaries, hd_for_overview_warm, force = TRUE),
           error = function(e) message("overview-cache: ", conditionMessage(e)))
}

# vim: ts=2 sw=2 et
