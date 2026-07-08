#!/usr/bin/env Rscript

# Vayu MCP warm bridge server — persistent process, one library(traning)
# load, framed request/response protocol over stdin/stdout.
#
# This is a pure optimization on top of inst/mcp_bridge.R (the per-call
# "spawn" bridge): for a given (func, args) pair, the JSON envelope this
# process returns MUST be byte-identical to spawning mcp_bridge.R fresh.
# See inst/mcp_bridge_shared.R (func_registry, build_call_args(),
# run_dispatch(), .load_traning()) — both bridges share that dispatch
# logic verbatim; only the DATA-LOADING layer differs (this file adds an
# in-memory mtime cache so repeat calls skip re-reading cache/*.RData
# from disk, in particular the ~89MB myruns.RData).
#
# Owned/spawned by python/traning_cli/mcp/r_bridge.py's WarmRBridge,
# which also implements the fallback: on ANY protocol trouble (timeout,
# EOF, malformed frame, id desync) Python kills this process and falls
# back to spawning inst/mcp_bridge.R fresh. This process therefore never
# needs to be perfectly reliable — it only needs to never HANG (see the
# I/O-safety notes below) and never silently return wrong data (see the
# mtime-cache notes below).
#
# --- Protocol -----------------------------------------------------------
# Newline-delimited, base64-encoded JSON frames: one request per line on
# stdin, one response per line on stdout.
#
#   request  := base64(json({"id": <num>, "func": <str>, "args": {...},
#                             "plot": <bool>, "plot_path": <str|null>})) "\n"
#   response := base64(json({"id": <num>, "type": "data"|"plot"|"error",
#                             ...})) "\n"
#
# Base64 (with any embedded newline stripped before writing) rather than
# raw JSON-per-line: jsonlite's encoder cannot be trusted to NEVER emit
# an embedded "\n" inside a string field (report/health text values are
# user data, not under this script's control), and a literal newline
# there would desync the line-based framing silently. Base64 makes
# desync structurally impossible — its alphabet contains no newline
# byte — at the cost of ~33% more bytes per frame, which is irrelevant
# at this payload size (KBs, not MBs).
#
# --- I/O safety (never let a warning corrupt the frame stream) ---------
# `.frame_out` is opened on the real stdout fd (`/dev/stdout`) BEFORE
# anything else runs, and every response is written directly to that
# connection object. Immediately after, `sink(type = "output")` and
# `sink(type = "message")` are installed so that the DEFAULT output
# target — what `cat()`/`print()`/`message()`/`warning()` write to when
# no connection is given explicitly — is stderr, not stdout. Any code in
# this script, mcp_bridge_shared.R, or a dependency package that prints
# a stray diagnostic can therefore never land on the frame stream: only
# `writeLines(..., con = .frame_out)` calls do, and those only happen at
# the one call site that emits a framed response. This is Unix-only
# (`/dev/stdout`) — the warm server is only deployed on macOS (dev) and
# Linux (kailash); Windows is not a target for this process.
#
# --- Never quit() on a request-level error ------------------------------
# `emit_error()` in inst/mcp_bridge.R calls quit() after printing — that
# is correct for the spawn bridge (a fresh process per call) but would
# kill this persistent process on the FIRST bad request. `serve_one()`
# below always RETURNS an error envelope instead; the request loop keeps
# running. The only things that end this process are: stdin EOF (parent
# died) or an uncaught panic outside serve_one()'s tryCatch (should be
# unreachable — everything serve_one() might throw is caught).
#
# --- In-memory mtime cache (correctness-critical) -----------------------
# `cache/*.RData` is rewritten on disk between calls (e.g. a mid-session
# `traning import`). Every request re-`stat`s the files its dependency
# bucket needs and compares mtime against what's cached in memory;
# only a changed source is reloaded, and only the derived products that
# depend on it are invalidated (see `.memo()` / the `.get_*()` family
# below). `file.info()$mtime` is a cheap stat call — this check runs on
# every request, even cache hits, and its cost is negligible next to a
# disk `load()` of a multi-MB RData file.

