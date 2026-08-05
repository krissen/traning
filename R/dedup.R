# Retroactive cross-source deduplication of the summaries cache.
#
# Import-time dedup (import_hae_workouts(), get_new_workouts()) keeps new
# data clean, but the cache accumulated duplicates while the window was
# ±90 s and one-directional. This is the one-off cleanup for those.

# Build the candidate table: every HAE row that has a Garmin twin.
.find_hae_duplicates <- function(summaries, ...) {
  empty <- data.frame(
    idx = integer(0), sessionStart = as.POSIXct(character(0)),
    sport = character(0), distance_hae = numeric(0),
    distance_tcx = numeric(0), dt_seconds = numeric(0),
    end_gap_seconds = numeric(0),
    file = character(0), tcx_file = character(0),
    stringsAsFactors = FALSE
  )
  if (!is.data.frame(summaries) || nrow(summaries) == 0 ||
      !"source" %in% names(summaries)) {
    return(empty)
  }

  src <- summaries$source
  hae_idx <- which(!is.na(src) & src == "hae")
  tcx_idx <- which(!is.na(src) & src == "tcx")
  if (length(hae_idx) == 0 || length(tcx_idx) == 0) return(empty)

  tcx <- summaries[tcx_idx, , drop = FALSE]
  hits <- lapply(hae_idx, function(i) {
    row <- summaries[i, , drop = FALSE]
    m <- .which_same_workout(row, tcx, ...)
    if (length(m) == 0) return(NULL)
    # Several Garmin rows can match (rare); report the closest one.
    dt <- abs(as.numeric(difftime(tcx$sessionStart[m], row$sessionStart,
                                  units = "secs")))
    best <- m[which.min(dt)]
    end_gap <- if ("sessionEnd" %in% names(summaries))
      abs(as.numeric(difftime(tcx$sessionEnd[best], row$sessionEnd,
                              units = "secs"))) else NA_real_
    data.frame(
      idx = i,
      sessionStart = row$sessionStart,
      sport = as.character(row$sport),
      distance_hae = as.numeric(row$distance),
      distance_tcx = as.numeric(tcx$distance[best]),
      dt_seconds = min(dt),
      end_gap_seconds = end_gap,
      file = as.character(row$file),
      tcx_file = basename(as.character(tcx$file[best])),
      stringsAsFactors = FALSE
    )
  })
  hits <- hits[!vapply(hits, is.null, logical(1))]
  if (length(hits) == 0) return(empty)
  do.call(rbind, hits)
}

#' Remove Apple Watch rows that duplicate a Garmin session
#'
#' Scans the whole summaries cache for `source == "hae"` rows that
#' describe the same workout as a `source == "tcx"` row (per
#' `.is_same_workout()`: either a close start plus a distance/duration
#' sanity check, or overlapping wall-clock intervals) and removes them —
#' Garmin wins. All sports are considered, not just running, though the
#' overlap half of the rule exempts the sports listed in
#' `.WORKOUT_OVERLAP_EXEMPT_SPORTS`.
#'
#' The reported `dt_seconds` is the start offset and `end_gap_seconds`
#' the stop offset; a pair with a large `dt_seconds` and a small
#' `end_gap_seconds` is the "second watch started midway" shape.
#'
#' Runs as a dry run by default: the candidates are listed and nothing is
#' written. Pass `dry_run = FALSE` to apply. The corresponding `myruns`
#' entries are removed alongside so the positional coupling survives, and
#' the result is written through `my_dbs_save()` (atomic).
#'
#' @param db_summaries Path to summaries.RData. Defaults to
#'   `$TRANING_DATA/cache/summaries.RData`.
#' @param db_myruns Path to myruns.RData. Defaults to
#'   `$TRANING_DATA/cache/myruns.RData`.
#' @param dry_run Logical. When TRUE (default) only report candidates.
#' @param verbose Logical. Print the candidate table.
#' @param limit Integer or NULL. Max number of candidate rows to print.
#' @return Invisibly, a data frame of the duplicate rows found (one row per
#'   removed/removable HAE session).
#' @export
dedup_summaries <- function(db_summaries = NULL, db_myruns = NULL,
                            dry_run = TRUE, verbose = TRUE, limit = NULL) {
  if (is.null(db_summaries) || is.null(db_myruns)) {
    traning_data <- Sys.getenv("TRANING_DATA")
    if (!nzchar(traning_data)) {
      stop("TRANING_DATA is not set and no cache paths were given.")
    }
    if (is.null(db_summaries)) {
      db_summaries <- file.path(traning_data, "cache", "summaries.RData")
    }
    if (is.null(db_myruns)) {
      db_myruns <- file.path(traning_data, "cache", "myruns.RData")
    }
  }

  loaded <- my_dbs_load(db_summaries, db_myruns)
  summaries <- loaded$summaries
  myruns <- loaded$myruns

  dups <- .find_hae_duplicates(summaries)

  if (verbose) {
    cat("Dubblettsökning: ", nrow(summaries), " rader, ",
        nrow(dups), " Apple Watch-rader har en Garmin-tvilling.\n", sep = "")
    if (nrow(dups) > 0) {
      shown <- if (is.null(limit)) dups else utils::head(dups, limit)
      out <- data.frame(
        datum = format(shown$sessionStart, "%Y-%m-%d %H:%M"),
        sport = shown$sport,
        `hae_m` = round(shown$distance_hae),
        `tcx_m` = round(shown$distance_tcx),
        `dt_s` = round(shown$dt_seconds),
        `slut_s` = round(shown$end_gap_seconds),
        fil = sub("^hae:", "", shown$file),
        check.names = FALSE,
        stringsAsFactors = FALSE
      )
      print(out, row.names = FALSE)
      if (!is.null(limit) && nrow(dups) > limit) {
        cat("... och ", nrow(dups) - limit, " till.\n", sep = "")
      }
    }
  }

  if (nrow(dups) == 0) {
    if (verbose) cat("Inget att rensa.\n")
    return(invisible(dups))
  }

  if (dry_run) {
    if (verbose) {
      cat("Torrkörning — inget skrivet. Kör med dry_run = FALSE ",
          "(CLI: utan --dry-run) för att ta bort.\n", sep = "")
    }
    return(invisible(dups))
  }

  aligned <- .align_myruns(summaries, myruns)
  summaries <- aligned$summaries
  myruns <- aligned$myruns

  drop <- sort(unique(dups$idx))
  summaries <- .restore_df_attrs(summaries[-drop, , drop = FALSE], summaries)
  rownames(summaries) <- NULL
  myruns <- myruns[-drop]

  if (length(myruns) != nrow(summaries)) {
    stop("dedup_summaries: myruns (", length(myruns),
         ") matchar inte summaries (", nrow(summaries),
         ") efter borttagning — inget sparat.")
  }

  my_dbs_save(db_summaries, db_myruns, summaries, myruns)
  if (verbose) {
    cat("Borttaget: ", length(drop), " rader. Kvar: ", nrow(summaries),
        " rader, ", length(myruns), " run-objekt.\n", sep = "")
  }
  invisible(dups)
}
