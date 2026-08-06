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
    duration_hae = numeric(0),
    distance_tcx = numeric(0), dt_seconds = numeric(0),
    end_gap_seconds = numeric(0),
    file = character(0), tcx_file = character(0),
    winner = character(0), tcx_drop = I(list()),
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
    # Several Garmin rows can match; the closest one is what the report
    # quotes, but the removal below uses all of them.
    dt <- abs(as.numeric(difftime(tcx$sessionStart[m], row$sessionStart,
                                  units = "secs")))
    best <- m[which.min(dt)]
    end_gap <- if ("sessionEnd" %in% names(summaries))
      abs(as.numeric(difftime(tcx$sessionEnd[best], row$sessionEnd,
                              units = "secs"))) else NA_real_
    # Garmin keeps the session unless everything it recorded for it adds
    # up to less than half the Apple Watch distance — the same test the
    # two import paths apply, against the same total.
    # Copies of one recording count once towards the total; every copy
    # is still removed below when the Apple Watch row wins. The set the
    # total is built from and the set that gets removed are the same
    # rows here, so a verdict cannot be applied to something it was
    # never weighed against — an NA verdict means the answer depends on
    # a distance nobody recorded, and the pair is then left alone.
    distinct <- m[.distinct_recordings(tcx$sessionStart[m])]
    verdict <- .garmin_verdict(row$distance, tcx$distance[distinct])
    if (is.na(verdict)) return(NULL)
    garmin <- verdict
    # When the watch wins, *every* fragment goes. A Garmin watch stopped
    # and restarted leaves two of them against one session, and removing
    # only the nearest would leave the other orphaned — a few kilometres
    # double-counted until someone ran the cleanup a second time.
    fragments <- if (garmin) integer(0) else tcx_idx[m]
    data.frame(
      idx = i,
      sessionStart = row$sessionStart,
      sport = as.character(row$sport),
      distance_hae = as.numeric(row$distance),
      # Duration decides between copies of a session that records no
      # distance at all — strength work, yoga, core.
      duration_hae = .workout_secs(row$duration),
      distance_tcx = as.numeric(tcx$distance[best]),
      dt_seconds = min(dt),
      end_gap_seconds = end_gap,
      file = as.character(row$file),
      tcx_file = if (garmin) basename(as.character(tcx$file[best]))
                 else paste(basename(as.character(tcx$file[m])),
                            collapse = ";"),
      winner = if (garmin) "garmin" else "aw",
      # Positions in `summaries` of every Garmin row that loses when the
      # Apple Watch row wins; empty otherwise. A list column so one
      # candidate can carry several fragments.
      tcx_drop = I(list(fragments)),
      stringsAsFactors = FALSE
    )
  })
  hits <- hits[!vapply(hits, is.null, logical(1))]
  if (length(hits) == 0) return(empty)
  do.call(rbind, hits)
}

# Rows to drop when several Apple Watch copies of one session survive
# together.
#
# HAE delivers two JSON files per session — the watch recording and the
# Garmin-Connect-mirrored copy — and caches written before the
# HAE-to-HAE dedup existed can hold both. When a Garmin fragment loses to
# that pair, removing the fragment alone leaves two rows for one session,
# which is the double count this whole cleanup exists to remove.
#
# The survivors are chosen per session, not per fragment. Choosing per
# fragment made the answer depend on the order the fragments were walked
# in: a row picked as the best copy of one fragment could be struck as
# surplus for the next, and a session could end up with every row gone.
# Grouping the rows by the session they describe and keeping the fullest
# of each group cannot do that — every group keeps exactly one row, and
# neither grouping nor .best_copy() depends on order.
.surplus_aw_copies <- function(dups, summaries) {
  aw <- which(dups$winner == "aw")
  if (length(aw) < 2) return(integer(0))

  groups <- .session_groups(summaries[dups$idx[aw], , drop = FALSE],
                            same_sport = TRUE)
  surplus <- integer(0)
  for (g in groups) {
    if (length(g) < 2) next
    best <- g[.best_copy(dups$distance_hae[aw[g]], dups$duration_hae[aw[g]])]
    surplus <- c(surplus, dups$idx[aw[setdiff(g, best)]])
  }
  sort(unique(surplus))
}

