# Health Auto Export (HAE) JSON parser
#
# Reads JSON exports from the Health Auto Export iOS app and returns
# tidy tibbles suitable for analysis alongside Garmin session data.

# --- Path helpers -------------------------------------------------------------

#' Resolve the health_export directory path
#' @return Character path to the health_export directory
#' @keywords internal
.hae_dir <- function() {
  data_root <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  if (is.na(data_root)) {
    stop("TRANING_DATA env var not set")
  }
  file.path(data_root, "kristian", "health_export")
}

#' Resolve the health data cache path
#' @return Character path to health_daily.RData
#' @keywords internal
.hae_cache_path <- function() {
  data_root <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  if (is.na(data_root)) {
    stop("TRANING_DATA env var not set")
  }
  file.path(data_root, "cache", "health_daily.RData")
}

#' Resolve the health import manifest path
#' @return Character path to health_import_manifest.json
#' @keywords internal
.hae_manifest_path <- function() {
  data_root <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  if (is.na(data_root)) {
    stop("TRANING_DATA env var not set")
  }
  file.path(data_root, "cache", "health_import_manifest.json")
}

#' Load the import manifest
#' @param manifest_path Path to manifest JSON. NULL = default.
#' @return Named list: filename -> list(mtime, size)
#' @keywords internal
.load_manifest <- function(manifest_path = NULL) {
  if (is.null(manifest_path)) manifest_path <- .hae_manifest_path()
  if (!file.exists(manifest_path)) return(list())
  loaded <- tryCatch(
    jsonlite::fromJSON(manifest_path, simplifyVector = FALSE),
    error = function(e) {
      warning("manifest JSON unreadable (", conditionMessage(e),
              "), starting with an empty manifest", call. = FALSE)
      NULL
    }
  )
  # Tolerate the case where the file parses as valid JSON but isn't the
  # shape we expect (a named list of entries). Anything else — a scalar,
  # an unnamed array, a string — degrades to an empty manifest so the
  # caller can still merge/replace without crashing downstream.
  if (!is.list(loaded) || is.null(names(loaded)) || any(names(loaded) == "")) {
    if (!is.null(loaded)) {
      warning("manifest has wrong shape (expected a named list of entries), ",
              "starting with an empty manifest", call. = FALSE)
    }
    return(list())
  }
  loaded
}

#' Compute what to write to the manifest after a run
#'
#' Centralised so every exit path (success, "no new data", filter-emptied)
#' goes through the same rule:
#'   * Full run (path = NULL): replace the manifest with the md5 of every
#'     file currently in the data directory — including files we didn't
#'     parse because .import_metrics filtered them out, so they don't
#'     re-trigger evaluation next run.
#'   * Single-file run (path != NULL): merge entries for every candidate
#'     into the existing on-disk manifest. We use `files` rather than
#'     `files_to_parse` so candidates dropped by .import_metrics still get
#'     their md5 recorded (otherwise a vector-path import containing only
#'     ignored canonical metrics never updates the manifest at all).
#'
#' @param files All candidate files seen this run (pre-filter).
#' @param path Original path argument (NULL = full run).
#' @param existing Manifest loaded at the top of the run. Expected to be a
#'   named list; non-list values are treated as empty so the merge can't
#'   crash on a malformed on-disk manifest.
#' @return Named list ready to pass to .save_manifest().
#' @keywords internal
.compute_manifest_to_save <- function(files, path, existing) {
  new_entries <- .build_manifest_entries(files)
  if (is.null(path)) {
    return(new_entries)
  }
  base <- if (is.list(existing)) existing else list()
  for (k in names(new_entries)) base[[k]] <- new_entries[[k]]
  base
}

#' Save the import manifest
#'
#' Atomic write: serialise to a temp file in the same directory, then rename.
#' On POSIX `file.rename()` overwrites an existing destination as a single
#' inode swap, so readers never observe a half-written manifest and a crash
#' mid-write leaves the previous version intact.
#'
#' POSIX-only invariant. On Windows `file.rename()` fails when the
#' destination exists, so this would abort on every save after the first.
#' The whole pipeline (kailash systemd services, AUR-managed R packages,
#' file paths) is Linux/macOS-only — Windows support is explicitly out of
#' scope. If that ever changes, this function needs an atomic replace that
#' works on NTFS (e.g. fs::file_move(), or a copy + unlink fallback that
#' accepts the loss of crash-atomicity on Windows).
#'
#' @param manifest Named list: filename -> list(md5)
#' @param manifest_path Path to manifest JSON. NULL = default.
#' @keywords internal
.save_manifest <- function(manifest, manifest_path = NULL) {
  if (is.null(manifest_path)) manifest_path <- .hae_manifest_path()
  cache_dir <- dirname(manifest_path)
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  tmp <- paste0(manifest_path, ".tmp.", Sys.getpid())
  on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
  jsonlite::write_json(manifest, tmp, auto_unbox = TRUE, pretty = TRUE)
  if (!file.rename(tmp, manifest_path)) {
    stop(".save_manifest: rename failed for ", manifest_path)
  }
}

#' Compare files against manifest and return only new/changed ones
#' @param files Character vector of file paths
#' @param manifest Named list from .load_manifest()
#' @return Character vector of files that need importing
#' @keywords internal
#' Generate a manifest key for a file path.
#'
#' For canonical files (path contains /canonical/), uses "metric/date.json".
#' For legacy files, uses basename.
#' @param path Character file path.
#' @return Character key.
#' @keywords internal
.manifest_key <- function(path) {
  if (grepl("/canonical/", path, fixed = TRUE)) {
    # canonical: metric_name/YYYY-MM-DD.json
    paste0(basename(dirname(path)), "/", basename(path))
  } else {
    basename(path)
  }
}

.filter_changed_files <- function(files, manifest) {
  changed <- vapply(files, function(f) {
    key <- .manifest_key(f)
    prev <- manifest[[key]]
    # Treat missing or malformed entries (no $md5, wrong type, NA) as "new"
    # so we re-parse instead of letting an NA propagate through `!=` and
    # turning a path into NA in the result. A corrupt manifest should
    # degrade to full re-import, not raise and not poison the file list.
    if (is.null(prev) || !is.list(prev) || is.null(prev$md5) ||
        !is.character(prev$md5) || length(prev$md5) != 1 ||
        is.na(prev$md5)) {
      return(TRUE)
    }
    unname(tools::md5sum(f)) != prev$md5
  }, logical(1))
  files[changed]
}

#' Build manifest entries for a set of files
#' @param files Character vector of file paths
#' @return Named list: key -> list(md5)
#' @keywords internal
.build_manifest_entries <- function(files) {
  entries <- list()
  for (f in files) {
    entries[[.manifest_key(f)]] <- list(
      md5 = unname(tools::md5sum(f))
    )
  }
  entries
}

# --- JSON parsing -------------------------------------------------------------

#' Parse a single HAE metric entry into a long-format tibble
#'
#' Handles three formats:
#' \itemize{
#'   \item Standard: \code{qty} field (most metrics)
#'   \item Heart rate: \code{Min}, \code{Avg}, \code{Max} fields
#'   \item Sleep: nested fields (totalSleep, core, deep, rem, awake, etc.)
#' }
#'
#' @param metric_obj A list from the parsed JSON (one element of
#'   \code{data$metrics}).
#' @return A tibble with columns: \code{date}, \code{metric}, \code{value},
#'   \code{source}.
#' @keywords internal
.parse_metric <- function(metric_obj) {
  name <- metric_obj$name
  samples <- metric_obj$data
  if (length(samples) == 0) return(tibble::tibble())

  if (name == "sleep_analysis") {
    return(.parse_sleep(samples))
  }

  if (name == "heart_rate") {
    return(.parse_heart_rate(samples))
  }

  # Standard qty format
  rows <- lapply(samples, function(s) {
    tibble::tibble(
      date   = as.Date(substr(s$date, 1, 10)),
      metric = name,
      value  = as.numeric(s$qty),
      source = s$source %||% NA_character_
    )
  })
  dplyr::bind_rows(rows)
}

#' Parse heart_rate samples (Min/Avg/Max format)
#' @param samples List of heart rate sample objects
#' @return Tibble in long format with heart_rate_min, _avg, _max metrics
#' @keywords internal
.parse_heart_rate <- function(samples) {
  rows <- lapply(samples, function(s) {
    d <- as.Date(substr(s$date, 1, 10))
    src <- s$source %||% NA_character_
    tibble::tibble(
      date   = rep(d, 3),
      metric = c("heart_rate_min", "heart_rate_avg", "heart_rate_max"),
      value  = c(as.numeric(s$Min), as.numeric(s$Avg), as.numeric(s$Max)),
      source = rep(src, 3)
    )
  })
  dplyr::bind_rows(rows)
}

#' Parse sleep_analysis samples
#'
#' Detects format automatically:
#' \itemize{
#'   \item Aggregated (HAE daily): has \code{totalSleep}, \code{core} etc.
#'   \item Raw segments: has \code{value} with stage names (Kärna, Djup, etc.)
#' }
#'
#' @param samples List of sleep sample objects
#' @return Tibble in long format with sleep_* metrics
#' @keywords internal
.parse_sleep <- function(samples) {
  if (length(samples) == 0) return(tibble::tibble())

  # Detect format: aggregated has "totalSleep", raw has "value"
  first <- samples[[1]]
  if (!is.null(first$totalSleep)) {
    return(.parse_sleep_aggregated(samples))
  }
  if (!is.null(first$value) && is.character(first$value)) {
    return(.parse_sleep_raw(samples))
  }
  warning("Okänt sömnformat — varken aggregerat eller rått")
  tibble::tibble()
}

#' Parse aggregated sleep samples (HAE daily export format)
#' @param samples List of aggregated sleep objects with totalSleep, core, etc.
#' @return Tibble in long format
#' @keywords internal
.parse_sleep_aggregated <- function(samples) {
  sleep_fields <- c("totalSleep", "core", "deep", "rem", "awake", "inBed",
                     "asleep")
  time_fields <- c("sleepStart", "sleepEnd", "inBedStart", "inBedEnd")

  rows <- lapply(samples, function(s) {
    d <- as.Date(substr(s$date, 1, 10))
    src <- s$source %||% NA_character_

    numeric_rows <- lapply(sleep_fields, function(f) {
      val <- s[[f]]
      if (is.null(val)) return(NULL)
      tibble::tibble(
        date = d, metric = paste0("sleep_", f),
        value = as.numeric(val), source = src
      )
    })

    time_rows <- lapply(time_fields, function(f) {
      val <- s[[f]]
      if (is.null(val) || val == "") return(NULL)
      parsed <- lubridate::ymd_hms(val, tz = "Europe/Stockholm", quiet = TRUE)
      if (is.na(parsed)) return(NULL)
      hour_frac <- lubridate::hour(parsed) +
                   lubridate::minute(parsed) / 60 +
                   lubridate::second(parsed) / 3600
      tibble::tibble(
        date = d, metric = paste0("sleep_", f),
        value = hour_frac, source = src
      )
    })

    dplyr::bind_rows(c(numeric_rows, time_rows))
  })
  dplyr::bind_rows(rows)
}