# --- Bootstrap ---
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) == 0) script_path <- "inst/mcp_bridge_server.R"
pkg_root <- normalizePath(file.path(dirname(script_path), ".."))

# Grab the real stdout connection before anything can redirect it (see
# the I/O-safety note above).
.frame_out <- file("/dev/stdout", open = "w")

source(file.path(pkg_root, "inst", "mcp_bridge_shared.R"), local = FALSE)

.load_traning(pkg_root)

# From here on: default output goes to stderr. Only `.frame_out` reaches
# the real stdout pipe Python reads.
sink(stderr(), type = "output")
sink(stderr(), type = "message")

message(sprintf(
  "mcp_bridge_server: booted, traning %s, pid %d",
  as.character(utils::packageVersion("traning")), Sys.getpid()
))

# --- Data paths (fixed for the process lifetime; TRANING_DATA does not
# change once the server is running) ---
traning_data_root <- Sys.getenv("TRANING_DATA")
if (traning_data_root == "") {
  stop("mcp_bridge_server: TRANING_DATA is not set")
}
db_summaries      <- file.path(traning_data_root, "cache", "summaries.RData")
db_myruns         <- file.path(traning_data_root, "cache", "myruns.RData")
gc_json_dir       <- file.path(traning_data_root, "kristian", "filer", "gconnect")
garmin_cache_path <- normalizePath(
  file.path(traning_data_root, "cache", "garmin_json.RData"), mustWork = FALSE
)
# .hae_cache_path() is an internal (non-exported) traning helper —
# reused via `:::` rather than duplicating its TRANING_DATA-relative
# path construction here. (zone/decoupling cache paths are NOT tracked
# here — see the comment on .get_zone_data()/.get_decoupling_data()
# below for why keying on those files' own mtime is actively harmful.)
health_cache_path <- traning:::.hae_cache_path()

# --- In-memory cache state ---
.STATE <- new.env(parent = emptyenv())

.mtime_num <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) return(NA_real_)
  as.numeric(file.info(path)$mtime)
}

# Recompute + store under `slot` only when `key` differs from what's
# cached there. `key` is typically a list of mtimes (+ sport, params,
# ...) — compared with identical() so NA (file absent) round-trips
# safely and a change in ANY component invalidates the entry.
.memo <- function(slot, key, loader) {
  entry <- .STATE[[slot]]
  if (!is.null(entry) && identical(entry$key, key)) {
    return(entry$value)
  }
  value <- loader()
  .STATE[[slot]] <- list(key = key, value = value)
  value
}

# --- Split summaries/myruns loading ---
# my_dbs_load() (R/import.R) — used by the spawn bridge — always loads
# BOTH RData files unconditionally, including the ~89MB myruns.RData,
# even for "s"-only requests (the common case: most report_* functions
# only need summaries). That's fine for a process that exits after one
# call; it would defeat the warm server's entire purpose. These two
# loaders replicate my_dbs_load()'s per-file logic (including its
# trackeRdataSummary-class-stripping and source-column-backfill
# normalization — see R/import.R) but split so myruns.RData is loaded
# ONLY when a request's dependency bucket actually contains "m".
.load_summaries_only <- function() {
  message("mcp_bridge_server: (re)loading summaries.RData from disk")
  if (file.exists(db_summaries)) {
    e <- new.env()
    load(db_summaries, envir = e)
    summaries <- e$summaries
  } else {
    summaries <- data.frame()
  }
  # Strip trackeRdataSummary class — its `[` method conflicts with dplyr.
  if (inherits(summaries, "trackeRdataSummary")) {
    class(summaries) <- "data.frame"
  }
  # Backfill source column for caches predating multi-source support.
  if (is.data.frame(summaries) && nrow(summaries) > 0 &&
      !"source" %in% names(summaries)) {
    summaries$source <- "tcx"
  }
  summaries
}

