# Health Auto Export (HAE) workout JSON parser
#
# Reads workout JSON files exported by the Health Auto Export iOS app and
# returns rows shaped like Garmin trackeR summaries so they can be appended
# to the same `summaries` data frame that powers PMC, ACWR and reports.

# --- Parser -------------------------------------------------------------------

# Every HAE workout name observed in the data, mapped to its canonical
# sport value. Enumerated rather than left to the slug fallback below so
# that a name whose Swedish spelling doesn't slugify to the value we
# already have in the cache can't silently create a second sport for the
# same activity.
#
# Canonical values are the existing cache values — "paddelsporter",
# "karntraning", "sinne_&_kropp" and friends stay slugs on purpose;
# renaming them would split the persisted `sport` column in two until a
# full re-import has run. Swedish display names live in
# .SPORT_LABELS_SV (R/sport_filter.R).
#
# "Vandring" deliberately maps to "walking": a separate "hiking" value
# would not match the c("running", "walking") deduction in
# compute_background_trimp(), so hiking kilometres would be counted both
# as session TRIMP and as background TRIMP.
.HAE_SPORT_NAMES <- list(
  "löpning"                 = "running",
  "kör"                     = "running",
  "utomhus kör"             = "running",
  "inomhus kör"             = "running",
  "cykling"                 = "cycling",
  "utomhus cykling"         = "cycling",
  "inomhus cykling"         = "cycling",
  "gång"                    = "walking",
  "utomhus gång"            = "walking",
  "inomhus gång"            = "walking",
  "vandring"                = "walking",
  "simning"                 = "swimming",
  "öppet vatten-simning"    = "swimming",
  "poolsimning"             = "swimming",
  "paddelsporter"           = "paddelsporter",
  "rodd"                    = "rodd",
  "skridskosporter"         = "skridskosporter",
  "snösporter"              = "snosporter",
  "utförsåkning"            = "utforsakning",
  "funktionell styrketräning" = "strength",
  "traditionell styrketräning" = "strength",
  "kärnträning"             = "karntraning",
  "yoga"                    = "yoga",
  "sinne & kropp"           = "sinne_&_kropp",
  "badminton"               = "badminton",
  "bordtennis"              = "bordtennis",
  "tennis"                  = "tennis",
  "fotboll"                 = "fotboll",
  "hockey"                  = "hockey",
  "fitness-spel"            = "fitness-spel",
  "bågskytte"               = "bagskytte",
  "övrigt"                  = "ovrigt"
)

# Normalise an HAE name for table lookup: lowercase, collapse runs of
# whitespace, trim. Keeps diacritics — the table is keyed on the Swedish
# spelling HAE actually writes.
.hae_name_key <- function(name) {
  n <- tolower(trimws(name))
  gsub("\\s+", " ", n)
}

#' Map an HAE workout name to a sport bucket
#'
#' Matches Garmin's `sport` strings ("running", "cycling") so that downstream
#' filtering (e.g. PMC's `str_detect(sport, "running")`) works without changes.
#' Resolution order: the enumerated \code{.HAE_SPORT_NAMES} table, then
#' substring rules for name variants Apple may add ("Utomhus Löpning"),
#' then a slug fallback.
#'
#' @param name HAE workout `name` string (Swedish UI labels like
#'   "Utomhus Kör", "Utomhus Cykling", "Utomhus Gång").
#' @return Character sport bucket (e.g. "running", "cycling", "walking").
#' @keywords internal
.hae_sport_from_name <- function(name) {
  .hae_sport_lookup(name)$sport
}

#' Whether an HAE workout name is covered by a known mapping
#'
#' Names that fall through to the slug fallback get no Swedish label and
#' no bucket, so the importer counts them and reports them rather than
#' letting a new Apple activity type appear silently.
#'
#' @param name HAE workout `name` string.
#' @return TRUE when the name resolved via table or substring rule.
#' @keywords internal
.hae_sport_is_mapped <- function(name) {
  .hae_sport_lookup(name)$mapped
}