# Map Swedish sleep stage names to metric suffixes
.sleep_stage_map <- c(
  "I s\u00e4ngen" = "inBed",
  "K\u00e4rna"    = "core",
  "Djup"          = "deep",
  "REM"           = "rem",
  "Vaken"         = "awake",
  "Sova"          = "asleep"
)

# Sources ranked by data quality (best first).
# General: Apple Watch for HR, HRV, etc.
.source_priority <- c(
  "Apple Watch f\u00f6r Kristian", "kankad", "kankad ",
  "Oura", "AutoSleep",
  "Sleep Cycle",
  "Health Sync", "Health Import", "Klocka", "anandavani", "Connect"
)

# Sleep: Apple Watch aggregated data is most reliable — Sleep Cycle
# has known bugs (duplicate sessions 2013-2015 giving 22.9h, and
# staging fragments assigned to wrong night giving 0.3h from 2025+).
# SC average is ~0.5h lower than AW but AW is consistently correct.
.sleep_source_priority <- .source_priority

#' Parse raw sleep segment samples into daily summaries
#'
#' Groups segments by night (using end-date), picks the best source per
#' night (preferring Apple Watch staging), and sums hours per stage.
#'
#' @param samples List of raw sleep segment objects with \code{value}
#'   (stage name), \code{qty} (hours), \code{startDate}, \code{endDate}.
#' @return Tibble in long format with sleep_* metrics per day.
#' @keywords internal
.parse_sleep_raw <- function(samples) {
  # Vectorised extraction for performance (96K+ rows)
  n <- length(samples)
  end_dates <- character(n)
  start_dates <- character(n)
  stages <- character(n)
  hours <- numeric(n)
  sources <- character(n)

  for (i in seq_len(n)) {
    s <- samples[[i]]
    end_dates[i]   <- s$endDate %||% s$end %||% s$date %||% ""
    start_dates[i] <- s$startDate %||% s$start %||% s$date %||% ""
    stages[i]      <- s$value %||% ""
    hours[i]       <- as.numeric(s$qty %||% 0)
    sources[i]     <- s$source %||% NA_character_
  }

  # Assign sleep date: segments starting >= 18:00 belong to the NEXT calendar

  # day's sleep (the wake-up date). Without this, pre-midnight segments get
  # assigned to the evening's date, splitting a single night across two days.
  end_date <- as.Date(substr(end_dates, 1, 10))
  start_date <- as.Date(substr(start_dates, 1, 10))
  start_hour <- as.integer(substr(start_dates, 12, 13))
  sleep_date <- dplyr::if_else(start_hour >= 18L, start_date + 1L, end_date)

  df <- tibble::tibble(
    date   = sleep_date,
    stage  = stages,
    hours  = hours,
    source = sources,
    start_ts = start_dates,
    end_ts   = end_dates
  )

  # Map stages to metric names; drop unknown stages
  df$metric_suffix <- .sleep_stage_map[df$stage]
  df <- df[!is.na(df$metric_suffix), ]

  # Deduplicate identical segments (Sleep Cycle often reports duplicates)
  df <- dplyr::distinct(df, date, stage, hours, source, start_ts, end_ts,
                         .keep_all = TRUE)

  # Normalize NBSP (U+00A0) before priority matching — HAE JSON writes
  # "Apple\u00a0Watch" with NBSP but the priority list uses regular space.
  df$source <- gsub("\u00a0", " ", df$source)

  # Source priority: rank each source
  df$src_rank <- match(df$source, .sleep_source_priority)
  df$src_rank[is.na(df$src_rank)] <- length(.sleep_source_priority) + 1L

  # Has staging = source provides Kärna/Djup/REM (not just inBed/asleep)
  staging_suffixes <- c("core", "deep", "rem")

  # Per night: pick source with best staging
  best_source <- df |>
    dplyr::group_by(date, source) |>
    dplyr::summarise(
      has_staging = any(metric_suffix %in% staging_suffixes),
      src_rank = dplyr::first(src_rank),
      .groups = "drop"
    ) |>
    dplyr::group_by(date) |>
    dplyr::arrange(dplyr::desc(has_staging), src_rank) |>
    dplyr::summarise(best_source = dplyr::first(source), .groups = "drop")

  # Filter to best source per night
  df <- df |>
    dplyr::inner_join(best_source, by = "date") |>
    dplyr::filter(source == best_source)

  # For stages with real data (core/deep/REM): sum durations.
  # For "asleep"/"inBed" (pre-staging era): take max per night to avoid
  # double-counting from overlapping Sleep Cycle segments.
  overlap_suffixes <- c("asleep", "inBed")

  stage_totals <- df |>
    dplyr::group_by(date, metric_suffix, source) |>
    dplyr::summarise(
      hours = dplyr::if_else(
        dplyr::first(metric_suffix) %in% overlap_suffixes,
        max(hours, na.rm = TRUE),
        sum(hours, na.rm = TRUE)
      ),
      .groups = "drop"
    )

  # Compute totalSleep = core + deep + rem (when staging available)
  # or inBed (when only Sleep Cycle-era data exists)
  daily <- stage_totals |>
    tidyr::pivot_wider(names_from = metric_suffix, values_from = hours,
                       values_fill = 0)

  # Ensure columns exist
  for (col in c("core", "deep", "rem", "asleep", "inBed")) {
    if (!col %in% names(daily)) daily[[col]] <- 0
  }

  daily <- daily |>
    dplyr::mutate(
      totalSleep = dplyr::case_when(
        core + deep + rem > 0 ~ core + deep + rem,
        asleep > 0            ~ asleep,
        inBed > 0             ~ inBed,
        TRUE                  ~ 0
      )
    )

  # Sleep times: earliest start, latest end per night
  sleep_times <- df |>
    dplyr::filter(metric_suffix != "inBed") |>
    dplyr::group_by(date) |>
    dplyr::summarise(
      sleepStart = min(start_ts),
      sleepEnd   = max(end_ts),
      .groups = "drop"
    )

  bed_times <- df |>
    dplyr::filter(metric_suffix == "inBed") |>
    dplyr::group_by(date) |>
    dplyr::summarise(
      inBedStart = min(start_ts),
      inBedEnd   = max(end_ts),
      .groups = "drop"
    )

  daily <- daily |>
    dplyr::left_join(sleep_times, by = "date") |>
    dplyr::left_join(bed_times, by = "date")

  # Pivot back to long format matching .parse_sleep_aggregated output
  numeric_cols <- intersect(
    c("totalSleep", "core", "deep", "rem", "awake", "inBed", "asleep"),
    names(daily)
  )
  time_cols <- intersect(
    c("sleepStart", "sleepEnd", "inBedStart", "inBedEnd"),
    names(daily)
  )

  numeric_long <- daily |>
    dplyr::select(date, source, dplyr::all_of(numeric_cols)) |>
    tidyr::pivot_longer(cols = dplyr::all_of(numeric_cols),
                        names_to = "field", values_to = "value") |>
    dplyr::mutate(metric = paste0("sleep_", field)) |>
    dplyr::select(date, metric, value, source)

  time_long <- if (length(time_cols) > 0) {
    daily |>
      dplyr::select(date, source, dplyr::all_of(time_cols)) |>
      tidyr::pivot_longer(cols = dplyr::all_of(time_cols),
                          names_to = "field", values_to = "ts") |>
      dplyr::mutate(
        parsed = lubridate::ymd_hms(ts, tz = "Europe/Stockholm", quiet = TRUE),
        value = lubridate::hour(parsed) +
                lubridate::minute(parsed) / 60 +
                lubridate::second(parsed) / 3600,
        metric = paste0("sleep_", field)
      ) |>
      dplyr::filter(!is.na(parsed)) |>
      dplyr::select(date, metric, value, source)
  } else {
    tibble::tibble()
  }

  dplyr::bind_rows(numeric_long, time_long)
}

# --- Source cleaning -----------------------------------------------------------

# Metrics where Garmin Connect values are unreliable when mixed with Apple Watch.
# HAE averages across sources, so "AW | Connect" produces bad aggregates.
.connect_contaminated_metrics <- c("resting_heart_rate")

#' Remove rows contaminated by Garmin Connect source mixing
#'
#' For certain metrics (e.g. resting_heart_rate), HAE daily aggregation
#' averages Apple Watch (~50 bpm) with Garmin Connect (~100 bpm), producing
#' misleading values. This function drops Connect-contaminated rows only when
#' pure Apple Watch data exists for the same (date, metric). When Connect is
#' the only source, it is kept as fallback — imperfect data beats no data.
#'
#' @param df Tibble with columns: date, metric, value, source.
#' @return Filtered tibble.
#' @keywords internal
.clean_sources <- function(df) {
  # Normalize non-breaking spaces (U+00A0) to regular spaces in source names.
  # HAE sometimes writes "Apple\u00a0Watch" with NBSP.
  df$source <- gsub("\u00a0", " ", df$source)

  # Drop Connect-contaminated rows only when pure AW data exists for the
  # same (date, metric). Keep Connect as fallback when AW is absent.
  n_dropped <- 0L
  for (m in .connect_contaminated_metrics) {
    is_metric <- df$metric == m
    is_connect <- is_metric & grepl("Connect", df$source, fixed = TRUE)
    is_pure <- is_metric & !grepl("Connect", df$source, fixed = TRUE)
    dates_with_pure <- unique(df$date[is_pure])
    drop <- is_connect & df$date %in% dates_with_pure
    n_dropped <- n_dropped + sum(drop)
    df <- df[!drop, ]
  }
  if (n_dropped > 0) {
    message("  Filtrerade bort ", n_dropped,
            " Connect-kontaminerade värden (ren AW-data fanns)")
  }

  # Drop implausible sleep values:
  # - totalSleep > 16 h (SC duplicate sessions, 2013-2015)
  # - totalSleep < 2 h when inBed > 4 h (SC lost contact during night)
  is_total <- df$metric == "sleep_totalSleep"
  if (any(is_total)) {
    # Check for matching inBed values on same date/source
    inbed_lookup <- df[df$metric == "sleep_inBed",
                       c("date", "source", "value")]
    names(inbed_lookup)[3] <- "inbed_val"
    total_df <- df[is_total, c("date", "source", "value")]
    merged <- merge(total_df, inbed_lookup, by = c("date", "source"),
                    all.x = TRUE)
    too_long <- is_total & df$value > 16
    too_short <- is_total &
      df$value < 2 &
      df$date %in% merged$date[!is.na(merged$inbed_val) & merged$inbed_val > 4]

    n_sleep_dropped <- sum(too_long | too_short)
    if (n_sleep_dropped > 0) {
      # Drop all sleep_* metrics for these (date, source) pairs
      bad_keys <- paste(df$date[too_long | too_short],
                        df$source[too_long | too_short])
      is_bad_sleep <- grepl("^sleep_", df$metric) &
        paste(df$date, df$source) %in% bad_keys
      message("  Filtrerade bort ", sum(is_bad_sleep),
              " rader fr\u00e5n ", n_sleep_dropped,
              " orimliga s\u00f6mnn\u00e4tter (>16h eller <2h med >4h i s\u00e4ngen)")
      df <- df[!is_bad_sleep, ]
    }
  }

  df
}

