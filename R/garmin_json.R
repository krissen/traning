# Garmin JSON import: extract rich metrics from gconnect JSON file pairs
#
# Each activity in gconnect/ has two files:
#   {timestamp}_{activityId}_summary.json
#   {timestamp}_{activityId}_details.json
#
# Two JSON formats exist:
#   Old (pre-late-2024): summary data nested under summaryDTO; details has only
#     metricDescriptors + activityDetailMetrics (no recoveryHR, RPE, etc.)
#   New (post-late-2024): flat top-level keys in summary; details has summaryDTO
#     with recoveryHR, RPE, temperature, minHR.
#
# Format detection: presence of the "summaryDTO" key in the summary JSON.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Parse a single summary JSON file and return a one-row list of named fields.
# Returns NA for any field that is absent or NULL in the JSON.
.parse_summary_json <- function(path) {
  raw <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      warning("Kunde inte tolka summary-JSON: ", basename(path),
              " (", conditionMessage(e), ")", call. = FALSE)
      return(NULL)
    }
  )
  if (is.null(raw)) return(NULL)

  # Determine format by presence of summaryDTO key
  is_old_format <- !is.null(raw[["summaryDTO"]])

  .get <- function(obj, key) {
    val <- obj[[key]]
    if (is.null(val)) NA_real_ else as.numeric(val)
  }

  if (is_old_format) {
    dto <- raw[["summaryDTO"]]
    maxHR           <- .get(dto, "maxHR")
    vO2MaxValue     <- .get(dto, "vO2MaxValue")
    hrTimeInZone_1  <- .get(dto, "hrTimeInZone_1")
    hrTimeInZone_2  <- .get(dto, "hrTimeInZone_2")
    hrTimeInZone_3  <- .get(dto, "hrTimeInZone_3")
    hrTimeInZone_4  <- .get(dto, "hrTimeInZone_4")
    hrTimeInZone_5  <- .get(dto, "hrTimeInZone_5")
  } else {
    maxHR           <- .get(raw, "maxHR")
    vO2MaxValue     <- .get(raw, "vO2MaxValue")
    hrTimeInZone_1  <- .get(raw, "hrTimeInZone_1")
    hrTimeInZone_2  <- .get(raw, "hrTimeInZone_2")
    hrTimeInZone_3  <- .get(raw, "hrTimeInZone_3")
    hrTimeInZone_4  <- .get(raw, "hrTimeInZone_4")
    hrTimeInZone_5  <- .get(raw, "hrTimeInZone_5")
  }

  list(
    garmin_maxHR          = maxHR,
    garmin_vO2MaxValue    = vO2MaxValue,
    garmin_hrTimeInZone_1 = hrTimeInZone_1,
    garmin_hrTimeInZone_2 = hrTimeInZone_2,
    garmin_hrTimeInZone_3 = hrTimeInZone_3,
    garmin_hrTimeInZone_4 = hrTimeInZone_4,
    garmin_hrTimeInZone_5 = hrTimeInZone_5
  )
}

# Parse a single details JSON file and return a one-row list of named fields.
# Old-format details files contain only time-series data (metricDescriptors +
# activityDetailMetrics) — those fields return NA.
# New-format details files have a summaryDTO with the scalar fields we need.
.parse_details_json <- function(path) {
  raw <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      warning("Kunde inte tolka details-JSON: ", basename(path),
              " (", conditionMessage(e), ")", call. = FALSE)
      return(NULL)
    }
  )
  if (is.null(raw)) {
    return(list(
      garmin_recoveryHeartRate  = NA_real_,
      garmin_directWorkoutRpe   = NA_real_,
      garmin_averageTemperature = NA_real_,
      garmin_minHR              = NA_real_
    ))
  }

  .get <- function(obj, key) {
    val <- obj[[key]]
    if (is.null(val)) NA_real_ else as.numeric(val)
  }

  # summaryDTO exists in new-format details (and also in some mid-era files)
  dto <- raw[["summaryDTO"]]
  if (!is.null(dto)) {
    # New-format details: summaryDTO holds scalar metrics
    list(
      garmin_recoveryHeartRate  = .get(dto, "recoveryHeartRate"),
      garmin_directWorkoutRpe   = .get(dto, "directWorkoutRpe"),
      garmin_averageTemperature = .get(dto, "averageTemperature"),
      garmin_minHR              = .get(dto, "minHR")
    )
  } else {
    # Old-format details: only time-series; scalar metrics not available
    list(
      garmin_recoveryHeartRate  = NA_real_,
      garmin_directWorkoutRpe   = NA_real_,
      garmin_averageTemperature = NA_real_,
      garmin_minHR              = NA_real_
    )
  }
}