# Shared resolution used by both helpers above.
.hae_sport_lookup <- function(name) {
  if (is.null(name) || length(name) == 0 || is.na(name) || !nzchar(name)) {
    return(list(sport = "unknown", mapped = FALSE))
  }
  key <- .hae_name_key(name)

  exact <- .HAE_SPORT_NAMES[[key]]
  if (!is.null(exact)) return(list(sport = exact, mapped = TRUE))

  # Substring rules — cover "Utomhus X" / "Inomhus X" variants of names
  # Apple may introduce without us having seen them yet.
  if (grepl("kör|löpning|löp", key)) return(list(sport = "running", mapped = TRUE))
  if (grepl("cykling|cykel", key)) return(list(sport = "cycling", mapped = TRUE))
  if (grepl("gång|promenad|vandring|walking", key)) {
    return(list(sport = "walking", mapped = TRUE))
  }
  if (grepl("simning|simma|swimming", key)) {
    return(list(sport = "swimming", mapped = TRUE))
  }
  if (grepl("styrk|gym|strength", key)) {
    return(list(sport = "strength", mapped = TRUE))
  }
  if (grepl("paddel", key)) return(list(sport = "paddelsporter", mapped = TRUE))

  # Fallback: lowercase, strip diacritics, replace spaces
  out <- tolower(name)
  out <- chartr("åäö", "aao", out)
  out <- gsub("\\s+", "_", out)
  list(sport = out, mapped = FALSE)
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

  row <- data.frame(
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
  # Carry the raw HAE name as an attribute rather than a column: the
  # importer needs it to report unmapped activity types, but `summaries`
  # is persisted and must not grow a column for it.
  attr(row, "hae_name") <- w[["name"]]
  row
}

# --- Cross-source matching ----------------------------------------------------

# Δstart window (seconds) used when at least one sanity quantity
# (distance or duration) can be compared between the two sessions.
# Apple Watch and Garmin are often started a minute or two apart on the
# same run — 2026-08-01 was 107 s — so a pure "same second" window is
# far too narrow.
.WORKOUT_MATCH_WINDOW <- 300

# Δstart window (seconds) when neither distance nor duration can be
# compared. Nothing but the clock separates the two rows then, so the
# window is tightened to avoid collapsing two genuinely adjacent
# sessions (e.g. a warm-up walk followed by a run).
.WORKOUT_MATCH_TIME_ONLY_WINDOW <- 120

# Relative tolerance for the distance/duration sanity check. GPS vs.
# wrist-measured distance for the same run typically differ by a few
# percent; 20 % leaves room for that without matching a 5 km run to a
# 12 km one.
.WORKOUT_MATCH_TOLERANCE <- 0.20

# Pull a field out of a data frame, list or bare vector holder.
.workout_field <- function(x, name) {
  if (is.data.frame(x) || is.list(x)) {
    if (!name %in% names(x)) return(NULL)
    return(x[[name]])
  }
  NULL
}

# Coerce a duration to seconds. trackeR stores durations as difftime
# whose units vary by session; a bare numeric is assumed to be seconds.
.workout_secs <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_real_)
  if (inherits(x, "difftime")) return(as.numeric(x, units = "secs"))
  as.numeric(x)
}

# TRUE where both quantities are present, positive and within `tol` of
# each other (relative to the larger of the two).
.within_relative <- function(x, y, tol) {
  ok <- !is.na(x) & !is.na(y) & x > 0 & y > 0
  out <- rep(FALSE, length(ok))
  out[ok] <- abs(x[ok] - y[ok]) / pmax(x[ok], y[ok]) <= tol
  out
}