# --- Daily aggregation --------------------------------------------------------

# Metrics that should be summed (accumulated over a day), not averaged.
.sum_metrics <- c(
  "step_count", "active_energy", "basal_energy_burned", "flights_climbed",
  "apple_exercise_time", "apple_stand_time", "apple_stand_hour",
  "walking_running_distance", "cycling_distance", "mindful_minutes",
  "time_in_daylight"
)

# Metrics where daily minimum is the correct aggregate.
# Resting HR: the lowest reading represents true resting state;
# later readings are inflated by activity, caffeine, stress etc.
.min_metrics <- c("resting_heart_rate")

#' Aggregate non-aggregated health data to daily values
#'
#' When HAE exports raw (non-aggregated) data, there may be multiple
#' samples per day per metric. This function reduces them to one value
#' per day: sum for accumulative metrics, min for resting heart rate
#' (true resting state), mean for everything else.
#' Heart rate min/max use min/max respectively.
#'
#' @param df Tibble with columns: date, metric, value, source.
#' @return Tibble with one row per (date, metric).
#' @keywords internal
.aggregate_daily <- function(df) {
  df |>
    dplyr::group_by(date, metric) |>
    dplyr::summarise(
      value = dplyr::case_when(
        dplyr::first(metric) %in% .sum_metrics ~ sum(value, na.rm = TRUE),
        dplyr::first(metric) %in% .min_metrics ~ min(value, na.rm = TRUE),
        dplyr::first(metric) == "heart_rate_min" ~ min(value, na.rm = TRUE),
        dplyr::first(metric) == "heart_rate_max" ~ max(value, na.rm = TRUE),
        .default = mean(value, na.rm = TRUE)
      ),
      source = dplyr::first(source),
      .groups = "drop"
    )
}

# --- Canonical reader ---------------------------------------------------------

#' Read a canonical per-metric-per-day JSON file
#'
#' Canonical files have the format:
#' \code{{"metric": "...", "date": "...", "units": "...", "samples": [...]}}
#'
#' @param path Path to the canonical JSON file.
#' @param verbose Logical, print progress. Default FALSE.
#' @return A tibble with columns: \code{date}, \code{metric}, \code{value},
#'   \code{source}.
#' @export
read_canonical_file <- function(path, verbose = FALSE) {
  if (!file.exists(path)) stop("Filen finns inte: ", path)

  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)

  # Canonical format: {metric, date, units, samples}
  metric_name <- raw$metric
  samples <- raw$samples
  if (is.null(metric_name) || is.null(samples) || length(samples) == 0) {
    return(tibble::tibble())
  }

  # Sum metrics produce one daily total. Two paths feed it:
  #   1. Fast path: `daily_total` precomputed by the Python writer
  #      (post-2026-05-11 canonical files). Single-row tibble, no
  #      sample parsing.
  #   2. Fallback: older canonical files predate the field. Parse the
  #      samples and aggregate IN THIS FILE — the downstream import
  #      pipeline uses `distinct(date, metric, .keep_all = TRUE)`,
  #      which would otherwise keep a single intra-day sample and
  #      undercount the day. Both paths emit the same shape.
  if (metric_name %in% .sum_metrics) {
    if (!is.null(raw$daily_total) && length(raw$daily_total) == 1) {
      first_src <- if (length(samples)) {
        s <- samples[[1]]$source
        if (is.null(s)) NA_character_ else as.character(s)
      } else NA_character_
      return(tibble::tibble(
        date = as.Date(raw$date),
        metric = metric_name,
        value = as.numeric(raw$daily_total),
        source = first_src
      ))
    }
    metric_obj <- list(name = metric_name, data = samples)
    parsed <- .parse_metric(metric_obj)
    if (nrow(parsed) > 1) {
      parsed <- .aggregate_daily(parsed)
    }
    return(parsed)
  }

  # Non-sum metrics: parse and defer aggregation to the global
  # pipeline (mean / min / max semantics differ per metric).
  metric_obj <- list(name = metric_name, data = samples)
  result <- .parse_metric(metric_obj)

  if (verbose && nrow(result) > 0) {
    cat("  ", basename(dirname(path)), "/", basename(path), ":",
        nrow(result), "rader\n")
  }

  result
}


# --- Main reader --------------------------------------------------------------

#' Read a Health Auto Export JSON file
#'
#' Parses all metrics from a single HAE JSON export and returns a tidy
#' long-format tibble.
#'
#' @param path Path to the JSON file.
#' @param verbose Logical, print progress. Default FALSE.
#' @return A tibble with columns: \code{date} (Date), \code{metric}
#'   (character), \code{value} (numeric), \code{source} (character).
#' @export
read_health_export <- function(path, verbose = FALSE) {
  if (!file.exists(path)) {
    stop("Filen finns inte: ", path)
  }

  if (verbose) cat("Läser", basename(path), "...\n")
  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)

  metrics_list <- raw$data$metrics
  if (is.null(metrics_list)) {
    metrics_list <- raw$metrics
  }
  if (is.null(metrics_list)) {
    stop("Kunde inte hitta metrics i JSON-filen")
  }

  if (verbose) cat("  ", length(metrics_list), "metric-grupper\n")

  parsed <- lapply(metrics_list, function(m) {
    result <- tryCatch(
      .parse_metric(m),
      error = function(e) {
        warning("Kunde inte parsa '", m$name, "': ", conditionMessage(e),
                call. = FALSE)
        tibble::tibble()
      }
    )
    if (verbose && nrow(result) > 0) {
      cat("  ", m$name, ":", nrow(result), "rader\n")
    }
    result
  })

  result <- dplyr::bind_rows(parsed)
  result <- .clean_sources(result)

  # Detect non-aggregated data: multiple samples per (date, metric)
  dup_count <- result |>
    dplyr::count(date, metric) |>
    dplyr::filter(n > 1) |>
    nrow()

  if (dup_count > 0) {
    if (verbose) cat("  Aggregerar", dup_count, "duplicerade dag/metric-par\n")
    result <- .aggregate_daily(result)
  }

  result
}

# --- Import pipeline ----------------------------------------------------------