# Extract the UTC start timestamp from a gconnect filename.
# Filenames have the form: {ISO8601-UTC}_{activityId}_{type}.json
# Examples:
#   2024-12-31T13:59:23+00:00_17881858496_summary.json
#   2020-06-01T05:59:49+00:00_5021470001_summary.json
# Returns a POSIXct (UTC) or NA if parsing fails.
.parse_gconnect_timestamp <- function(filename) {
  # Extract the leading timestamp portion (up to the first underscore that
  # is followed by digits — the activityId)
  ts_str <- sub("^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})[^_]*_.*$",
                "\\1", filename)
  if (identical(ts_str, filename)) return(as.POSIXct(NA))
  tryCatch(
    as.POSIXct(ts_str, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
    error = function(e) as.POSIXct(NA)
  )
}

# ---------------------------------------------------------------------------
# Exported functions
# ---------------------------------------------------------------------------

#' Import Garmin JSON metrics from gconnect directory
#'
#' Reads all *_summary.json and *_details.json pairs in gc_dir and extracts
#' the rich metrics that are not available in trackeR summaries. Handles both
#' the old format (data nested under summaryDTO) and the new flat format.
#'
#' @param gc_dir Character. Path to the gconnect directory containing JSON files.
#' @return A tibble with one row per activity pair, with columns:
#'   \describe{
#'     \item{filename_prefix}{The \code{{timestamp}_{activityId}} stem shared
#'       by the summary and details files.}
#'     \item{gc_timestamp_utc}{POSIXct UTC timestamp parsed from the filename.}
#'     \item{garmin_maxHR}{Maximum heart rate (bpm).}
#'     \item{garmin_hrTimeInZone_1 -- garmin_hrTimeInZone_5}{Time in each HR
#'       zone (seconds).}
#'     \item{garmin_vO2MaxValue}{Estimated VO2max.}
#'     \item{garmin_recoveryHeartRate}{Heart rate measured ~2 min post-effort
#'       (new-format files only; NA for older files).}
#'     \item{garmin_directWorkoutRpe}{Self-reported RPE 0-100 (new-format
#'       files only; NA for older files).}
#'     \item{garmin_averageTemperature}{Average temperature during activity
#'       in degrees Celsius (new-format files only; NA for older files).}
#'     \item{garmin_minHR}{Minimum heart rate during activity (bpm;
#'       new-format files only; NA for older files).}
#'   }
#' @export
import_garmin_json <- function(gc_dir) {
  if (!dir.exists(gc_dir)) {
    stop("Katalogen finns inte: ", gc_dir)
  }

  summary_files <- list.files(
    gc_dir,
    pattern = "_summary\\.json$",
    full.names = TRUE
  )

  if (length(summary_files) == 0) {
    message("Inga summary-JSON-filer hittades i: ", gc_dir)
    return(tibble::tibble())
  }

  message("Läser ", length(summary_files), " Garmin JSON-par från ", gc_dir)

  rows <- vector("list", length(summary_files))

  for (i in seq_along(summary_files)) {
    sum_path <- summary_files[[i]]
    fname    <- basename(sum_path)

    # Derive the prefix and details path from the summary filename
    prefix       <- sub("_summary\\.json$", "", fname)
    details_path <- file.path(gc_dir, paste0(prefix, "_details.json"))

    # Parse UTC timestamp from filename
    gc_ts <- .parse_gconnect_timestamp(fname)

    # Parse summary fields
    sum_fields <- .parse_summary_json(sum_path)

    # Parse details fields (missing details file is handled gracefully)
    if (file.exists(details_path)) {
      det_fields <- .parse_details_json(details_path)
    } else {
      det_fields <- list(
        garmin_recoveryHeartRate  = NA_real_,
        garmin_directWorkoutRpe   = NA_real_,
        garmin_averageTemperature = NA_real_,
        garmin_minHR              = NA_real_
      )
    }

    if (is.null(sum_fields)) {
      # summary parse failed — emit a row of NAs so the prefix is still indexed
      sum_fields <- list(
        garmin_maxHR          = NA_real_,
        garmin_vO2MaxValue    = NA_real_,
        garmin_hrTimeInZone_1 = NA_real_,
        garmin_hrTimeInZone_2 = NA_real_,
        garmin_hrTimeInZone_3 = NA_real_,
        garmin_hrTimeInZone_4 = NA_real_,
        garmin_hrTimeInZone_5 = NA_real_
      )
    }

    rows[[i]] <- tibble::tibble(
      filename_prefix           = prefix,
      gc_timestamp_utc          = gc_ts,
      garmin_maxHR              = sum_fields$garmin_maxHR,
      garmin_vO2MaxValue        = sum_fields$garmin_vO2MaxValue,
      garmin_hrTimeInZone_1     = sum_fields$garmin_hrTimeInZone_1,
      garmin_hrTimeInZone_2     = sum_fields$garmin_hrTimeInZone_2,
      garmin_hrTimeInZone_3     = sum_fields$garmin_hrTimeInZone_3,
      garmin_hrTimeInZone_4     = sum_fields$garmin_hrTimeInZone_4,
      garmin_hrTimeInZone_5     = sum_fields$garmin_hrTimeInZone_5,
      garmin_recoveryHeartRate  = det_fields$garmin_recoveryHeartRate,
      garmin_directWorkoutRpe   = det_fields$garmin_directWorkoutRpe,
      garmin_averageTemperature = det_fields$garmin_averageTemperature,
      garmin_minHR              = det_fields$garmin_minHR
    )

    if (i %% 500 == 0) {
      message("  ", i, " / ", length(summary_files), " filer inlästa ...")
    }
  }

  dplyr::bind_rows(rows)
}

#' Augment summaries with Garmin JSON fields
#'
#' Joins garmin_data (produced by \code{import_garmin_json()}) onto the
#' summaries data frame. Matching is done on UTC timestamp within a tolerance
#' of 120 seconds, comparing the \code{gc_timestamp_utc} column in garmin_data
#' against the \code{sessionStart} column in summaries (coerced to UTC).
#'
#' Activities with no matching JSON record receive NA for all garmin_* columns.
#' Ambiguous matches (multiple JSON files within the tolerance window) are
#' resolved by taking the closest match; a warning is emitted when this occurs.
#'
#' @param summaries Data frame. The existing summaries tibble (must contain a
#'   \code{sessionStart} POSIXct column).
#' @param garmin_data Tibble. Output of \code{import_garmin_json()}.
#' @param tolerance_secs Numeric. Maximum allowed difference in seconds between
#'   \code{sessionStart} and \code{gc_timestamp_utc} for a match.
#'   Default 120.
#' @return The summaries tibble with additional garmin_* columns appended.
#'   Rows are preserved in their original order.
#' @export
augment_summaries <- function(summaries, garmin_data,
                               tolerance_secs = 120) {
  if (nrow(garmin_data) == 0) {
    message("garmin_data är tom — inga Garmin-kolumner läggs till.")
    return(summaries)
  }
  if (!("sessionStart" %in% names(summaries))) {
    stop("summaries saknar kolumnen 'sessionStart'.")
  }

  # Work in UTC throughout
  session_utc <- as.POSIXct(summaries$sessionStart, tz = "UTC")
  gc_ts       <- as.POSIXct(garmin_data$gc_timestamp_utc, tz = "UTC")

  garmin_cols <- c(
    "garmin_maxHR", "garmin_vO2MaxValue",
    "garmin_hrTimeInZone_1", "garmin_hrTimeInZone_2",
    "garmin_hrTimeInZone_3", "garmin_hrTimeInZone_4", "garmin_hrTimeInZone_5",
    "garmin_recoveryHeartRate", "garmin_directWorkoutRpe",
    "garmin_averageTemperature", "garmin_minHR"
  )

  # Pre-allocate result columns as NA
  result_cols <- lapply(garmin_cols, function(cn) rep(NA_real_, nrow(summaries)))
  names(result_cols) <- garmin_cols

  matched_count   <- 0L
  ambiguous_count <- 0L

  for (i in seq_len(nrow(summaries))) {
    s_ts <- session_utc[[i]]
    if (is.na(s_ts)) next

    diffs <- abs(as.numeric(difftime(gc_ts, s_ts, units = "secs")))
    within_tol <- which(diffs <= tolerance_secs)

    if (length(within_tol) == 0L) next

    if (length(within_tol) > 1L) {
      ambiguous_count <- ambiguous_count + 1L
      within_tol <- within_tol[which.min(diffs[within_tol])]
    }

    matched_count <- matched_count + 1L
    j <- within_tol[[1L]]
    for (cn in garmin_cols) {
      result_cols[[cn]][[i]] <- garmin_data[[cn]][[j]]
    }
  }

  if (ambiguous_count > 0L) {
    warning(ambiguous_count,
            " aktivitet(er) matchades mot fler \u00e4n en JSON-fil;",
            " n\u00e4rmaste tidsstampel anv\u00e4ndes.",
            call. = FALSE)
  }

  message(
    "Garmin JSON: ", matched_count, " av ", nrow(summaries),
    " aktiviteter matchade (tolerans \u00b1", tolerance_secs, " s)."
  )

  dplyr::bind_cols(summaries, tibble::as_tibble(result_cols))
}

#' Load Garmin JSON data with incremental caching
#'
#' Wraps \code{import_garmin_json()} with an RData cache. On first call, reads
#' all JSON files and saves the result. On subsequent calls, only reads files
#' newer than the cache and appends them.
#'
#' @param gc_dir Character. Path to the gconnect directory.
#' @param cache_path Character. Path for the RData cache file.
#'   Default: \code{file.path(dirname(gc_dir), "..", "..", "cache", "garmin_json.RData")}.
#' @return Tibble identical to \code{import_garmin_json()} output.
#' @export
load_garmin_json <- function(gc_dir,
                             cache_path = NULL) {
  if (is.null(cache_path)) {
    cache_path <- file.path(
      dirname(gc_dir), "..", "..", "cache", "garmin_json.RData"
    )
    cache_path <- normalizePath(cache_path, mustWork = FALSE)
  }

  if (!file.exists(cache_path)) {
    # Cold start — read everything
    garmin_data <- import_garmin_json(gc_dir)
    save(garmin_data, file = cache_path)
    return(garmin_data)
  }

  # Load cached data
  load(cache_path)  # loads 'garmin_data'
  cache_mtime <- file.info(cache_path)$mtime

  # Find summary files newer than the cache
  summary_files <- list.files(
    gc_dir,
    pattern = "_summary\\.json$",
    full.names = TRUE
  )
  file_mtimes <- file.info(summary_files)$mtime
  new_files <- summary_files[file_mtimes > cache_mtime]

  if (length(new_files) == 0) {
    message("Garmin JSON cache: ", nrow(garmin_data),
            " aktiviteter (inga nya filer).")
    return(garmin_data)
  }

  # Parse only the new files by creating a temp dir with symlinks
  tmp_dir <- tempfile("gc_incr_")
  dir.create(tmp_dir)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  for (sf in new_files) {
    file.copy(sf, tmp_dir)
    # Also copy the corresponding details file if it exists
    prefix <- sub("_summary\\.json$", "", basename(sf))
    det <- file.path(gc_dir, paste0(prefix, "_details.json"))
    if (file.exists(det)) file.copy(det, tmp_dir)
  }

  new_data <- import_garmin_json(tmp_dir)

  # Remove any rows already in cache (by filename_prefix) and append
  if (nrow(new_data) > 0) {
    new_data <- new_data[!new_data$filename_prefix %in%
                           garmin_data$filename_prefix, ]
  }

  if (nrow(new_data) > 0) {
    garmin_data <- dplyr::bind_rows(garmin_data, new_data)
    message("Garmin JSON cache: +", nrow(new_data), " nya, ",
            nrow(garmin_data), " totalt.")
  } else {
    message("Garmin JSON cache: ", nrow(garmin_data),
            " aktiviteter (inga nya unika).")
  }

  save(garmin_data, file = cache_path)
  garmin_data
}
