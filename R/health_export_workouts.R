# Health Auto Export (HAE) workout JSON parser
#
# Reads workout JSON files exported by the Health Auto Export iOS app and
# returns rows shaped like Garmin trackeR summaries so they can be appended
# to the same `summaries` data frame that powers PMC, ACWR and reports.

# --- Parser -------------------------------------------------------------------

#' Map an HAE workout name to a sport bucket
#'
#' Matches Garmin's `sport` strings ("running", "cycling") so that downstream
#' filtering (e.g. PMC's `str_detect(sport, "running")`) works without changes.
#' Anything not matched returns a sanitised version of the input name.
#'
#' @param name HAE workout `name` string (Swedish UI labels like
#'   "Utomhus Kör", "Utomhus Cykling", "Utomhus Gång").
#' @return Character sport bucket (e.g. "running", "cycling", "walking").
#' @keywords internal
.hae_sport_from_name <- function(name) {
  if (is.null(name) || is.na(name) || !nzchar(name)) return("unknown")
  n <- tolower(name)
  if (grepl("kör|löpning|löp", n)) return("running")
  if (grepl("cykling|cykel", n)) return("cycling")
  if (grepl("gång|promenad|vandring|walking", n)) return("walking")
  if (grepl("simning|simma|swimming", n)) return("swimming")
  if (grepl("styrk|gym|strength", n)) return("strength")
  # Fallback: lowercase, strip diacritics, replace spaces
  out <- tolower(name)
  out <- chartr("åäö", "aao", out)
  out <- gsub("\\s+", "_", out)
  out
}

# Pick a numeric quantity from an HAE field that's either {qty, units} or NA/NULL
.hae_qty <- function(field) {
  if (is.null(field)) return(NA_real_)
  if (is.list(field) && !is.null(field[["qty"]])) return(as.numeric(field[["qty"]]))
  NA_real_
}

# Parse HAE timestamp ("YYYY-MM-DD HH:MM:SS +ZZZZ") to POSIXct
.hae_parse_time <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) return(as.POSIXct(NA))
  # %z handles "+0200"; HAE writes "+0200" without colon
  t <- as.POSIXct(s, format = "%Y-%m-%d %H:%M:%OS %z", tz = "UTC")
  t
}

#' Parse a single HAE workout JSON file
#'
#' Reads one HAE workout JSON file and returns a 1-row data frame with
#' columns matching Garmin trackeR summary output.  Missing fields become
#' `NA`.  Returns `NULL` if the file is unreadable or lacks required keys
#' (`start`, `duration`).
#'
#' @param path Path to a single HAE workout `.json` file.
#' @return One-row data frame, or `NULL` on parse failure.
#' @export
parse_hae_workout <- function(path) {
  raw <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                  error = function(e) NULL)
  if (is.null(raw)) return(NULL)
  workouts <- raw[["data"]][["workouts"]]
  if (is.null(workouts) || length(workouts) == 0) return(NULL)
  w <- workouts[[1]]

  # Required fields
  start <- .hae_parse_time(w[["start"]])
  duration <- if (!is.null(w[["duration"]])) as.numeric(w[["duration"]]) else NA_real_
  if (is.na(start) || is.na(duration)) return(NULL)

  end <- .hae_parse_time(w[["end"]])
  dist_km <- .hae_qty(w[["distance"]])
  dist_m <- if (is.na(dist_km)) NA_real_ else dist_km * 1000
  avg_hr <- .hae_qty(w[["avgHeartRate"]])
  speed_kmh <- .hae_qty(w[["speed"]])
  speed_ms <- if (is.na(speed_kmh)) {
    if (!is.na(dist_m) && duration > 0) dist_m / duration else NA_real_
  } else {
    speed_kmh / 3.6
  }
  pace_minkm <- if (!is.na(dist_km) && dist_km > 0 && duration > 0) {
    (duration / 60) / dist_km
  } else NA_real_
  elev_up <- .hae_qty(w[["elevationUp"]])
  sport <- .hae_sport_from_name(w[["name"]])

  # trackeR stores durations as difftime in seconds.  Match that so
  # downstream code (compute_trimp et al.) that calls
  # as.numeric(durationMoving, units = "mins") gets minutes, not seconds.
  dur_dt <- as.difftime(duration, units = "secs")

  data.frame(
    sessionStart = start,
    sessionEnd = end,
    duration = dur_dt,
    durationMoving = dur_dt,
    distance = dist_m,
    avgHeartRate = avg_hr,
    avgHeartRateMoving = avg_hr,
    avgSpeed = speed_ms,
    avgSpeedMoving = speed_ms,
    avgPace = pace_minkm,
    avgPaceMoving = pace_minkm,
    avgAltitude = NA_real_,
    avgAltitudeMoving = NA_real_,
    total_elevation_gain = elev_up,
    avgCadenceRunning = NA_real_,
    avgCadenceRunningMoving = NA_real_,
    avgStride = NA_real_,
    avgStrideMoving = NA_real_,
    sport = sport,
    file = paste0("hae:", basename(path)),
    source = "hae",
    stringsAsFactors = FALSE
  )
}

# --- Importer -----------------------------------------------------------------