#' Whether two workout records describe the same session
#'
#' The shared rule behind every cross-source dedup in the package
#' (HAE import, TCX import, \code{dedup_summaries()}): two sessions are
#' the same workout when they start within
#' \code{window_seconds} of each other **and** either their distances or
#' their durations agree within \code{tolerance}. When neither quantity
#' can be compared — one side lacks both — the decision falls back to
#' time alone, with the narrower \code{time_only_seconds} window.
#'
#' Sport is deliberately not part of the rule: Apple Watch sometimes
#' labels a slow jog "Utomhus Gång" while Garmin records it as running.
#'
#' Vectorised over \code{b} (and over \code{a}, if given more than one
#' row); the usual recycling rules apply.
#'
#' @param a,b Data frames or lists with `sessionStart` and, optionally,
#'   `distance` (metres) and `duration` (difftime or seconds).
#' @param window_seconds Δstart window when a sanity quantity is
#'   comparable.
#' @param time_only_seconds Δstart window when neither distance nor
#'   duration is comparable on both sides.
#' @param tolerance Relative tolerance for the distance/duration check.
#' @return Logical vector, one element per compared pair.
#' @keywords internal
.is_same_workout <- function(a, b,
                             window_seconds = .WORKOUT_MATCH_WINDOW,
                             time_only_seconds = .WORKOUT_MATCH_TIME_ONLY_WINDOW,
                             tolerance = .WORKOUT_MATCH_TOLERANCE) {
  sa <- .workout_field(a, "sessionStart")
  sb <- .workout_field(b, "sessionStart")
  if (is.null(sa) || is.null(sb) || length(sa) == 0 || length(sb) == 0) {
    return(logical(0))
  }

  n <- max(length(sa), length(sb))
  rec <- function(x, default = NA_real_) {
    if (is.null(x) || length(x) == 0) return(rep(default, n))
    rep(x, length.out = n)
  }

  sa <- rep(as.POSIXct(sa), length.out = n)
  sb <- rep(as.POSIXct(sb), length.out = n)
  da <- rec(as.numeric(.workout_field(a, "distance")))
  db <- rec(as.numeric(.workout_field(b, "distance")))
  ta <- rec(.workout_secs(.workout_field(a, "duration")))
  tb <- rec(.workout_secs(.workout_field(b, "duration")))

  dt <- abs(as.numeric(difftime(sa, sb, units = "secs")))
  dt[is.na(dt)] <- Inf

  dist_ok <- .within_relative(da, db, tolerance)
  dur_ok <- .within_relative(ta, tb, tolerance)
  comparable <- (!is.na(da) & !is.na(db) & da > 0 & db > 0) |
                (!is.na(ta) & !is.na(tb) & ta > 0 & tb > 0)

  ifelse(comparable,
         dt <= window_seconds & (dist_ok | dur_ok),
         dt <= time_only_seconds)
}

# Rows of `candidates` that are the same workout as the single row `row`.
# Returns an integer vector of positions (empty when nothing matches).
.which_same_workout <- function(row, candidates, ...) {
  if (is.null(candidates) || nrow(candidates) == 0) return(integer(0))
  which(.is_same_workout(row, candidates, ...))
}

# --- Importer -----------------------------------------------------------------