#' Import health export data with deduplication
#'
#' Reads all JSON files in the health_export/metrics/ directory (or a
#' specified file), merges with previously cached data, deduplicates on
#' (date, metric), and saves the result.
#'
#' Uses a file manifest to track which files have been imported and their
#' mtime/size. Only new or modified files are re-parsed, making repeated
#' imports fast (skips unchanged files).
#'
#' @param path Optional path to a specific JSON file. If NULL, reads all
#'   JSON files in the health_export/metrics/ directory.
#' @param cache_path Optional path to the RData cache. Defaults to
#'   \code{$TRANING_DATA/cache/health_daily.RData}.
#' @param force Logical, re-import all files regardless of manifest.
#'   Default FALSE.
#' @param save Logical, save to cache after import. Default TRUE.
#' @param verbose Logical, print progress. Default TRUE.
#' @return A tibble of all health data (long format), invisibly.
#' @export
import_health_export <- function(path = NULL, cache_path = NULL,
                                  force = FALSE, save = TRUE,
                                  verbose = TRUE) {
  if (is.null(cache_path)) cache_path <- .hae_cache_path()

  # Load existing cache
  existing <- load_health_data(cache_path)
  if (verbose && nrow(existing) > 0) {
    cat("Cache:", nrow(existing), "rader,",
        length(unique(existing$metric)), "metrics,",
        as.character(min(existing$date)), "till",
        as.character(max(existing$date)), "\n")
  }

  # Find files to import — prefer canonical/ if it exists, else metrics/
  canonical_dir <- file.path(.hae_dir(), "canonical")
  use_canonical <- is.null(path) && dir.exists(canonical_dir)

  if (is.null(path)) {
    if (use_canonical) {
      canonical_files <- list.files(canonical_dir, pattern = "\\.json$",
                                     full.names = TRUE, recursive = TRUE)
      # Also include legacy metrics/ files (sleep spans midnight,
      # kept in legacy format)
      metrics_dir <- file.path(.hae_dir(), "metrics")
      legacy_files <- if (dir.exists(metrics_dir)) {
        list.files(metrics_dir, pattern = "\\.json$",
                   full.names = TRUE, recursive = FALSE)
      } else character(0)
      files <- c(canonical_files, legacy_files)
      if (verbose) cat("Importerar fr\u00e5n canonical/ (", length(canonical_files),
                       ") + metrics/ (", length(legacy_files), ")\n")
    } else {
      metrics_dir <- file.path(.hae_dir(), "metrics")
      files <- list.files(metrics_dir, pattern = "\\.json$",
                          full.names = TRUE, recursive = FALSE)
    }
    if (length(files) == 0) {
      cat("Inga JSON-filer att importera\n")
      return(invisible(existing))
    }
  } else {
    files <- path
  }

  # Skip the manifest entirely when we're not going to save (no point
  # reading it, and the default path requires TRANING_DATA which the
  # caller may not have set). Otherwise load it once and reuse at save
  # time so that single-file or forced runs don't overwrite entries for
  # files they didn't touch. .load_manifest() already tolerates corrupt
  # JSON and wrong-shape values; it returns list() in those cases.
  existing_manifest <- if (save) .load_manifest() else list()
  # Use the manifest to filter only when we're doing an unforced full sweep.
  manifest <- if (is.null(path) && !force) existing_manifest else list()
  if (length(manifest) > 0) {
    files_to_parse <- .filter_changed_files(files, manifest)
    n_skipped <- length(files) - length(files_to_parse)
    if (verbose) {
      cat(length(files), "filer totalt,", n_skipped,
          "oförändrade (hoppar över),", length(files_to_parse), "att importera\n")
    }
    if (length(files_to_parse) == 0) {
      cat("Alla filer redan importerade — inget att göra\n")
      return(invisible(existing))
    }
  } else {
    files_to_parse <- files
    if (verbose) {
      if (force) {
        cat("Tvångsimport:", length(files_to_parse), "fil(er)\n")
      } else {
        cat("Importerar", length(files_to_parse), "fil(er)\n")
      }
    }
  }

  # Filter to actively used metrics (canonical files only; legacy always kept)
  n_before_filter <- length(files_to_parse)
  files_to_parse <- Filter(function(f) {
    if (!grepl("/canonical/", f, fixed = TRUE)) return(TRUE)
    basename(dirname(f)) %in% .import_metrics
  }, files_to_parse)
  n_filtered <- n_before_filter - length(files_to_parse)
  if (verbose && n_filtered > 0) {
    cat(n_filtered, "filer filtrerade (oanv\u00e4nda metrics)\n")
  }

  new_data <- lapply(files_to_parse, function(f) {
    if (grepl("/canonical/", f, fixed = TRUE)) {
      read_canonical_file(f, verbose = verbose)
    } else {
      read_health_export(f, verbose = verbose)
    }
  })
  new_data <- dplyr::bind_rows(new_data)

  if (nrow(new_data) == 0) {
    cat("Inga nya data\n")
    # We still need to refresh the manifest. Two reasons we get here with
    # candidates outstanding:
    #   1. Files were considered (md5 changed against manifest) but parsed
    #      to zero rows.
    #   2. The .import_metrics filter just above reduced files_to_parse to
    #      zero — in that case files_to_parse is empty but `files` still
    #      lists everything we evaluated. Use `files` to gate the save so
    #      we don't miss this branch (the bug Copilot flagged).
    if (save && length(files) > 0) {
      .save_manifest(
        .compute_manifest_to_save(files, path, existing_manifest)
      )
    }
    return(invisible(existing))
  }

  # Merge: new_data first so fresher values win when source rank is tied
  combined <- dplyr::bind_rows(new_data, existing)
  combined <- .clean_sources(combined)
  # Rank sources: Apple Watch preferred for both sleep and general metrics.
  is_sleep <- grepl("^sleep_", combined$metric)
  combined$.src_rank <- NA_integer_
  combined$.src_rank[is_sleep] <- match(
    combined$source[is_sleep], .sleep_source_priority)
  combined$.src_rank[!is_sleep] <- match(
    combined$source[!is_sleep], .source_priority)
  combined$.src_rank[is.na(combined$.src_rank)] <- 99L
  health_daily <- combined |>
    dplyr::arrange(date, metric, .src_rank) |>
    dplyr::distinct(date, metric, .keep_all = TRUE) |>
    dplyr::select(-".src_rank")

  # Filter to actively used metrics (legacy files may bring in extras)
  all_sleep <- grepl("^sleep_", health_daily$metric)
  keep <- health_daily$metric %in% .import_metrics | all_sleep
  n_dropped <- sum(!keep)
  if (n_dropped > 0 && verbose) {
    cat("Filtrerade bort", n_dropped, "rader (oanv\u00e4nda metrics)\n")
  }
  health_daily <- health_daily[keep, ]

  n_new <- nrow(health_daily) - nrow(existing)
  if (verbose) {
    cat("Resultat:", nrow(health_daily), "rader",
        "(", n_new, "nya)\n")
    cat("Period:", as.character(min(health_daily$date)), "till",
        as.character(max(health_daily$date)), "\n")
    cat("Metrics:", length(unique(health_daily$metric)), "\n")
  }

  if (save) {
    save_health_data(health_daily, cache_path)
    if (verbose) cat("Sparad:", cache_path, "\n")

    # Update manifest using the same rule applied at every exit path —
    # see .compute_manifest_to_save() for the policy.
    .save_manifest(
      .compute_manifest_to_save(files, path, existing_manifest)
    )
    if (verbose) cat("Manifest uppdaterad\n")
  }

  invisible(health_daily)
}

# --- Cache I/O ----------------------------------------------------------------

#' Load cached health data
#'
#' @param cache_path Path to RData file. Defaults to
#'   \code{$TRANING_DATA/cache/health_daily.RData}.
#' @return A tibble (empty tibble if cache doesn't exist).
#' @export
load_health_data <- function(cache_path = NULL) {
  if (is.null(cache_path)) cache_path <- .hae_cache_path()
  if (!file.exists(cache_path)) {
    return(tibble::tibble(
      date   = as.Date(character()),
      metric = character(),
      value  = numeric(),
      source = character()
    ))
  }
  load(cache_path)
  health_daily
}

#' Save health data to cache
#'
#' @param health_daily Tibble of health data.
#' @param cache_path Path to RData file.
#' @export
save_health_data <- function(health_daily, cache_path = NULL) {
  if (is.null(cache_path)) cache_path <- .hae_cache_path()
  cache_dir <- dirname(cache_path)
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  save_atomic(health_daily, file = cache_path)
}

# --- Convenience accessors ----------------------------------------------------

#' Pivot health data to wide format (one row per date)
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param metrics Character vector of metric names to include. NULL = all.
#' @return A wide tibble with one row per date and one column per metric.
#' @export
pivot_health_wide <- function(health_daily, metrics = NULL) {
  if (!is.null(metrics)) {
    health_daily <- health_daily |>
      dplyr::filter(metric %in% metrics)
  }
  health_daily |>
    dplyr::select(date, metric, value) |>
    tidyr::pivot_wider(names_from = metric, values_from = value)
}

#' Get readiness metrics for a date range
#'
#' Returns daily values for the core readiness metrics: resting HR,
#' HRV (as Ln RMSSD), sleep total, and sleep deep.
#'
#' @param health_daily Long-format tibble from \code{import_health_export()}.
#' @param after Start date (inclusive). NULL = no lower bound.
#' @param before End date (inclusive). NULL = no upper bound.
#' @return A wide tibble with readiness metrics per day.
#' @export
get_readiness <- function(health_daily, after = NULL, before = NULL) {
  readiness_metrics <- c("resting_heart_rate", "heart_rate_variability",
                          "sleep_totalSleep", "sleep_deep", "sleep_rem",
                          "sleep_core", "sleep_awake",
                          "blood_oxygen_saturation", "respiratory_rate",
                          "apple_sleeping_wrist_temperature")

  df <- health_daily |>
    dplyr::filter(metric %in% readiness_metrics)

  if (!is.null(after))  df <- df |> dplyr::filter(date >= as.Date(after))
  if (!is.null(before)) df <- df |> dplyr::filter(date <= as.Date(before))

  wide <- df |>
    dplyr::select(date, metric, value) |>
    tidyr::pivot_wider(names_from = metric, values_from = value) |>
    dplyr::arrange(date)

  # Add Ln(RMSSD) if HRV is present
  if ("heart_rate_variability" %in% names(wide)) {
    wide <- wide |>
      dplyr::mutate(ln_rmssd = log(heart_rate_variability))
  }

  wide
}

# --- Import metric filter ----------------------------------------------------
# Only these metrics are parsed into health_daily.RData. Canonical files
# for all metrics remain on disk — add a metric here and run
# --import-health --force to include it in the cache.
.import_metrics <- c(
  # Readiness core (tier 2)
  "resting_heart_rate", "heart_rate_variability",
  "sleep_totalSleep", "sleep_deep",
  # Sleep stages (used by get_readiness, plot_health, Shiny)
  "sleep_rem", "sleep_core", "sleep_awake",
  # Rare / high signal (tier 1)
  "vo2_max", "blood_oxygen_saturation", "cardio_recovery",
  "respiratory_rate", "apple_sleeping_wrist_temperature",
  "running_ground_contact_time", "running_power", "running_speed",
  "running_stride_length", "running_vertical_oscillation",
  # Activity — daily totals from the canonical `daily_total` fast-path.
  # active_energy and walking_running_distance used to be excluded
  # because parsing their 1000+ intra-day samples per day was too
  # expensive; the fast-path in read_canonical_file() makes inclusion
  # near-free for files written by the post-2026-05-11 storage layer.
  "step_count", "active_energy", "walking_running_distance",
  # Body composition
  "weight_body_mass"
)

# --- Delta-based insight ----------------------------------------------------

# Tier 1: rare metrics — always report any change
.tier1_metrics <- c(
  "vo2_max", "blood_oxygen_saturation",
  "respiratory_rate", "apple_sleeping_wrist_temperature"
)

# Workout-only metrics — recorded by the watch during a session, not daily
# values. They belong to a per-session insight, not to the daily health
# digest. health_insight_delta() skips these; future workout-insight code
# can surface them. Labels/units below are kept for that future use.
.pass_metrics <- c(
  "cardio_recovery",
  "running_ground_contact_time", "running_power", "running_speed",
  "running_stride_length", "running_vertical_oscillation"
)

# Tier 2: daily metrics — report if significant vs 7d average
.tier2_thresholds <- list(
  heart_rate_variability = 5,    # ms
  resting_heart_rate     = 4,    # bpm
  sleep_totalSleep       = 0.5,  # hours
  sleep_deep             = 0.3   # hours
)

# Tier 3: high-frequency, low-insight — never report
.tier3_metrics <- c(
  "step_count", "active_energy", "basal_energy_burned", "flights_climbed",
  "apple_exercise_time", "walking_running_distance", "heart_rate",
  "heart_rate_min", "heart_rate_avg", "heart_rate_max",
  "environmental_audio_exposure", "headphone_audio_exposure",
  "physical_effort", "apple_stand_hour", "apple_stand_time",
  "stair_speed_up", "stair_speed_down", "time_in_daylight",
  "walking_speed", "walking_step_length",
  "walking_asymmetry_percentage", "walking_double_support_percentage",
  "walking_heart_rate_average",
  # Nutritional
  "dietary_energy", "dietary_sugar", "dietary_water", "protein",
  "carbohydrates", "total_fat", "fiber", "saturated_fat",
  "monounsaturated_fat", "polyunsaturated_fat", "sodium", "potassium",
  "calcium", "iron", "zinc", "magnesium", "manganese", "copper",
  "phosphorus", "selenium", "iodine", "caffeine",
  "vitamin_a", "vitamin_b6", "vitamin_c", "vitamin_e", "vitamin_k",
  "folate", "niacin", "riboflavin", "thiamin", "pantothenic_acid",
  # Other low-signal
  "body_fat_percentage", "body_mass_index", "lean_body_mass",
  "weight_body_mass", "height", "handwashing",
  "mindful_minutes", "number_of_times_fallen",
  "cycling_distance", "swimming_distance", "swimming_stroke_count",
  "distance_downhill_snow_sports", "six_minute_walking_test_distance",
  # Sleep sub-metrics (total and deep handled in tier 2)
  "sleep_rem", "sleep_core", "sleep_awake", "sleep_inBed",
  "sleep_asleep", "sleep_inBedStart", "sleep_inBedEnd",
  "sleep_sleepStart", "sleep_sleepEnd", "sleep_analysis",
  "basal_body_temperature"
)