.load_myruns_only <- function() {
  message("mcp_bridge_server: (re)loading myruns.RData from disk (~89MB)")
  if (file.exists(db_myruns)) {
    e <- new.env()
    load(db_myruns, envir = e)
    myruns <- e$myruns
  } else {
    myruns <- list()
  }
  myruns
}

.get_summaries <- function() {
  .memo("summaries", .mtime_num(db_summaries), .load_summaries_only)
}

.get_myruns <- function() {
  .memo("myruns", .mtime_num(db_myruns), .load_myruns_only)
}

# Garmin-augmented summaries. Depends on the raw summaries mtime AND the
# garmin_json.RData cache mtime that load_garmin_json() itself
# maintains — a fresh Garmin Connect sync can update that file without
# touching summaries.RData, and vice versa.
.get_augmented_summaries <- function(summaries) {
  key <- list(.mtime_num(db_summaries), .mtime_num(garmin_cache_path))
  .memo("augmented_summaries", key, function() {
    if (!dir.exists(gc_json_dir)) return(summaries)
    garmin_data <- load_garmin_json(gc_json_dir)
    augment_summaries(summaries, garmin_data)
  })
}

.get_health_daily <- function() {
  .memo("health_daily", .mtime_num(health_cache_path),
        function() load_health_data())
}

# Zone / decoupling caches are keyed by sport (a cache built for
# "running" must never be reused for "cycling" — see load_zone_
# distribution()'s / load_decoupling()'s own sport-match guard) and by
# every upstream mtime that could change their output: summaries,
# garmin augmentation, and myruns.
#
# Deliberately NOT keyed on zone_cache_path's / decoupling_cache_path's
# own mtime, even though that would seem like the most direct
# staleness signal: load_zone_distribution() (and load_decoupling(),
# unless called with read_only = TRUE, which this server does not)
# unconditionally REWRITES its own RData cache file on every call —
# including a pure cache-hit call that computed zero new sessions. If
# the key included that file's mtime, every call would bump the mtime
# and invalidate the memo entry for the NEXT call, permanently
# defeating the cache (verified empirically: an early version of this
# file did this and re-ran the full zone computation on every single
# request). Since zone/decoupling data is fully reconstructible from
# summaries + myruns + params, the file's own mtime carries no
# information the summaries/myruns/garmin mtimes don't already capture.
.get_zone_data <- function(summaries, myruns, sport) {
  key <- list(sport = sport,
              summaries_mtime = .mtime_num(db_summaries),
              garmin_mtime    = .mtime_num(garmin_cache_path),
              myruns_mtime    = .mtime_num(db_myruns))
  .memo(paste0("zone_", sport), key, function() {
    load_zone_distribution(summaries, myruns, sport = sport)
  })
}

.get_decoupling_data <- function(summaries, myruns, sport) {
  key <- list(sport = sport,
              summaries_mtime = .mtime_num(db_summaries),
              garmin_mtime    = .mtime_num(garmin_cache_path),
              myruns_mtime    = .mtime_num(db_myruns))
  .memo(paste0("decoupling_", sport), key, function() {
    load_decoupling(summaries, myruns, sport = sport)
  })
}