#' Import HAE workout JSON files into summaries
#'
#' Scans `workouts_dir` for `*.json` files, parses each into a summary row,
#' and appends new rows to `summaries`.  Three dedup checks are applied:
#' \enumerate{
#'   \item filename already imported (matched via `file = "hae:<basename>"`)
#'   \item a Garmin (`source == "tcx"`) row describes the same workout per
#'     \code{.is_same_workout()} — Garmin wins, the HAE row is skipped.
#'     Sport is **not** required to match, since two different activities
#'     at the same instant aren't a realistic case and the sport label
#'     sometimes disagrees between Garmin and AW (e.g. a slow jog logged
#'     as "walking" by AW).
#'   \item another HAE row — already cached or accepted earlier in this
#'     same run — describes the same workout. HAE frequently delivers two
#'     JSON files per session (the Apple Watch recording and the
#'     Garmin-Connect-mirrored copy, typically 0–5 s apart); the first one
#'     seen wins.
#' }
#' `myruns` receives `NULL` placeholders so positional alignment with
#' `summaries` is preserved.
#'
#' @param workouts_dir Path to directory containing HAE workout JSON.
#' @param summaries Existing summaries data frame.
#' @param myruns Existing myruns list.
#' @param verbose Logical. Print per-file progress.
#' @param tolerance_seconds Integer. Δstart window (seconds) for dedup when
#'   distance or duration can be compared (default 300).
#' @param time_only_seconds Integer. Narrower Δstart window used when
#'   neither distance nor duration is available on both sides (default 120).
#' @return List with `summaries`, `myruns`, `n_imported`, `n_skipped_dup`,
#'   `n_skipped_dup_hae`, `n_skipped_invalid`, `by_sport`,
#'   `n_unmapped_sports` and `unmapped_names`. `n_skipped_dup` counts rows
#'   dropped in favour of a Garmin row, `n_skipped_dup_hae` rows dropped in
#'   favour of another HAE row. `n_unmapped_sports`/`unmapped_names`
#'   surface activity types that fell through to the slug fallback in
#'   `.hae_sport_from_name()` — they get neither a Swedish label nor a
#'   bucket, so they should be added to `.HAE_SPORT_NAMES` the first time
#'   they appear rather than be discovered months later in a report.
#' @export
import_hae_workouts <- function(workouts_dir, summaries, myruns,
                                verbose = FALSE,
                                tolerance_seconds = .WORKOUT_MATCH_WINDOW,
                                time_only_seconds = .WORKOUT_MATCH_TIME_ONLY_WINDOW) {
  result <- list(
    summaries = summaries,
    myruns = myruns,
    n_imported = 0L,
    n_skipped_dup = 0L,
    n_skipped_dup_hae = 0L,
    n_skipped_invalid = 0L,
    by_sport = integer(0),
    n_unmapped_sports = 0L,
    unmapped_names = character(0)
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

  # Cached rows to dedup against: Garmin (TCX) rows for cross-source
  # dedup, HAE rows for the duplicate-JSON case. Both carry distance and
  # duration so .is_same_workout() can apply its sanity check.
  .candidates <- function(which_source) {
    if (!all(c("source", "sessionStart") %in% names(summaries)) ||
        nrow(summaries) == 0) {
      return(NULL)
    }
    keep <- !is.na(summaries$source) & summaries$source == which_source
    if (!any(keep)) return(NULL)
    data.frame(
      sessionStart = summaries$sessionStart[keep],
      distance = if ("distance" %in% names(summaries))
        as.numeric(summaries$distance[keep]) else NA_real_,
      duration = if ("duration" %in% names(summaries))
        .workout_secs(summaries$duration[keep]) else NA_real_,
      stringsAsFactors = FALSE
    )
  }
  tcx_rows <- .candidates("tcx")
  # Cached HAE rows plus the ones accepted earlier in this same run: two
  # new JSON files for one session usually arrive in the same batch, so
  # comparing against the cache alone would let the pair through.
  hae_rows <- .candidates("hae")

  by_sport <- integer(0)
  unmapped <- character(0)
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

    # Cross-source dedup: Garmin wins (sport label may disagree).
    hit <- .which_same_workout(row, tcx_rows,
                               window_seconds = tolerance_seconds,
                               time_only_seconds = time_only_seconds)
    if (length(hit) > 0) {
      result$n_skipped_dup <- result$n_skipped_dup + 1L
      if (verbose) {
        dt <- abs(as.numeric(difftime(tcx_rows$sessionStart[hit],
                                      row$sessionStart, units = "secs")))
        cat("Dedupp mot Garmin: ", bn,
            " (Δt = ", round(min(dt)), "s)\n", sep = "")
      }
      next
    }

    # HAE↔HAE dedup: the AW recording and the Connect-mirrored copy of
    # one session arrive as two JSON files. Keep the first one seen.
    hit <- .which_same_workout(row, hae_rows,
                               window_seconds = tolerance_seconds,
                               time_only_seconds = time_only_seconds)
    if (length(hit) > 0) {
      result$n_skipped_dup_hae <- result$n_skipped_dup_hae + 1L
      if (verbose) {
        dt <- abs(as.numeric(difftime(hae_rows$sessionStart[hit],
                                      row$sessionStart, units = "secs")))
        cat("Dedupp mot HAE: ", bn,
            " (Δt = ", round(min(dt)), "s)\n", sep = "")
      }
      next
    }

    new_rows[[length(new_rows) + 1L]] <- row
    hae_rows <- rbind(hae_rows, data.frame(
      sessionStart = row$sessionStart,
      distance = as.numeric(row$distance),
      duration = .workout_secs(row$duration),
      stringsAsFactors = FALSE
    ))
    by_sport[row$sport] <- (if (is.na(by_sport[row$sport])) 0L else
                            by_sport[row$sport]) + 1L
    hae_name <- attr(row, "hae_name")
    if (!is.null(hae_name) && !.hae_sport_is_mapped(hae_name)) {
      unmapped <- c(unmapped, as.character(hae_name))
    }
    if (verbose) cat("HAE ny: ", bn, " [", row$sport, "]\n", sep = "")
  }

  unmapped <- sort(unique(unmapped))
  result$unmapped_names <- unmapped
  result$n_unmapped_sports <- length(unmapped)
  if (length(unmapped) > 0 && verbose) {
    cat("Okänd aktivitetstyp (ingen etikett, ingen bucket): ",
        paste(unmapped, collapse = ", "), "\n", sep = "")
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