# Human-readable labels for metrics (Swedish)
.metric_labels <- c(
  heart_rate_variability           = "HRV",
  resting_heart_rate               = "vila",
  sleep_totalSleep                 = "s\u00f6mn",
  sleep_deep                       = "djups\u00f6mn",
  vo2_max                          = "VO2max",
  blood_oxygen_saturation          = "SpO2",
  cardio_recovery                  = "cardio recovery",
  respiratory_rate                 = "andningsfrekvens",
  apple_sleeping_wrist_temperature = "handledstemperatur",
  running_ground_contact_time      = "markkontakt",
  running_power                    = "l\u00f6peffekt",
  running_speed                    = "l\u00f6phastighet",
  running_stride_length            = "stegl\u00e4ngd",
  running_vertical_oscillation     = "vertikal oscillation"
)

# Units for metrics
.metric_units <- c(
  heart_rate_variability           = "ms",
  resting_heart_rate               = "bpm",
  sleep_totalSleep                 = "h",
  sleep_deep                       = "h",
  vo2_max                          = "",
  blood_oxygen_saturation          = "%",
  cardio_recovery                  = "bpm",
  respiratory_rate                 = "/min",
  apple_sleeping_wrist_temperature = "\u00b0C",
  running_ground_contact_time      = "ms",
  running_power                    = "W",
  running_speed                    = "m/s",
  running_stride_length            = "m",
  running_vertical_oscillation     = "cm"
)


#' Generate delta-based health insight text
#'
#' Compares before/after health data tibbles and produces Swedish-language
#' insight text about meaningful changes only.
#'
#' @param before Tibble of health data before import (long format:
#'   date, metric, value, source).
#' @param after Same format, after import.
#' @return Character string. Empty string if no meaningful changes.
#' @export
health_insight_delta <- function(before, after) {
  if (is.null(after) || nrow(after) == 0) return("")

  # Find changed (date, metric) pairs
  after_key <- after |>
    dplyr::select(date, metric, value)
  before_key <- if (nrow(before) > 0) {
    before |> dplyr::select(date, metric, value)
  } else {
    tibble::tibble(date = as.Date(character()), metric = character(),
                   value = numeric())
  }

  changed <- dplyr::anti_join(after_key, before_key,
                               by = c("date", "metric", "value"))
  if (nrow(changed) == 0) return("")

  # Focus on latest date

  focus_date <- max(changed$date)
  changed <- changed |> dplyr::filter(date == focus_date)

  parts <- character()

  for (i in seq_len(nrow(changed))) {
    m <- changed$metric[i]
    v <- changed$value[i]

    # Tier 3 and per-session metrics: skip
    if (m %in% .tier3_metrics) next
    if (m %in% .pass_metrics) next

    label <- if (m %in% names(.metric_labels)) .metric_labels[[m]] else m
    unit  <- if (m %in% names(.metric_units)) .metric_units[[m]] else ""
    unit_str <- if (nzchar(unit)) paste0(" ", unit) else ""

    if (m %in% .tier1_metrics) {
      # Tier 1: always report
      parts <- c(parts, paste0(label, " ", round(v, 1), unit_str))
    } else if (m %in% names(.tier2_thresholds)) {
      # Tier 2: compare against 7d rolling average from before
      threshold <- .tier2_thresholds[[m]]
      hist_vals <- before |>
        dplyr::filter(
          metric == m,
          date >= focus_date - 7,
          date < focus_date
        ) |>
        dplyr::pull(value)

      avg7d <- if (length(hist_vals) >= 2) mean(hist_vals, na.rm = TRUE) else NA

      # Sleep < 5.5h always flags
      if (m == "sleep_totalSleep" && !is.na(v) && v < 5.5) {
        parts <- c(parts, paste0(label, " ", round(v, 1), unit_str,
                                  " (kort natt)"))
        next
      }

      if (!is.na(avg7d)) {
        delta <- v - avg7d
        if (abs(delta) >= threshold) {
          sign_str <- if (delta > 0) "+" else ""
          parts <- c(parts, paste0(label, " ", round(v, 1), unit_str,
                                    " (", sign_str, round(delta, 1),
                                    " vs 7d)"))
        }
      } else {
        # No history — report as new
        parts <- c(parts, paste0(label, " ", round(v, 1), unit_str))
      }
    } else {
      # Unknown metric (not in any tier) — treat as tier 1
      parts <- c(parts, paste0(label, " ", round(v, 1), unit_str))
    }
  }

  if (length(parts) == 0) return("")

  date_str <- format(focus_date, "%e %b") |> trimws()
  paste0("H\u00e4lsa ", date_str, ": ", paste(parts, collapse = ", "))
}


# --- Tillst\u00e5nds-baserad insight (state notification) -------------------------

# Component spec used by the readiness/update insight functions:
# label  = Swedish text
# unit   = printed unit (no leading space)
# fmt    = sprintf format for the numeric value
# baseline_label = "vs 7d" / "vs normalt" / etc., printed alongside the delta
.readiness_components <- list(
  hrv = list(
    label_neg = "svag HRV", label_pos = "stark HRV", label_ok = "HRV",
    unit = "ms", fmt = "%.0f", baseline_label = "vs 7d"
  ),
  sleep = list(
    label_neg = "kort s\u00f6mn", label_pos = "bra s\u00f6mn", label_ok = "s\u00f6mn",
    unit = "h", fmt = "%.1f", baseline_label = "vs normalt"
  ),
  rhr = list(
    label_neg = "f\u00f6rh\u00f6jd vilopuls", label_pos = "l\u00e5g vilopuls", label_ok = "vilopuls",
    unit = "bpm", fmt = "%.0f", baseline_label = "vs baseline"
  ),
  load = list(
    label_neg = "h\u00f6g belastning", label_pos = "l\u00e5g belastning", label_ok = "belastning",
    unit = "", fmt = "%.1f", baseline_label = "TSB"
  ),
  wrist_temp = list(
    label_neg = "f\u00f6rh\u00f6jd handledstemp", label_pos = "l\u00e5g handledstemp",
    label_ok = "handledstemp",
    unit = "\u00b0C", fmt = "%.1f", baseline_label = "vs 14d"
  )
)

#' Pull today's readiness row + raw-value baselines for prose rendering
#'
#' Internal helper. Takes the same inputs as compute_readiness() but augments
#' the latest day with raw HRV (ms) and a 7d HRV-ms baseline, plus the raw
#' sleep 7d baseline. Returns NULL if no readiness row can be produced.
#'
#' @keywords internal
.readiness_for_insight <- function(health_daily, summaries, on_date = NULL,
                                    hr_max = NULL, hr_rest = NULL) {
  if (is.null(health_daily) || nrow(health_daily) == 0) return(NULL)
  r <- tryCatch(
    compute_readiness(health_daily, summaries,
                       hr_max = hr_max, hr_rest = hr_rest),
    error = function(e) NULL
  )
  if (is.null(r) || nrow(r) == 0) return(NULL)

  if (is.null(on_date)) on_date <- max(r$date)
  on_date <- as.Date(on_date)
  row <- r[r$date == on_date, , drop = FALSE]
  if (nrow(row) == 0) return(NULL)

  # Raw HRV in ms (prose uses ms, not ln_rmssd)
  hrv_today <- health_daily |>
    dplyr::filter(metric == "heart_rate_variability", date == on_date) |>
    dplyr::pull(value)
  hrv_today <- if (length(hrv_today) >= 1) mean(hrv_today, na.rm = TRUE) else NA_real_

  hrv_7d <- health_daily |>
    dplyr::filter(metric == "heart_rate_variability",
                  date >= on_date - 7, date < on_date) |>
    dplyr::pull(value)
  hrv_7d_mean <- if (length(hrv_7d) >= 2) mean(hrv_7d, na.rm = TRUE) else NA_real_

  # Raw sleep 7d mean
  sleep_7d <- health_daily |>
    dplyr::filter(metric == "sleep_totalSleep",
                  date >= on_date - 7, date < on_date) |>
    dplyr::pull(value)
  sleep_7d_mean <- if (length(sleep_7d) >= 2) mean(sleep_7d, na.rm = TRUE) else NA_real_

  list(
    row = row,
    hrv_ms = hrv_today,
    hrv_ms_7d = hrv_7d_mean,
    sleep_7d = sleep_7d_mean
  )
}

#' Build component summary for prose rendering
#'
#' @keywords internal
.readiness_component_summary <- function(ctx) {
  row <- ctx$row
  list(
    hrv = list(
      value = if (is.finite(ctx$hrv_ms)) round(ctx$hrv_ms, 0) else NA_real_,
      delta = if (is.finite(ctx$hrv_ms) && is.finite(ctx$hrv_ms_7d))
                round(ctx$hrv_ms - ctx$hrv_ms_7d, 0) else NA_real_,
      flag  = isTRUE(row$hrv_flag),
      score = row$hrv_score
    ),
    sleep = list(
      value = if (is.finite(row$sleep_total)) round(row$sleep_total, 1) else NA_real_,
      delta = if (is.finite(row$sleep_total) && is.finite(ctx$sleep_7d))
                round(row$sleep_total - ctx$sleep_7d, 1) else NA_real_,
      flag  = isTRUE(row$sleep_flag),
      score = row$sleep_score
    ),
    rhr = list(
      value = if (is.finite(row$resting_hr)) round(row$resting_hr, 0) else NA_real_,
      delta = if (is.finite(row$rhr_deviation)) round(row$rhr_deviation, 1) else NA_real_,
      flag  = isTRUE(row$rhr_flag),
      score = row$rhr_score
    ),
    load = list(
      value = if (is.finite(row$tsb)) round(row$tsb, 1) else NA_real_,
      delta = NA_real_,
      flag  = isTRUE(row$load_flag),
      score = row$trimp_score
    ),
    wrist_temp = if ("wrist_temp" %in% names(row) && is.finite(row$wrist_temp)) {
      list(
        value = round(row$wrist_temp, 1),
        delta = if (is.finite(row$wrist_temp_deviation))
                  round(row$wrist_temp_deviation, 2) else NA_real_,
        flag  = isTRUE(row$wrist_temp_flag),
        score = row$wrist_temp_score
      )
    } else NULL
  )
}