#' Import HAE workout JSON files into summaries
#'
#' Scans `workouts_dir` for `*.json` files, parses each into a summary row,
#' and appends new rows to `summaries`.  Two dedup checks are applied:
#' \enumerate{
#'   \item filename already imported (matched via `file = "hae:<basename>"`)
#'   \item a Garmin (`source == "tcx"`) row exists within
#'     `tolerance_seconds` of the HAE `sessionStart` — Garmin wins, HAE
#'     row is skipped.  Sport is **not** required to match, since two
#'     different activities at the same instant aren't a realistic case
#'     and the sport label sometimes disagrees between Garmin and AW
#'     (e.g. a slow jog logged as "walking" by AW).
#' }
#' `myruns` receives `NULL` placeholders so positional alignment with
#' `summaries` is preserved.
#'
#' @param workouts_dir Path to directory containing HAE workout JSON.
#' @param summaries Existing summaries data frame.
#' @param myruns Existing myruns list.
#' @param verbose Logical. Print per-file progress.
#' @param tolerance_seconds Integer. ±window for Garmin dedup (default 90).
#' @return List with `summaries`, `myruns`, `n_imported`, `n_skipped_dup`,
#'   `n_skipped_invalid`, `by_sport`.
#' @export
import_hae_workouts <- function(workouts_dir, summaries, myruns,
                                verbose = FALSE, tolerance_seconds = 90L) {
  result <- list(
    summaries = summaries,
    myruns = myruns,
    n_imported = 0L,
    n_skipped_dup = 0L,
    n_skipped_invalid = 0L,
    by_sport = integer(0)
  )

  if (!dir.exists(workouts_dir)) {
    if (verbose) message("HAE workouts dir saknas: ", workouts_dir)
    return(result)
  }

  files <- list.files(workouts_dir, pattern = "\\.json$",
                      full.names = TRUE, ignore.case = TRUE)
  if (length(files) == 0) {
    if (verbose) message("Inga HAE workout-JSON i ", workouts_dir)
    return(result)
  }

  # Already-imported HAE files (basename without "hae:" prefix)
  existing_hae <- character(0)
  if ("file" %in% names(summaries) && nrow(summaries) > 0) {
    hae_files <- summaries$file[grepl("^hae:", summaries$file)]
    existing_hae <- sub("^hae:", "", hae_files)
  }

  # Garmin TCX rows for cross-source dedup
  tcx_starts <- as.POSIXct(character(0))
  if (all(c("source", "sessionStart") %in% names(summaries)) &&
      nrow(summaries) > 0) {
    is_tcx <- !is.na(summaries$source) & summaries$source == "tcx"
    tcx_starts <- summaries$sessionStart[is_tcx]
  }

  by_sport <- integer(0)
  new_rows <- list()

  for (f in files) {
    bn <- basename(f)
    if (bn %in% existing_hae) {
      if (verbose) cat("Redan inläst (HAE): ", bn, "\n", sep = "")
      next
    }

    row <- tryCatch(parse_hae_workout(f), error = function(e) NULL)
    if (is.null(row)) {
      result$n_skipped_invalid <- result$n_skipped_invalid + 1L
      if (verbose) cat("Ogiltig HAE-JSON: ", bn, "\n", sep = "")
      next
    }

    # Cross-source dedup (time-only — sport label may disagree).
    if (length(tcx_starts) > 0) {
      dt <- abs(as.numeric(difftime(tcx_starts, row$sessionStart,
                                    units = "secs")))
      hit <- which(dt < tolerance_seconds)
      if (length(hit) > 0) {
        result$n_skipped_dup <- result$n_skipped_dup + 1L
        if (verbose) {
          cat("Dedupp mot Garmin: ", bn,
              " (Δt = ", round(min(dt[hit])), "s)\n", sep = "")
        }
        next
      }
    }

    new_rows[[length(new_rows) + 1L]] <- row
    by_sport[row$sport] <- (if (is.na(by_sport[row$sport])) 0L else
                            by_sport[row$sport]) + 1L
    if (verbose) cat("HAE ny: ", bn, " [", row$sport, "]\n", sep = "")
  }

  if (length(new_rows) > 0) {
    new_df <- do.call(rbind, new_rows)
    # Align columns: pad missing in summaries or new_df with NA
    summaries <- .rbind_align(summaries, new_df)
    # Add NULL placeholders to myruns
    n_new <- nrow(new_df)
    myruns <- c(myruns, vector("list", n_new))

    result$summaries <- summaries
    result$myruns <- myruns
    result$n_imported <- n_new
    result$by_sport <- by_sport
  }

  result
}

# Bind two data frames by union of columns, filling NA where absent
.rbind_align <- function(a, b) {
  if (nrow(a) == 0) return(b)
  if (nrow(b) == 0) return(a)
  all_cols <- union(names(a), names(b))
  for (col in setdiff(all_cols, names(a))) a[[col]] <- NA
  for (col in setdiff(all_cols, names(b))) b[[col]] <- NA
  rbind(a[, all_cols, drop = FALSE], b[, all_cols, drop = FALSE],
        deparse.level = 0, make.row.names = FALSE)
}