# --- Build the traning_data bundle for one request -----------------------
# Mirrors mcp_bridge.R's "Conditional data loading" + "Build the
# traning_data bundle" blocks exactly (same order of operations, same
# fallback values for unloaded slots) but sources each slot from the
# memoized .get_*() accessors above instead of an unconditional disk
# read.
build_bundle <- function(func_name, func_args) {
  deps <- func_registry[[func_name]]
  needs <- function(ch) grepl(ch, deps, fixed = TRUE)

  summaries <- NULL
  myruns <- NULL
  health_daily <- NULL
  zone_data <- NULL
  decoupling_data <- NULL

  if (needs("s") || needs("m")) {
    summaries <- .get_summaries()
  }
  if (needs("m")) {
    myruns <- .get_myruns()
  }

  if (needs("g") && dir.exists(gc_json_dir)) {
    summaries <- .get_augmented_summaries(summaries)
  }

  if (needs("h")) {
    health_daily <- .get_health_daily()
  }

  sport_arg <- if (!is.null(func_args$sport)) {
    as.character(func_args$sport)
  } else {
    "running"
  }

  if (needs("z")) {
    zone_data <- .get_zone_data(summaries, myruns, sport_arg)
  }

  if (needs("d")) {
    decoupling_data <- .get_decoupling_data(summaries, myruns, sport_arg)
  }

  traning_data(
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
}

# --- Serve one request, return a response envelope (never emit/quit) ---
serve_one <- function(req) {
  id <- req$id
  func_name <- req$func
  func_args <- req$args
  if (is.null(func_args)) func_args <- list()
  do_plot <- isTRUE(req$plot)
  plot_path <- req$plot_path

  if (is.null(func_name) || !func_name %in% names(func_registry)) {
    return(list(id = id, type = "error",
                message = paste0("Unknown or missing function: ", func_name)))
  }

  bundle <- tryCatch(build_bundle(func_name, func_args),
                     error = function(e) e)
  if (inherits(bundle, "error")) {
    return(list(id = id, type = "error",
                message = paste0("mcp_bridge_server: data load error: ",
                                 conditionMessage(bundle))))
  }

  call_args <- tryCatch(build_call_args(func_name, func_args, bundle),
                        error = function(e) e)
  if (inherits(call_args, "error")) {
    return(list(id = id, type = "error",
                message = paste0("mcp_bridge_server: argument error: ",
                                 conditionMessage(call_args))))
  }

  resp <- run_dispatch(func_name, call_args, do_plot, plot_path)
  resp$id <- id
  resp
}

# --- Framing ---
send_frame <- function(con, obj) {
  payload <- as.character(jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null",
                                           dataframe = "rows", Date = "ISO8601"))
  encoded <- gsub("[\r\n]", "", jsonlite::base64_enc(charToRaw(payload)))
  writeLines(encoded, con = con)
  flush(con)
}

read_frame <- function(con) {
  line <- tryCatch(readLines(con, n = 1, warn = FALSE),
                   error = function(e) character(0))
  if (length(line) == 0) return(NULL)  # EOF
  if (!nzchar(line)) return(list())     # blank line — treated as a no-op below
  tryCatch({
    payload <- rawToChar(jsonlite::base64_dec(line))
    jsonlite::fromJSON(payload, simplifyVector = FALSE)
  }, error = function(e) {
    message("mcp_bridge_server: dropped malformed request frame: ",
            conditionMessage(e))
    list()
  })
}

# --- Request loop ---
# NOTE: `stdin()` (no args) is R's console-input connection, which under
# Rscript is NOT wired to the process's actual stdin pipe and reads as
# immediate EOF — a `file("stdin", ...)` connection is required to read
# what Python's subprocess.Popen(..., stdin=PIPE) actually writes.
con_in <- file("stdin", open = "rt")
message("mcp_bridge_server: entering request loop")
repeat {
  req <- read_frame(con_in)
  if (is.null(req)) {
    message("mcp_bridge_server: stdin EOF, exiting")
    break
  }
  if (length(req) == 0 || is.null(req$id)) {
    # Blank line or a malformed frame we couldn't recover an id from —
    # nothing useful to respond with (there's no id to correlate a
    # response to), so just wait for the next line rather than guessing.
    next
  }
  resp <- tryCatch(
    serve_one(req),
    error = function(e) {
      list(id = req$id, type = "error",
          message = paste0("mcp_bridge_server: unhandled error: ",
                           conditionMessage(e)))
    }
  )
  send_frame(.frame_out, resp)
}
