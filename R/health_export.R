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
  jsonlite::fromJSON(manifest_path, simplifyVector = FALSE)
}

#' Save the import manifest
#' @param manifest Named list: filename -> list(mtime, size)
#' @param manifest_path Path to manifest JSON. NULL = default.
#' @keywords internal
.save_manifest <- function(manifest, manifest_path = NULL) {
  if (is.null(manifest_path)) manifest_path <- .hae_manifest_path()
  cache_dir <- dirname(manifest_path)
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  jsonlite::write_json(manifest, manifest_path, auto_unbox = TRUE, pretty = TRUE)
}

#' Compare files against manifest and return only new/changed ones
#' @param files Character vector of file paths
#' @param manifest Named list from .load_manifest()
#' @return Character vector of files that need importing
#' @keywords internal
.filter_changed_files <- function(files, manifest) {
  changed <- vapply(files, function(f) {
    key <- basename(f)
    info <- file.info(f)
    prev <- manifest[[key]]
    if (is.null(prev)) return(TRUE)  # new file
    prev_mtime <- as.integer(prev$mtime)
    prev_size  <- as.numeric(prev$size)
    cur_mtime  <- as.integer(as.numeric(info$mtime))
    cur_size   <- info$size
    cur_mtime != prev_mtime || cur_size != prev_size
  }, logical(1))
  files[changed]
}

#' Build manifest entries for a set of files
#' @param files Character vector of file paths
#' @return Named list: basename -> list(mtime, size)
#' @keywords internal
.build_manifest_entries <- function(files) {
  entries <- list()
  for (f in files) {
    info <- file.info(f)
    entries[[basename(f)]] <- list(
      mtime = as.integer(as.numeric(info$mtime)),
      size  = info$size
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

# Sources ranked by sleep staging quality (best first)
.sleep_source_priority <- c(
  "Apple Watch f\u00f6r Kristian", "kankad", "kankad ",
  "Sleep Cycle", "AutoSleep", "Oura",
  "Health Sync", "Health Import", "Klocka", "anandavani", "Connect"
)

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

  # Assign sleep date from end timestamp (wake-up date)
  sleep_date <- as.Date(substr(end_dates, 1, 10))

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
#' misleading values. This function drops those mixed-source rows, keeping
#' only pure Apple Watch data.
#'
#' @param df Tibble with columns: date, metric, value, source.
#' @return Filtered tibble.
#' @keywords internal
.clean_sources <- function(df) {
  is_contaminated <- df$metric %in% .connect_contaminated_metrics &
    grepl("Connect", df$source, fixed = TRUE)
  n_dropped <- sum(is_contaminated)
  if (n_dropped > 0) {
    message("  Filtrerade bort ", n_dropped,
            " Connect-kontaminerade värden (resting_heart_rate)")
  }
  df[!is_contaminated, ]
}

# --- Daily aggregation --------------------------------------------------------

# Metrics that should be summed (accumulated over a day), not averaged.
.sum_metrics <- c(
  "step_count", "active_energy", "basal_energy_burned", "flights_climbed",
  "apple_exercise_time", "apple_stand_time", "apple_stand_hour",
  "walking_running_distance", "cycling_distance", "mindful_minutes",
  "time_in_daylight"
)

#' Aggregate non-aggregated health data to daily values
#'
#' When HAE exports raw (non-aggregated) data, there may be multiple
#' samples per day per metric. This function reduces them to one value
#' per day: sum for accumulative metrics, mean for everything else.
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
        dplyr::first(metric) == "heart_rate_min" ~ min(value, na.rm = TRUE),
        dplyr::first(metric) == "heart_rate_max" ~ max(value, na.rm = TRUE),
        .default = mean(value, na.rm = TRUE)
      ),
      source = dplyr::first(source),
      .groups = "drop"
    )
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

  # Find files to import
  if (is.null(path)) {
    metrics_dir <- file.path(.hae_dir(), "metrics")
    files <- list.files(metrics_dir, pattern = "\\.json$",
                        full.names = TRUE, recursive = FALSE)
    if (length(files) == 0) {
      cat("Inga JSON-filer i", metrics_dir, "\n")
      return(invisible(existing))
    }
  } else {
    files <- path
  }

  # Filter to new/changed files using manifest (unless forced or single file)
  manifest <- if (is.null(path) && !force) .load_manifest() else list()
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

  new_data <- lapply(files_to_parse, function(f) {
    read_health_export(f, verbose = verbose)
  })
  new_data <- dplyr::bind_rows(new_data)

  if (nrow(new_data) == 0) {
    cat("Inga nya data\n")
    return(invisible(existing))
  }

  # Merge, clean sources, and deduplicate
  combined <- dplyr::bind_rows(existing, new_data)
  combined <- .clean_sources(combined)
  health_daily <- combined |>
    dplyr::arrange(date, metric) |>
    dplyr::distinct(date, metric, .keep_all = TRUE)

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

    # Update manifest with all files (both parsed and previously imported)
    new_entries <- .build_manifest_entries(files_to_parse)
    if (force || is.null(path)) {
      # Full run: rebuild manifest from all files
      all_entries <- .build_manifest_entries(files)
      .save_manifest(all_entries)
    } else {
      # Single-file run: merge into existing manifest
      for (k in names(new_entries)) manifest[[k]] <- new_entries[[k]]
      .save_manifest(manifest)
    }
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
  save(health_daily, file = cache_path)
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
                          "blood_oxygen_saturation", "respiratory_rate")

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