# Apple Watch rows that duplicate another Apple Watch row, with no
# Garmin recording of the session at all.
#
# The importer has deduplicated HAE against HAE since this work began,
# but rows imported before that stayed, and the Garmin sweep never sees
# them: it starts from a Garmin row, and these sessions have none.
#
# Same rule as everywhere else — rows that match each other are one
# session, the fullest is kept — with one addition of its own: the
# comparison is bucketed by time first. Copies of a session are seconds
# apart, so rows more than a few hours apart cannot be copies, and
# comparing every wrist row with every other one would be several
# million comparisons for nothing.
.surplus_hae_copies <- function(summaries, window_hours = 6) {
  if (!is.data.frame(summaries) || !"source" %in% names(summaries)) {
    return(integer(0))
  }
  idx <- which(!is.na(summaries$source) & summaries$source == "hae")
  if (length(idx) < 2) return(integer(0))

  idx <- idx[order(summaries$sessionStart[idx])]
  starts <- as.numeric(summaries$sessionStart[idx])
  gap <- c(Inf, diff(starts))
  bucket <- cumsum(gap > window_hours * 3600)

  surplus <- integer(0)
  for (b in unique(bucket)) {
    rows_idx <- idx[bucket == b]
    if (length(rows_idx) < 2) next
    rows <- summaries[rows_idx, , drop = FALSE]
    # Same device on both sides, so the labels mean something: a ride
    # and a run whose edges overlap are two sessions, not one recorded
    # twice. Commuting by bike with a run in the middle produces exactly
    # that shape.
    for (g in .session_groups(rows, same_sport = TRUE)) {
      if (length(g) < 2) next
      best <- g[.best_copy(rows$distance[g], rows$duration[g])]
      surplus <- c(surplus, rows_idx[setdiff(g, best)])
    }
  }
  sort(unique(surplus))
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
  # Sessions the watch recorded twice and Garmin not at all: invisible to
  # the sweep above, which starts from a Garmin row.
  hae_copies <- setdiff(.surplus_hae_copies(summaries), dups$idx)
  # Carried on every return path, dry run included, so a caller can see
  # what the second sweep found without re-running it.
  attr(dups, "hae_copies") <- hae_copies

  n_aw <- sum(dups$winner == "aw")
  if (verbose) {
    cat("Dubblettsökning: ", nrow(summaries), " rader, ",
        nrow(dups), " Apple Watch-rader har en Garmin-tvilling",
        if (n_aw > 0) paste0(" (", n_aw, " där Garmin bara fångade ",
                             "ett fragment — AW-raden behålls)") else "",
        ".\n", sep = "")
    if (length(hae_copies) > 0) {
      cat("HAE-kopior utan Garmin-tvilling: ", length(hae_copies),
          " rader att ta bort.\n", sep = "")
    }
    if (nrow(dups) > 0) {
      shown <- if (is.null(limit)) dups else utils::head(dups, limit)
      out <- data.frame(
        datum = format(shown$sessionStart, "%Y-%m-%d %H:%M"),
        sport = shown$sport,
        `hae_m` = round(shown$distance_hae),
        `tcx_m` = round(shown$distance_tcx),
        `dt_s` = round(shown$dt_seconds),
        `slut_s` = round(shown$end_gap_seconds),
        behåller = ifelse(shown$winner == "garmin", "Garmin", "AW"),
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

  if (nrow(dups) == 0 && length(hae_copies) == 0) {
    if (verbose) cat("Inget att rensa.\n")
    return(invisible(dups))
  }

  if (dry_run) {
    if (verbose) {
      cat("Torrkörning — inget skrivet. Kör med dry_run = FALSE ",
          "(CLI: traning dedup --apply) för att ta bort.\n", sep = "")
    }
    return(invisible(dups))
  }

  aligned <- .align_myruns(summaries, myruns)
  summaries <- aligned$summaries
  myruns <- aligned$myruns

  # This path deliberately does NOT group the matched rows into sessions
  # the way the two import paths do, and the omission is a decision, not
  # an oversight — please do not "complete the class" here without
  # re-running the measurement below.
  #
  # Grouping would guard against a Garmin row that wins against two
  # different sessions and retires both. Measured against the pre-cleanup
  # cache, every formulation of that guard costs real duplicates:
  #   no guard                                       321 candidates
  #   Garmin may take only one group                 241  (80 lost)
  #   ... only groups inside its own interval        245  (76 lost)
  #   ... only when a winning group reaches outside  317   (4 lost)
  # The reason is that the harmful shape and the commonest real one are
  # structurally the same. A wrist recording stopped and restarted during
  # a run leaves several segments that do not match each other but are
  # all the same outing — 2018-11-02 has four, of 1440, 774, 4624 and
  # 1888 m, inside one 13 196 m Garmin run — and retiring all of them is
  # exactly right. The four the narrowest guard still costs are a watch
  # left running a few minutes past the Garmin stop, which the product
  # owner counts as the same session.
  #
  # The shape the guard would protect against does not occur in the data,
  # and import_hae_workouts() now turns away any file that matches two
  # sessions, so it cannot be introduced. Before running --apply against
  # a cache that has not been measured, count the ambiguous candidates:
  #
  #   suppressMessages(devtools::load_all("~/dev/traning", quiet = TRUE))
  #   cache <- file.path(Sys.getenv("TRANING_DATA"), "cache")
  #   s <- my_dbs_load(file.path(cache, "summaries.RData"),
  #                    file.path(cache, "myruns.RData"),
  #                    load_myruns = FALSE)$summaries
  #   hae <- which(!is.na(s$source) & s$source == "hae")
  #   tcx <- s[!is.na(s$source) & s$source == "tcx", ]
  #   found <- 0L
  #   for (i in hae) {
  #     row <- s[i, , drop = FALSE]
  #     m <- which(traning:::.is_same_workout(row, tcx))
  #     if (!length(m)) next
  #     d <- m[traning:::.distinct_recordings(tcx$sessionStart[m])]
  #     v <- traning:::.garmin_verdict(row$distance, tcx$distance[d])
  #     if (is.na(v) || !v) next
  #     near <- hae[abs(as.numeric(difftime(s$sessionStart[hae],
  #                     row$sessionStart, units = "days"))) <= 1]
  #     covered <- integer(0)
  #     for (t in m) covered <- union(covered, near[traning:::.is_same_workout(
  #       tcx[t, , drop = FALSE], s[near, , drop = FALSE])])
  #     covered <- sort(as.integer(covered))
  #     g <- traning:::.session_groups(s[covered, , drop = FALSE])
  #     if (length(g) < 2) next
  #     sf <- min(as.numeric(tcx$sessionStart[d]))
  #     st <- max(as.numeric(tcx$sessionEnd[d]))
  #     won <- vapply(g, function(gg) all(traning:::.garmin_verdict(
  #       s$distance[covered[gg]], tcx$distance[d]) %in% TRUE), logical(1))
  #     inside <- vapply(g, function(gg) { r <- s[covered[gg], , drop = FALSE]
  #       isTRUE(min(as.numeric(r$sessionStart)) >= sf - 300 &&
  #              max(as.numeric(r$sessionEnd)) <= st + 300) }, logical(1))
  #     if (!(sum(won) > 1 && any(won & !inside))) next
  #     found <- found + 1L
  #     cat("--- Garmin ", format(tcx$sessionStart[d[1]], "%Y-%m-%d %H:%M"),
  #         " ", round(tcx$distance[d[1]]), " m\n", sep = "")
  #     print(data.frame(start = format(s$sessionStart[covered], "%H:%M"),
  #       slut = format(s$sessionEnd[covered], "%H:%M"),
  #       sport = s$sport[covered], m = round(s$distance[covered]),
  #       grupp = rep(seq_along(g), lengths(g)),
  #       utanfor = rep(!inside, lengths(g))), row.names = FALSE)
  #   }
  #   cat("\nTvetydiga kandidater:", found, "\n")
  #
  # Read the shapes, not just the count. On kedar's pre-cleanup cache it
  # prints 4, all of them a wrist recording overshooting the Garmin stop
  # by minutes. Anything else — two full-length sessions with the Garmin
  # row a short slice of each — is the shape this path cannot resolve:
  # stop and escalate rather than running --apply.
  #
  # Garmin fragments go first, so an Apple Watch row that lost to a
  # fragment elsewhere isn't dropped on account of a row that is itself
  # about to disappear.
  drop_tcx <- sort(unique(unlist(dups$tcx_drop)))
  drop_hae <- dups$idx[dups$winner == "garmin"]
  drop_hae <- c(drop_hae, .surplus_aw_copies(dups, summaries), hae_copies)
  drop <- sort(unique(c(drop_hae, drop_tcx)))

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
    cat("Borttaget: ", length(drop_hae), " Apple Watch-rader (varav ",
        length(hae_copies), " kopior utan Garmin-tvilling) och ",
        length(drop_tcx), " Garmin-fragment (från ", n_aw,
        " pass). Kvar: ", nrow(summaries), " rader, ", length(myruns),
        " run-objekt.\n", sep = "")
  }
  invisible(dups)
}