#' Render one component as Swedish prose with optional delta
#'
#' @keywords internal
.render_component <- function(name, c, kind = c("neg", "pos", "ok")) {
  kind <- match.arg(kind)
  spec <- .readiness_components[[name]]
  if (is.null(spec) || is.null(c) || is.na(c$value)) return(NA_character_)

  # Load: always neutral label unless flagged. "L\u00e5g belastning" can mean rest,
  # which doesn't necessarily warrant a positive callout.
  if (name == "load" && kind != "neg") kind <- "ok"

  # Sleep: the flag fires on absolute hours < 7 AND HRV trending down,
  # but the prose label compares vs personal 7d normal. "kort s\u00f6mn"
  # implies the night deviated downward, so demote to the neutral
  # label whenever the delta-vs-normal signal isn't actually pointing
  # down \u2014 i.e. delta >= 0 (positive OR exactly normal). The flag
  # still keeps the line in "Drar ner".
  if (name == "sleep" && kind == "neg" &&
      !is.na(c$delta) && c$delta >= 0) {
    kind <- "ok"
  }

  label <- spec[[paste0("label_", kind)]]
  unit_str <- if (nzchar(spec$unit)) paste0(" ", spec$unit) else ""
  val_str <- sprintf(spec$fmt, c$value)

  if (name == "load") {
    sign_str <- if (!is.na(c$value) && c$value > 0) "+" else ""
    return(paste0(label, " (", spec$baseline_label, " ", sign_str, val_str, ")"))
  }

  # Drop the "vs Xd" suffix when delta rounds to zero \u2014 adds no information
  delta_meaningful <- !is.na(c$delta) &&
    abs(c$delta) >= switch(name, hrv = 1, sleep = 0.1, rhr = 0.5,
                            wrist_temp = 0.05, 0)
  if (delta_meaningful) {
    sign_str <- if (c$delta > 0) "+" else ""
    paste0(label, " (", val_str, unit_str, ", ", sign_str,
           sprintf(spec$fmt, c$delta), " ", spec$baseline_label, ")")
  } else {
    paste0(label, " (", val_str, unit_str, ")")
  }
}

# --- Sport activity helpers for notification prose --------------------------
# These produce the per-sport summary lines that are appended to the daily
# readiness prose ("Senaste dygnet:" + the Sunday weekly recap). Helpers
# return NULL when there's nothing useful to say so callers can omit the
# line silently.

