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

#' Parse sleep_analysis samples (nested field format)
#' @param samples List of sleep sample objects
#' @return Tibble in long format with sleep_* metrics
#' @keywords internal
.parse_sleep <- function(samples) {
  # Fields to extract as numeric metrics (hours)
  sleep_fields <- c("totalSleep", "core", "deep", "rem", "awake", "inBed",
                     "asleep")
  # Time fields to extract as character
  time_fields <- c("sleepStart", "sleepEnd", "inBedStart", "inBedEnd")

  rows <- lapply(samples, function(s) {
    d <- as.Date(substr(s$date, 1, 10))
    src <- s$source %||% NA_character_

    numeric_rows <- lapply(sleep_fields, function(f) {
      val <- s[[f]]
      if (is.null(val)) return(NULL)
      tibble::tibble(
        date   = d,
        metric = paste0("sleep_", f),
        value  = as.numeric(val),
        source = src
      )
    })

    time_rows <- lapply(time_fields, function(f) {
      val <- s[[f]]
      if (is.null(val) || val == "") return(NULL)
      # Store sleep times as fractional hours since midnight
      parsed <- lubridate::ymd_hms(val, tz = "Europe/Stockholm", quiet = TRUE)
      if (is.na(parsed)) return(NULL)
      hour_frac <- lubridate::hour(parsed) +
                   lubridate::minute(parsed) / 60 +
                   lubridate::second(parsed) / 3600
      # If sleepStart is before midnight next day -> previous evening
      # (e.g. 23:52 = 23.87, not a problem)
      tibble::tibble(
        date   = d,
        metric = paste0("sleep_", f),
        value  = hour_frac,
        source = src
      )
    })

    dplyr::bind_rows(c(numeric_rows, time_rows))
  })
  dplyr::bind_rows(rows)
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
#' @param path Optional path to a specific JSON file. If NULL, reads all
#'   JSON files in the health_export/metrics/ directory.
#' @param cache_path Optional path to the RData cache. Defaults to
#'   \code{$TRANING_DATA/cache/health_daily.RData}.
#' @param save Logical, save to cache after import. Default TRUE.
#' @param verbose Logical, print progress. Default TRUE.
#' @return A tibble of all health data (long format), invisibly.
#' @export
import_health_export <- function(path = NULL, cache_path = NULL,
                                  save = TRUE, verbose = TRUE) {
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

  if (verbose) cat("Importerar", length(files), "fil(er)\n")

  new_data <- lapply(files, function(f) {
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