# Recent sport activity within `hours` of `on_date`. Returns a data frame
# of (sport, sessions, km) ordered by km descending, or NULL if no rows
# pass the per-sport distance threshold (>= 0.1 km).  Distance-less
# sports (gym/strength rows that have sessions but no kilometres) are
# dropped — listing "styrketräning 0.0 km" in the push reads as noise.
.recent_sport_activity <- function(summaries, on_date, hours = 24L) {
  if (is.null(summaries) || !is.data.frame(summaries) || nrow(summaries) == 0)
    return(NULL)
  if (!all(c("sport", "sessionStart", "distance") %in% names(summaries)))
    return(NULL)
  end_ts   <- as.POSIXct(as.character(on_date),
                          format = "%Y-%m-%d", tz = "UTC") +
              as.difftime(1, units = "days")
  start_ts <- end_ts - as.difftime(hours, units = "hours")

  recent <- summaries[
    !is.na(summaries$sessionStart) &
      summaries$sessionStart >= start_ts &
      summaries$sessionStart <  end_ts &
      !is.na(summaries$sport),
    , drop = FALSE
  ]
  if (nrow(recent) == 0) return(NULL)

  agg <- by(recent, recent$sport, function(d) {
    data.frame(
      sport    = d$sport[1],
      sessions = nrow(d),
      km       = sum(as.numeric(d$distance), na.rm = TRUE) / 1000,
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, agg)
  out <- out[!is.na(out$km) & out$km >= 0.1, , drop = FALSE]
  if (nrow(out) == 0) return(NULL)
  rownames(out) <- NULL
  out[order(-out$km), , drop = FALSE]
}

# Same shape as .recent_sport_activity but for an ISO calendar week.
# `week_offset = 0` is the week containing on_date, `-1` is the previous
# week, etc. Returns a list with `iso_week`, `total_km`, `total_trimp`
# (multi-sport HR-based weekly load), and a per-sport data frame
# (zero-rows when no sessions reached the 0.1 km floor).
.weekly_sport_aggregate <- function(summaries, on_date, week_offset = 0L) {
  if (is.null(summaries) || !is.data.frame(summaries) || nrow(summaries) == 0)
    return(NULL)
  ref <- as.Date(on_date) + (week_offset * 7L)
  # ISO week: Monday start. as.POSIXlt$wday returns 0 (Sun) .. 6 (Sat).
  wday <- as.POSIXlt(ref)$wday
  monday_offset <- if (wday == 0L) 6L else (wday - 1L)
  monday <- ref - monday_offset
  end_ts   <- as.POSIXct(as.character(monday + 7L),
                          format = "%Y-%m-%d", tz = "UTC")
  start_ts <- as.POSIXct(as.character(monday),
                          format = "%Y-%m-%d", tz = "UTC")

  rows <- summaries[
    !is.na(summaries$sessionStart) &
      summaries$sessionStart >= start_ts &
      summaries$sessionStart <  end_ts &
      !is.na(summaries$sport),
    , drop = FALSE
  ]
  if (nrow(rows) == 0) {
    return(list(
      iso_week    = format(monday, "%G-W%V"),
      total_km    = 0,
      total_trimp = NA_real_,
      per_sport   = data.frame(sport = character(0), sessions = integer(0),
                                km = numeric(0), stringsAsFactors = FALSE)
    ))
  }
  agg <- by(rows, rows$sport, function(d) {
    data.frame(
      sport    = d$sport[1],
      sessions = nrow(d),
      km       = sum(as.numeric(d$distance), na.rm = TRUE) / 1000,
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, agg)
  # Drop zero-distance sports so they don't inflate the "över N sporter"
  # count or render as "styrketräning 0.0 km".
  out <- out[!is.na(out$km) & out$km >= 0.1, , drop = FALSE]
  rownames(out) <- NULL
  out <- out[order(-out$km), , drop = FALSE]

  # Use the same HR_max scope as compute_trimp's multi-sport default
  # and .sport_mix_data() — "all" — so the weekly recap, the readiness
  # PMC and the sport-mix plot all read TRIMP off the same scale.
  # .session_trimp() is the shared Banister implementation; sum returns
  # 0 on an all-NA vector so we check before summing.
  hr_max <- tryCatch(get_hr_max(summaries, sport = "all"),
                     error = function(e) NA_real_)
  trimp_vec <- if (is.finite(hr_max) && hr_max > 0)
    .session_trimp(rows, hr_max = hr_max) else NA_real_
  total_trimp <- if (any(!is.na(trimp_vec)))
    sum(trimp_vec, na.rm = TRUE) else NA_real_

  list(
    iso_week    = format(monday, "%G-W%V"),
    total_km    = sum(out$km),
    total_trimp = total_trimp,
    per_sport   = out
  )
}

# Format a single distance for in-line text (one decimal under 10, integer
# from 10 km).
.fmt_km <- function(km) {
  if (is.na(km)) return("")
  if (km >= 10) format(round(km), big.mark = "")
  else sprintf("%.1f", km)
}

# Build the "Senaste dygnet: löpning 8.1 km, gång 4.2 km." line, or NULL.
.format_recent_activity_line <- function(activity) {
  if (is.null(activity) || nrow(activity) == 0) return(NULL)
  parts <- vapply(seq_len(nrow(activity)), function(i) {
    sport <- tolower(.sport_label_sv(activity$sport[i]))
    paste0(sport, " ", .fmt_km(activity$km[i]), " km")
  }, character(1))
  paste0("Senaste dygnet: ", paste(parts, collapse = ", "), ".")
}

# Extract the ISO week number ("YYYY-WNN" -> "NN", padding stripped)
# for inline references like "mot v.19". Returns NULL when the slot
# is missing or malformed so callers can fall back on neutral wording.
.iso_week_number <- function(iso_week) {
  if (is.null(iso_week) || is.na(iso_week)) return(NULL)
  parts <- strsplit(as.character(iso_week), "W", fixed = TRUE)[[1]]
  if (length(parts) != 2L) return(NULL)
  num <- suppressWarnings(as.integer(parts[2]))
  if (is.na(num)) return(NULL)
  as.character(num)  # drops the leading zero in "05" -> "5"
}

# Build the displayed numbers for one week's recap: a single rounded
# value per sport plus the matching total. Per-sport entries use
# integer rendering above 1 km when the weekly total reaches 10 km
# (keeps "57, 16, 6" from reading as a mixed-precision list), but any
# sub-1 km bucket keeps one-decimal precision so a 0.3 km strength
# session doesn't get rendered as "0" — that would read as no
# activity even though the sport was included. The total is computed
# off the same rendered values so the parts always sum to it, and the
# delta vs the previous week uses these displayed totals for the same
# reason. Returns a list with three numerics-or-strings of equal
# length to per_sport plus a scalar total.
.weekly_recap_display <- function(weekly) {
  per <- weekly$per_sport
  total_km <- weekly$total_km
  if (is.null(per) || nrow(per) == 0) {
    return(list(per_str = character(0), total_num = total_km,
                total_str = .fmt_km(total_km)))
  }
  if (!is.finite(total_km) || total_km < 10) {
    # Under 10 km the line renders one-decimal precision throughout
    # (.fmt_km's rule). Derive the total from the rounded per-sport
    # values so the parts always add up exactly to the displayed total
    # — same contract as the integer-mode branch below.
    per_num <- round(per$km, 1)
    per_str <- vapply(per_num, .fmt_km, character(1))
    total_num <- sum(per_num)
    return(list(per_str = per_str, total_num = total_num,
                total_str = .fmt_km(total_num)))
  }
  use_decimal <- per$km < 1
  per_num <- ifelse(use_decimal, round(per$km, 1), round(per$km))
  # Render each entry individually: vectorised format() picks one
  # precision for the whole vector, which would force "50.0" alongside
  # "0.3" rather than "50" alongside "0.3".
  per_str <- vapply(seq_along(per_num), function(i) {
    if (use_decimal[i]) sprintf("%.1f", per_num[i])
    else format(per_num[i], big.mark = "", trim = TRUE)
  }, character(1))
  total_num <- sum(per_num)
  # If any per-sport entry is sub-1 we render it with one decimal, so
  # the total has to match that precision — otherwise "50.3 km
  # (löpning 50, styrketräning 0.3)" would print as "50 km (...)"
  # and lose the .3 from the sum.
  total_str <- if (any(use_decimal)) sprintf("%.1f", total_num) else
               format(round(total_num), big.mark = "", trim = TRUE)
  list(per_str = per_str, total_num = total_num, total_str = total_str)
}

# Build "Förra veckan: ..." line. `prefix` controls the Swedish header.
# Delta is preferred against TRIMP (intensity-aware load) so a week of
# easy cycling km doesn't outrank a hard running week — falls back to
# km-delta when no HR-anchored TRIMP is available.
.format_weekly_summary_line <- function(weekly, previous = NULL,
                                         prefix = "Förra veckan") {
  if (is.null(weekly) || weekly$total_km < 0.1) return(NULL)
  per <- weekly$per_sport
  n_sports <- nrow(per)
  disp <- .weekly_recap_display(weekly)

  body <- if (n_sports == 1) {
    sport <- tolower(.sport_label_sv(per$sport[1]))
    paste0(disp$total_str, " km ", sport)
  } else if (n_sports == 2) {
    s1 <- tolower(.sport_label_sv(per$sport[1]))
    s2 <- tolower(.sport_label_sv(per$sport[2]))
    paste0(disp$total_str, " km (", s1, " ", disp$per_str[1],
           ", ", s2, " ", disp$per_str[2], ")")
  } else {
    detail <- vapply(seq_len(n_sports), function(i) {
      paste0(tolower(.sport_label_sv(per$sport[i])), " ", disp$per_str[i])
    }, character(1))
    paste0(disp$total_str, " km över ", n_sports, " sporter (",
           paste(detail, collapse = ", "), ")")
  }

  delta_part <- ""
  if (!is.null(previous)) {
    prev_week_num <- .iso_week_number(previous$iso_week)
    prev_label <- if (is.null(prev_week_num)) "veckan innan" else
                  paste0("v.", prev_week_num)

    prev_trimp <- previous$total_trimp
    cur_trimp  <- weekly$total_trimp
    have_trimp <- !is.null(prev_trimp) && !is.null(cur_trimp) &&
                  is.finite(prev_trimp) && is.finite(cur_trimp) &&
                  prev_trimp > 0

    if (have_trimp) {
      pct <- (cur_trimp - prev_trimp) / prev_trimp * 100
      if (abs(pct) >= 5) {
        sign_str <- if (pct > 0) "+" else "-"
        delta_part <- paste0(" ", sign_str, round(abs(pct)),
                              " % belastning mot ", prev_label, ".")
      } else {
        delta_part <- paste0(" Som ", prev_label,
                              " belastningsmässigt.")
      }
    } else if (!is.null(previous$total_km) &&
               is.finite(previous$total_km)) {
      # Compute the delta off the displayed totals so a week that
      # shows as "20 km" doesn't read as "-1.4 km mot v.X" because
      # raw totals (19 vs 20.4) say something different from what
      # the parts add up to.
      prev_disp <- .weekly_recap_display(previous)
      diff_km <- disp$total_num - prev_disp$total_num
      if (abs(diff_km) >= 0.5) {
        sign_str <- if (diff_km > 0) "+" else "-"
        delta_part <- paste0(" ", sign_str, .fmt_km(abs(diff_km)),
                              " km mot ", prev_label, ".")
      } else {
        delta_part <- paste0(" Som ", prev_label, ".")
      }
    }
  }

  paste0(prefix, ": ", body, ".", delta_part)
}

# Monday morning gets the weekly recap of the week that just ended.
# Other days return NULL so we don't spam — Sunday's partial-week recap
# was dropped because the same number changes again on Monday once the
# Sunday session lands, which read as confusing rather than useful.
.weekly_line_for_date <- function(summaries, on_date,
                                   notify_sport = TRUE) {
  if (!isTRUE(notify_sport)) return(NULL)
  wday <- as.POSIXlt(as.Date(on_date))$wday  # 0=Sun, 1=Mon ... 6=Sat
  if (wday != 1L) return(NULL)
  last <- .weekly_sport_aggregate(summaries, on_date, week_offset = -1L)
  prev <- .weekly_sport_aggregate(summaries, on_date, week_offset = -2L)
  .format_weekly_summary_line(last, prev, prefix = "Förra veckan")
}

# Read the opt-out env var once; defaults to "on" for any value other
# than the explicit "false"/"0"/"no" set.
.notify_sport_enabled <- function() {
  v <- tolower(Sys.getenv("TRANING_NOTIFY_SPORT", unset = "true"))
  !v %in% c("false", "0", "no", "off")
}

#' Generate state-based health insight notification
#'
#' Produces Swedish prose describing today's readiness state and the components
#' driving it (good or bad). Output is suitable for a morning notification.
#'
#' @param health_daily Long-format tibble from \code{load_health_data()}.
#' @param summaries Garmin summaries.
#' @param hr_max,hr_rest Optional overrides for HRmax / HRrest.
#' @param on_date Date to render (default = latest in health_daily).
#' @return A list with elements: \code{prosa} (character, possibly ""),
#'   \code{datum} (Date), \code{status} (character), \code{score} (numeric),
#'   \code{kvalitet} (character), \code{components} (named list of per-metric
#'   value/delta/flag/score), \code{components_present} (named logical for
#'   notify-state tracking).
#' @export
health_insight_readiness <- function(health_daily, summaries,
                                      hr_max = NULL, hr_rest = NULL,
                                      on_date = NULL) {
  ctx <- .readiness_for_insight(health_daily, summaries, on_date,
                                 hr_max, hr_rest)
  if (is.null(ctx)) {
    return(list(prosa = "", datum = NA, status = NA_character_,
                score = NA_real_, kvalitet = NA_character_,
                components = list(), components_present = list()))
  }
  row <- ctx$row
  comps <- .readiness_component_summary(ctx)

  status <- row$readiness_status
  score <- if (is.finite(row$readiness_score)) round(row$readiness_score, 0) else NA_real_
  kvalitet <- row$data_quality

  # Header \u2014 "Dagsform <ball> <Status> <score>." (date is implicit; the
  # iPhone push carries its own timestamp). Coloured ball matches the
  # Status word so the state is readable at a glance.
  ball <- switch(status %||% "",
                 "Gr\u00f6n" = "\U0001F7E2",
                 "Gul"  = "\U0001F7E1",
                 "R\u00f6d"  = "\U0001F534",
                 "")
  if (!is.na(status) && !is.na(score)) {
    header <- paste0("Dagsform ", if (nzchar(ball)) paste0(ball, " ") else "",
                      status, " ", score)
    if (isTRUE(kvalitet %in% c("partial", "minimal"))) {
      missing <- character()
      if (is.na(comps$hrv$value))   missing <- c(missing, "HRV")
      if (is.na(comps$sleep$value)) missing <- c(missing, "s\u00f6mn")
      if (is.na(comps$rhr$value))   missing <- c(missing, "vilopuls")
      if (length(missing) > 0) {
        header <- paste0(header, " (", kvalitet, ", ",
                          paste(missing, collapse = "/"), " saknas \u00e4n)")
      } else {
        header <- paste0(header, " (", kvalitet, ")")
      }
    }
    header <- paste0(header, ".")
  } else {
    # No score computable; degrade gracefully
    header <- "Dagsform \u2014 otillr\u00e4ckligt underlag."
  }

  # Drar ner: flagged components
  drar_ner <- character()
  for (name in names(comps)) {
    c <- comps[[name]]
    if (!is.null(c) && isTRUE(c$flag) && !is.na(c$value)) {
      drar_ner <- c(drar_ner, .render_component(name, c, "neg"))
    }
  }

  # OK: present, not-flagged components, ordered by importance
  ok_parts <- character()
  for (name in c("hrv", "sleep", "rhr", "load", "wrist_temp")) {
    c <- comps[[name]]
    if (!is.null(c) && !isTRUE(c$flag) && !is.na(c$value)) {
      kind <- if (!is.na(c$score) && c$score >= 80) "pos" else "ok"
      ok_parts <- c(ok_parts, .render_component(name, c, kind))
    }
  }

  parts <- c(header)
  if (length(drar_ner) > 0)
    parts <- c(parts, paste0("Drar ner: ", paste(drar_ner, collapse = ", "), "."))
  if (length(ok_parts) > 0)
    parts <- c(parts, paste0("OK: ", paste(ok_parts, collapse = ", "), "."))

  # Sport-aware additions: last-24h activity + Sunday/Monday weekly
  # recap. Both are silent when there's nothing useful to say, and
  # opt-out with TRANING_NOTIFY_SPORT=false.
  if (.notify_sport_enabled()) {
    activity_line <- .format_recent_activity_line(
      .recent_sport_activity(summaries, row$date)
    )
    if (!is.null(activity_line)) parts <- c(parts, activity_line)

    weekly_line <- .weekly_line_for_date(summaries, row$date,
                                          notify_sport = TRUE)
    if (!is.null(weekly_line)) parts <- c(parts, weekly_line)
  }

  # Smart insight: at most one prioritized trend line (streak / ACWR /
  # HRV-trend). Opt-out: TRANING_NOTIFY_CONTEXT=false.
  if (.notify_context_enabled()) {
    ctx_line <- .insight_context_line(summaries, health_daily, row$date)
    if (!is.null(ctx_line)) parts <- c(parts, ctx_line)
  }

  prosa <- paste(parts, collapse = " ")

  components_present <- list(
    hrv        = !is.na(comps$hrv$value),
    sleep      = !is.na(comps$sleep$value),
    rhr        = !is.na(comps$rhr$value),
    load       = !is.na(comps$load$value),
    wrist_temp = !is.null(comps$wrist_temp) && !is.na(comps$wrist_temp$value)
  )

  list(
    prosa              = prosa,
    datum              = row$date,
    status             = status,
    score              = score,
    kvalitet           = kvalitet,
    components         = comps,
    components_present = components_present
  )
}

# Tier-1 metric thresholds for afternoon update notifications. Delta is
# computed against the 7d rolling mean; abs(delta) >= threshold triggers.
.tier1_update_thresholds <- list(
  vo2_max                          = 0.5,
  apple_sleeping_wrist_temperature = 0.4,
  respiratory_rate                 = 2,
  blood_oxygen_saturation          = 2
)

#' Determine whether a follow-up notification is warranted
#'
#' Compares today's readiness state against \code{prev_state} (the morning
#' notification snapshot from \code{.notify_state.json}) and decides whether
#' something has materially changed.
#'
#' Triggers (in order):
#' \enumerate{
#'   \item Morning was partial/minimal AND a previously missing component is
#'         now present → re-render today's state.
#'   \item A tier-1 metric (VO2max, wrist temp, respiratory rate, SpO2) has a
#'         new value not yet reported, with abs(delta vs 7d-mean) above
#'         threshold.
#' }
#'
#' Empty string = no notification.
#'
#' @param health_daily Long-format tibble.
#' @param summaries Garmin summaries.
#' @param prev_state List parsed from \code{.notify_state.json} (or NULL).
#' @param hr_max,hr_rest Optional overrides.
#' @param on_date Date to evaluate (default = latest).
#' @return List with \code{prosa} (character, possibly ""),
#'   \code{trigger} (character: "rerender" / "tier1" / ""),
#'   plus the same fields as \code{health_insight_readiness} when re-rendering.
#' @export
health_insight_update <- function(health_daily, summaries, prev_state,
                                   hr_max = NULL, hr_rest = NULL,
                                   on_date = NULL) {
  empty <- list(prosa = "", trigger = "", datum = NA, status = NA_character_,
                score = NA_real_, kvalitet = NA_character_,
                components = list(), components_present = list(),
                tier1_metric = NA_character_)

  if (is.null(prev_state) || is.null(prev_state$date)) return(empty)
  current <- health_insight_readiness(health_daily, summaries,
                                       hr_max, hr_rest, on_date)
  if (is.na(current$datum)) return(empty)

  prev_date <- as.Date(prev_state$date)
  if (current$datum != prev_date) return(empty)  # different day → caller handles

  # --- Trigger 1: re-render after partial morning -------------------------
  was_partial <- isTRUE(prev_state$morning_kvalitet %in% c("partial", "minimal"))
  if (was_partial) {
    prev_present <- prev_state$morning_components %||% list()
    new_keys <- character()
    for (k in names(current$components_present)) {
      now <- isTRUE(current$components_present[[k]])
      then <- isTRUE(prev_present[[k]])
      if (now && !then) new_keys <- c(new_keys, k)
    }
    if (length(new_keys) > 0) {
      added_parts <- character()
      for (k in new_keys) {
        c <- current$components[[k]]
        spec <- .readiness_components[[k]]
        if (!is.null(c) && !is.na(c$value) && !is.null(spec)) {
          unit_str <- if (nzchar(spec$unit)) paste0(" ", spec$unit) else ""
          added_parts <- c(added_parts,
                            paste0(spec$label_ok, " ",
                                   sprintf(spec$fmt, c$value), unit_str))
        }
      }
      transition <- ""
      prev_status <- prev_state$morning_status
      prev_score  <- prev_state$morning_score
      if (!is.null(prev_status) && !is.na(current$status) &&
          length(prev_status) == 1 && !is.na(prev_status)) {
        if (prev_status != current$status ||
            (!is.null(prev_score) && length(prev_score) == 1 &&
             !is.na(prev_score) && abs(prev_score - current$score) >= 5)) {
          transition <- paste0(" ", prev_status, " ", prev_score,
                                " ⇒ ", current$status, " ", current$score, ".")
        } else {
          transition <- paste0(" ", current$status, " ", current$score, ".")
        }
      }
      prosa <- paste0("Dagsform uppdaterad: ",
                      paste(added_parts, collapse = ", "), ".",
                      transition)
      out <- current
      out$prosa <- prosa
      out$trigger <- "rerender"
      out$tier1_metric <- NA_character_
      return(out)
    }
  }

  # --- Trigger 2: tier-1 metric not yet reported --------------------------
  already_sent <- prev_state$afternoon_updates_sent %||% character()
  for (m in names(.tier1_update_thresholds)) {
    if (m %in% already_sent) next
    today <- health_daily |>
      dplyr::filter(metric == m, date == current$datum) |>
      dplyr::pull(value)
    if (length(today) == 0 || all(is.na(today))) next
    val <- mean(today, na.rm = TRUE)
    hist <- health_daily |>
      dplyr::filter(metric == m,
                    date >= current$datum - 7, date < current$datum) |>
      dplyr::pull(value)
    if (length(hist) < 2) next
    avg7d <- mean(hist, na.rm = TRUE)
    delta <- val - avg7d
    if (!is.finite(delta) || abs(delta) < .tier1_update_thresholds[[m]]) next

    label <- if (m %in% names(.metric_labels)) .metric_labels[[m]] else m
    unit  <- if (m %in% names(.metric_units))  .metric_units[[m]]  else ""
    unit_str <- if (nzchar(unit)) paste0(" ", unit) else ""
    sign_str <- if (delta > 0) "+" else ""
    prosa <- paste0(toupper(substr(label, 1, 1)), substr(label, 2, nchar(label)),
                    " ", round(val, 1), unit_str,
                    " (", sign_str, round(delta, 1), " vs 7d).")
    out <- current
    out$prosa <- prosa
    out$trigger <- "tier1"
    out$tier1_metric <- m
    return(out)
  }

  # Nothing to say
  empty$datum <- current$datum
  empty
}

# Null-coalescing helper
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a


# --- Vayu data-inspection helpers --------------------------------------------

#' Recent data dump for the last N hours
#'
#' Returns all health metrics and Garmin sessions in the recent window,
#' plus the last push entries from \code{notifications.jsonl}. Designed for
#' the Vayu MCP \code{get_recent_data} tool — gives the model a structured
#' snapshot of what we know right now.
#'
#' @param health_daily Long-format tibble.
#' @param summaries Garmin summaries.
#' @param hours Window size in hours (default 24).
#' @return A list with: \code{since}, \code{until}, \code{metrics} (named list,
#'   one entry per metric with date/value points), \code{sessions} (data
#'   frame), \code{last_pushes} (data frame from notifications.jsonl, may be
#'   empty).
#' @export
recent_data_dump <- function(health_daily, summaries, hours = 24) {
  now <- Sys.time()
  cutoff_ts <- now - hours * 3600
  cutoff_date <- as.Date(cutoff_ts)

  # Health metrics — date-resolution only (not timestamped per row)
  recent_h <- health_daily |>
    dplyr::filter(date >= cutoff_date) |>
    dplyr::arrange(metric, date)
  metrics <- list()
  if (nrow(recent_h) > 0) {
    by_metric <- split(recent_h[, c("date", "value")], recent_h$metric)
    for (m in names(by_metric)) {
      df <- by_metric[[m]]
      metrics[[m]] <- list(
        date  = format(df$date, "%Y-%m-%d"),
        value = round(df$value, 3)
      )
    }
  }

  # Sessions — sessionStart is timestamped
  sess_cols <- c("sessionStart", "sport", "duration", "distance",
                 "avgPace", "avgHeartRate")
  available <- intersect(sess_cols, names(summaries))
  sessions <- summaries
  if ("sessionStart" %in% names(sessions)) {
    sessions <- sessions[as.POSIXct(sessions$sessionStart) >= cutoff_ts, ,
                          drop = FALSE]
    if (length(available) > 0 && nrow(sessions) > 0) {
      sessions <- sessions[, available, drop = FALSE]
    }
  } else {
    sessions <- sessions[0, , drop = FALSE]
  }
  # difftime columns (e.g. duration, avgPace from trackeR) don't serialize
  # to JSON — coerce to numeric in their stored units.
  for (col in names(sessions)) {
    if (inherits(sessions[[col]], "difftime")) {
      sessions[[col]] <- as.numeric(sessions[[col]])
    }
  }

  # Last pushes — read from notifications.jsonl if present
  last_pushes <- .read_recent_pushes(cutoff_ts)

  list(
    since       = format(cutoff_ts, "%Y-%m-%dT%H:%M:%S"),
    until       = format(now, "%Y-%m-%dT%H:%M:%S"),
    hours       = hours,
    metrics     = metrics,
    sessions    = sessions,
    last_pushes = last_pushes
  )
}

#' Latest known value per metric
#'
#' Per-metric most recent value, with timestamp and age in hours. Sorted from
#' oldest to newest so any data-quality gaps surface at the top.
#'
#' @param health_daily Long-format tibble.
#' @return Tibble with columns metric, date, value, age_hours.
#' @export
latest_known_metrics <- function(health_daily) {
  if (nrow(health_daily) == 0) {
    return(tibble::tibble(metric = character(), date = as.Date(character()),
                          value = numeric(), age_hours = numeric()))
  }
  now <- Sys.time()
  health_daily |>
    dplyr::filter(!is.na(value)) |>
    dplyr::group_by(metric) |>
    dplyr::summarise(
      date  = max(date),
      value = round(value[which.max(date)], 3),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      age_hours = round(
        as.numeric(difftime(now, as.POSIXct(date), units = "hours")), 1
      )
    ) |>
    dplyr::arrange(date)
}

#' Read recent push events from notifications.jsonl
#' @keywords internal
.read_recent_pushes <- function(cutoff_ts) {
  data_dir <- Sys.getenv("TRANING_DATA", "")
  empty <- tibble::tibble(ts = character(), trigger = character(),
                          title = character(), sent = logical())
  if (data_dir == "") return(empty)
  log_path <- file.path(data_dir, "logs", "notifications.jsonl")
  if (!file.exists(log_path)) return(empty)
  lines <- tryCatch(readLines(log_path, warn = FALSE),
                     error = function(e) character())
  if (length(lines) == 0) return(empty)
  # Tail efficiently: only consider the last N lines, recent ones at end
  tail_lines <- utils::tail(lines, 200)
  parsed <- lapply(tail_lines, function(ln) {
    tryCatch(jsonlite::fromJSON(ln), error = function(e) NULL)
  })
  parsed <- parsed[!vapply(parsed, is.null, logical(1))]
  if (length(parsed) == 0) return(empty)
  df <- do.call(rbind, lapply(parsed, function(x) {
    data.frame(
      ts      = x$ts %||% NA_character_,
      trigger = x$trigger %||% NA_character_,
      title   = x$title %||% NA_character_,
      sent    = isTRUE(x$sent),
      stringsAsFactors = FALSE
    )
  }))
  df <- df[!is.na(df$ts), , drop = FALSE]
  if (nrow(df) == 0) return(empty)
  df$ts_parsed <- as.POSIXct(df$ts, format = "%Y-%m-%dT%H:%M:%S")
  df <- df[!is.na(df$ts_parsed) & df$ts_parsed >= cutoff_ts, , drop = FALSE]
  df$ts_parsed <- NULL
  tibble::as_tibble(df)
}
