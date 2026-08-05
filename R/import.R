# Data I/O: load, save, and import workout data

# Workaround for trackeR 1.6.1 bug: change_units() uses get() to find
# unit conversion functions by name in the calling environment, but they
# are not exported from the trackeR namespace. Copy all conversion
# functions into this package's namespace so get() can find them.
.onLoad <- function(libname, pkgname) {
  ns <- asNamespace("trackeR")
  pkg_env <- parent.env(environment())
  for (fn_name in ls(ns, pattern = "2")) {
    obj <- get(fn_name, envir = ns)
    if (is.function(obj)) {
      assign(fn_name, obj, envir = pkg_env)
    }
  }

  # S7 packages must call methods_register() on load so that methods for
  # external generics (e.g. base::print, base::format for the S7 classes
  # in R/traning_data.R) are registered correctly. See ?S7::methods_register.
  S7::methods_register()

  # Load the shared metric taxonomy (inst/metric_taxonomy.json, shared
  # with the Python side) once per session rather than re-reading the
  # JSON on every call. .sum_metrics is used throughout R/health_export.R
  # via `%in% .sum_metrics`.
  taxonomy <- .load_metric_taxonomy()
  .sum_metrics <<- taxonomy$sum_metrics
}

# Copy the non-structural attributes of `old` onto `new`. Base
# subsetting of a data frame drops them, and one of them —
# "garmin_augmented_at" — is what stops inst/cli.R from re-running the
# (expensive) Garmin augmentation on every invocation.
.restore_df_attrs <- function(new, old) {
  structural <- c("names", "row.names", "class", "dim", "dimnames")
  for (a in setdiff(names(attributes(old)), structural)) {
    attr(new, a) <- attr(old, a)
  }
  new
}

#' Identify summaries rows so a set of them can be recognised later
#'
#' Row positions are not a usable identity across an import: rows are
#' appended by two importers in turn and removed in between, so "the
#' last n rows" answers a different question than "the rows that were
#' added".
#'
#' The key is the session start and the source, and deliberately not the
#' file. A rename — the same session found again under a new path, with
#' the old one gone from disk — rewrites `file` in place without adding
#' anything, and including it would make that row look new. The pair is
#' unique in any saved cache, since `my_dbs_save()` deduplicates on
#' exactly those two columns, and neither importer appends a row whose
#' pair already exists.
#'
#' @param summaries Summaries data frame.
#' @return Character vector, one key per row.
#' @keywords internal
.summary_row_keys <- function(summaries) {
  if (!is.data.frame(summaries) || nrow(summaries) == 0) return(character(0))
  col <- function(name) {
    if (name %in% names(summaries)) as.character(summaries[[name]])
    else rep(NA_character_, nrow(summaries))
  }
  paste(col("sessionStart"), col("source"), sep = "\u001f")
}

#' Bring `myruns` back to the same length as `summaries`
#'
#' `myruns` is coupled to `summaries` by position only, and caches
#' written before that coupling was enforced can be off by a handful of
#' entries. Pad with `NULL` placeholders (or drop unreachable trailing
#' entries) rather than letting the mismatch propagate silently.
#'
#' @param summaries Summaries data frame.
#' @param myruns List of trackeR run objects.
#' @param quiet Logical. Suppress the message describing the repair.
#' @return List with `summaries` (unchanged) and a length-corrected `myruns`.
#' @keywords internal
.align_myruns <- function(summaries, myruns, quiet = FALSE) {
  n <- nrow(summaries)
  if (is.null(myruns)) myruns <- list()
  if (length(myruns) == n) return(list(summaries = summaries, myruns = myruns))

  # An entirely empty myruns is the documented "summaries-only cache"
  # shape, not corruption — pad it without the alarm. A *partial*
  # mismatch is the signal worth surfacing.
  if (!quiet && length(myruns) > 0) {
    message("myruns/summaries ur synk: ", length(myruns), " run-objekt mot ",
            n, " rader — justerar längden.")
  }
  if (length(myruns) < n) {
    myruns <- c(myruns, vector("list", n - length(myruns)))
  } else {
    # Entries past the last summaries row are unreachable by any caller.
    myruns <- myruns[seq_len(n)]
  }
  list(summaries = summaries, myruns = myruns)
}

#' Save summaries and myruns to RData files
#'
#' `summaries` is sorted by `sessionStart` and deduplicated per source
#' before writing. `myruns` is reordered and subset by the *same*
#' permutation: the two objects are coupled by position, so sorting one
#' without the other silently pairs every row with the wrong trackeR run.
#'
#' @param db_summaries Path to summaries.RData
#' @param db_myruns Path to myruns.RData
#' @param summaries Data frame of workout summaries
#' @param myruns List of trackeR run objects
#' @export
my_dbs_save <- function(db_summaries, db_myruns, summaries, myruns) {
  aligned <- .align_myruns(summaries, myruns)
  summaries <- aligned$summaries
  myruns <- aligned$myruns

  if (nrow(summaries) > 0) {
    old <- summaries
    # order() on a POSIXct is stable, matching dplyr::arrange()'s
    # tie behaviour, and gives us the permutation to apply to myruns.
    ord <- order(summaries$sessionStart)
    summaries <- summaries[ord, , drop = FALSE]
    myruns <- myruns[ord]

    # Dedup within a source (exact-second match). Cross-source dedup runs
    # at import time (with a tolerance window) — see import_hae_workouts()
    # and get_new_workouts() — and retroactively via dedup_summaries().
    key <- if ("source" %in% names(summaries)) {
      data.frame(sessionStart = summaries$sessionStart,
                 source = summaries$source)
    } else {
      data.frame(sessionStart = summaries$sessionStart)
    }
    keep <- !duplicated(key)
    summaries <- summaries[keep, , drop = FALSE]
    myruns <- myruns[keep]

    rownames(summaries) <- NULL
    summaries <- .restore_df_attrs(summaries, old)
  }

  save_atomic(myruns, file = db_myruns)
  save_atomic(summaries, file = db_summaries)
}

#' Load summaries and myruns from RData files
#' @param db_summaries Path to summaries.RData
#' @param db_myruns Path to myruns.RData
#' @param load_myruns Logical; whether to load `db_myruns` (default TRUE).
#'   The myruns cache is typically ~89MB, dwarfing summaries.RData — set to
#'   FALSE for callers that only need `summaries` (e.g. the Shiny landing
#'   page's initial load) and want to skip that cost. When FALSE, `myruns`
#'   is returned as `list()` regardless of what's on disk.
#' @return List with elements "summaries" and "myruns"
#' @export
my_dbs_load <- function(db_summaries, db_myruns, load_myruns = TRUE) {
  if (file.exists(db_summaries)) {
    load(db_summaries)
  } else {
    summaries <- data.frame()
  }
  if (load_myruns && file.exists(db_myruns)) {
    load(db_myruns)
  } else {
    myruns <- list()
  }

  # Strip trackeRdataSummary class — its [ method conflicts with dplyr
  if (inherits(summaries, "trackeRdataSummary")) {
    class(summaries) <- "data.frame"
  }

  # Backfill source column for caches predating multi-source support.
  if (is.data.frame(summaries) && nrow(summaries) > 0 &&
      !"source" %in% names(summaries)) {
    summaries$source <- "tcx"
  }

  # Report — but don't repair — a positional mismatch between the two
  # caches. Repairing here would silently rewrite what the caller sees
  # without writing it back; my_dbs_save() does the actual alignment.
  if (load_myruns && is.data.frame(summaries) && length(myruns) > 0 &&
      length(myruns) != nrow(summaries)) {
    message("Varning: myruns (", length(myruns), ") och summaries (",
            nrow(summaries), ") har olika längd — ",
            "positionskopplingen är ur synk. ",
            "Nästa my_dbs_save() justerar längden.")
  }

  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
  return(my_templist)
}

#' List all TCX files in a directory
#' @param mytcxpath Path to directory containing TCX files
#' @return Character vector of full file paths
#' @export
get_my_files <- function(mytcxpath) {
  files <- list.files(
    path = mytcxpath,
    recursive = TRUE,
    pattern = "*.tcx",
    ignore.case = TRUE,
    full.names = TRUE
  )
  return(files)
}

#' Import new TCX workouts not already in summaries
#'
#' Each newly imported Garmin session also evicts any Apple Watch
#' (`source == "hae"`) row describing the same workout — the HAE push
#' usually beats the Garmin fetch, so without this the pair survives as
#' two sessions. Garmin wins; matching follows `.is_same_workout()`.
#'
#' @param files Character vector of TCX file paths
#' @param summaries Existing summaries data frame
#' @param myruns Existing myruns list
#' @param verbose Logical, print progress messages (default FALSE)
#' @return List with elements "summaries", "myruns", "n_imported",
#'   "n_updated", "n_hae_removed" and "n_garmin_fragments". `n_imported`
#'   counts appended rows, which is not the same as the change in row
#'   count: a session that evicts its Apple Watch twin adds one row and
#'   removes another.
#' @export
get_new_workouts <- function(files, summaries, myruns, verbose = FALSE,
                             batch_size = 500,
                             db_summaries = NULL, db_myruns = NULL) {
  # Every myruns index used below — the slot the new session lands on, the
  # slots evicted HAE rows vacate — assumes the two objects already line
  # up. Correct the length on the way in rather than on the way out: a
  # myruns list longer than summaries would otherwise have a real run
  # object overwritten by the first import of the batch.
  aligned <- .align_myruns(summaries, myruns)
  summaries <- aligned$summaries
  myruns <- aligned$myruns

  # Match on basename to handle relative vs absolute path mismatches
  existing_basenames <- if ("file" %in% names(summaries))
    basename(summaries$file[!is.na(summaries$file)]) else character(0)
  existing_starts <- if ("sessionStart" %in% names(summaries))
    summaries$sessionStart else as.POSIXct(character(0))
  n_imported <- 0
  n_updated <- 0
  n_hae_removed <- 0
  n_garmin_fragments <- 0
  # Garmin legs parked for the second pass below, where they are weighed
  # as a group rather than one at a time.
  deferred <- list()

  # Append one parsed session and evict the Apple Watch rows it replaces.
  # Shared by the loop and the second pass so the myruns bookkeeping —
  # the slot the row lands on, the slots the evicted rows vacate — exists
  # in one place only.
  append_session <- function(run_summary, parsed, dup, thefile, ss) {
    if (nrow(summaries) == 0) {
      summaries <<- run_summary
    } else {
      summaries <<- .rbind_align(summaries, run_summary)
    }
    # Index by the row position this session actually landed on, not by
    # any loop counter: files are skipped without touching summaries, so
    # the two drift apart and indexing by the counter silently paired a
    # row with the wrong trackeR object.
    myruns[[nrow(summaries)]] <<- parsed
    existing_basenames <<- c(existing_basenames, basename(thefile))
    existing_starts <<- c(existing_starts, ss)
    n_imported <<- n_imported + 1

    # Done after the append so the positions removed here cannot disturb
    # the myruns slot just assigned.
    if (length(dup) > 0) {
      summaries <<- .restore_df_attrs(summaries[-dup, , drop = FALSE], summaries)
      rownames(summaries) <<- NULL
      if (length(myruns) > 0) {
        drop_runs <- dup[dup <= length(myruns)]
        if (length(drop_runs) > 0) myruns <<- myruns[-drop_runs]
      }
      existing_starts <<- existing_starts[-dup]
      n_hae_removed <<- n_hae_removed + length(dup)
    }
  }

  # Apple Watch rows describing the same session as `row`.
  matching_hae <- function(row) {
    if (!"source" %in% names(summaries) || nrow(summaries) == 0) {
      return(integer(0))
    }
    idx <- which(!is.na(summaries$source) & summaries$source == "hae")
    if (length(idx) == 0) return(integer(0))
    idx[.is_same_workout(row, summaries[idx, , drop = FALSE])]
  }

  # Distances of the Garmin rows already cached for the session that the
  # Apple Watch rows `dup` describe.
  #
  # Keyed on the Apple Watch row rather than on the incoming file, because
  # two legs of one session do not match *each other*: they are
  # consecutive, half an hour apart, and neither overlaps the other. What
  # makes them one session is that each matches the same wrist recording,
  # which spans them both.
  cached_garmin_distances <- function(dup) {
    if (length(dup) == 0 ||
        !all(c("source", "distance") %in% names(summaries))) {
      return(numeric(0))
    }
    idx <- which(!is.na(summaries$source) & summaries$source == "tcx")
    if (length(idx) == 0) return(numeric(0))
    # Every Apple Watch row this session matched, not just the first of
    # them. The two copies HAE writes do not span quite the same window,
    # so an early leg can belong to one copy and a late leg to the other;
    # anchoring on one copy then hides the leg that belongs to the other,
    # and the arriving leg is dismissed as a fragment for good. The
    # eviction already takes every matched copy, so the session is what
    # any of them recognises.
    legs <- integer(0)
    for (h in dup) {
      legs <- union(legs, idx[.is_same_workout(
        summaries[h, , drop = FALSE], summaries[idx, , drop = FALSE])])
    }
    legs <- sort(as.integer(legs))
    # One recording cached under two names counts once.
    legs <- legs[.distinct_recordings(summaries$sessionStart[legs])]
    as.numeric(summaries$distance[legs])
  }

  for (i in seq_along(files)) {
    thefile <- files[[i]]
    if (basename(thefile) %in% existing_basenames) {
      if (verbose) {
        cat("Redan inläst: ", basename(thefile), "\n", sep = "")
      }
    } else {
      if (verbose) {
        cat("Läser in ", basename(files[[i]]), " ... ", sep = "")
      }
      parsed <- tryCatch({
        trackeR::read_container(files[[i]])
      }, error = function(e) {
        warning("Kunde inte läsa: ", basename(files[[i]]),
                " (", conditionMessage(e), ")", call. = FALSE)
        NULL
      })
      if (is.null(parsed)) next

      run_summary <- summary(parsed)
      class(run_summary) <- "data.frame"

      # Dedup by sessionStart: same activity may exist under a different
      # filename (renamed TCX, symlink mismatch, etc.). If the timestamp
      # matches within 2 s, skip the file. Only update the cached filename
      # if the old file no longer exists (actual rename vs. two copies).
      ss <- run_summary$sessionStart
      dup_idx <- which(abs(difftime(existing_starts, ss, units = "secs")) < 2)
      # Only another Garmin row can be this same file under a different
      # name. An Apple Watch row starting in the same second is a
      # cross-source duplicate, and belongs to the winner rule below —
      # letting it through here overwrote the HAE row's "hae:" file key
      # with the TCX path, which both broke the row's identity and made
      # its JSON importable again on the next run.
      if (length(dup_idx) > 0 && "source" %in% names(summaries)) {
        same_source <- is.na(summaries$source[dup_idx]) |
                       summaries$source[dup_idx] == "tcx"
        dup_idx <- dup_idx[same_source]
      }
      if (length(dup_idx) > 0) {
        existing_basenames <- c(existing_basenames, basename(thefile))
        old_path <- summaries$file[dup_idx[1]]
        if (!file.exists(old_path)) {
          summaries$file[dup_idx[1]] <- thefile
          n_updated <- n_updated + 1
          if (verbose) {
            cat("dublett av ", basename(old_path),
                " (saknas), uppdaterar filnamn\n", sep = "")
          }
        } else if (verbose) {
          cat("dublett av ", basename(old_path), ", hoppar över\n", sep = "")
        }
        next
      }

      # Strip trackeRdataSummary class before dplyr operations —
      # its [ method conflicts with dplyr::mutate() and causes
      # row expansion (1 row becomes 28)
      run_summary <- add_my_columns(run_summary)
      run_summary$source <- "tcx"

      # Which cached Apple Watch rows describe this same session? Decided
      # before the append, because when Garmin loses the fragment rule the
      # right outcome is not to write its row at all.
      dup <- matching_hae(run_summary)

      # A cache without a distance column leaves the default in place:
      # .garmin_wins() on a zero-length vector would otherwise answer
      # "no row says Garmin wins" and hand the session to the watch.
      dup_distance <- if ("distance" %in% names(summaries))
        summaries$distance[dup] else NA_real_
      # Weigh this file against every Garmin row already cached for the
      # same session: the watch may have been stopped and restarted, and
      # a single leg loses to a session it only partly covers.
      garmin_total <- .garmin_total(
        c(as.numeric(run_summary$distance), cached_garmin_distances(dup)))

      # Against the *best* Apple Watch copy, not any of them. A cache can
      # hold both copies HAE delivers, the full recording and a shorter
      # mirrored one, and eviction takes every matching row — so beating
      # only the short copy would let a partial Garmin file delete the
      # complete session along with it.
      if (length(dup) > 0 &&
          !all(.garmin_wins(dup_distance, garmin_total))) {
        # Not enough on its own — but the remaining legs may be in this
        # same batch, so park it and decide once the batch is known.
        deferred[[length(deferred) + 1L]] <- list(
          row = run_summary, parsed = parsed, file = thefile, start = ss)
        existing_basenames <- c(existing_basenames, basename(thefile))
        if (verbose) {
          cat("fragment (", round(as.numeric(run_summary$distance)),
              " m), avvaktar resten av batchen\n", sep = "")
        }
        next
      }

      if (verbose) {
        cat("OK\n")
        if (length(dup) > 0) {
          cat("  ersätter ", length(dup), " Apple Watch-rad",
              if (length(dup) > 1) "er" else "", " för samma pass\n",
              sep = "")
        }
      }
      append_session(run_summary, parsed, dup, thefile, ss)

      # Checkpoint: save every batch_size imports
      if (n_imported %% batch_size == 0 &&
          !is.null(db_summaries) && !is.null(db_myruns)) {
        if (verbose) cat("  Checkpoint: ", n_imported, " importerade, sparar...\n", sep = "")
        my_dbs_save(db_summaries, db_myruns, summaries, myruns)
      }
    }
  }
  # Parking a file does not record its start, so the main loop's
  # same-source duplicate check never saw it: two copies of one recording
  # under different names both ended up here. Left alone they would be
  # summed as two legs — enough to hand Garmin a session it only recorded
  # once — and the second copy would then be appended beside the first.
  # Collapse them before anything is weighed. Everything parked is a
  # Garmin row, so matching starts is the whole test, and the window is
  # the one the main loop uses.
  if (length(deferred) > 1) {
    keep <- .distinct_recordings(
      vapply(deferred, function(e) as.numeric(e$row$sessionStart), numeric(1)))
    if (verbose) {
      for (k in which(!keep)) {
        cat("dublett av parkerad del: ", basename(deferred[[k]]$file),
            ", hoppar över\n", sep = "")
      }
    }
    deferred <- deferred[keep]
  }

  # Second pass over the parked legs. Each is weighed against everything
  # Garmin holds for its session — the legs still parked here plus any
  # already cached — so a session that arrives split across several files
  # wins as a whole even though no single file would.
  #
  # This is also how a cache cleaned under the older per-leg rule
  # converges: the legs were removed and their files left on disk, so the
  # next import re-reads them together and they take the session back.
  pending <- rep(TRUE, length(deferred))
  for (k in seq_along(deferred)) {
    entry <- deferred[[k]]
    # The same guard the main loop applies before parsing, repeated here
    # because this pass appends too: without it a second copy of a
    # recording would be added beside the first, the Apple Watch row
    # having already been taken by the first. Same-source only, for the
    # same reason as in the loop — an Apple Watch row starting in the
    # same second is the duplicate this pass exists to resolve, not a
    # copy of the file.
    near <- which(abs(as.numeric(existing_starts) -
                      as.numeric(entry$row$sessionStart)) < 2)
    if (length(near) > 0 && "source" %in% names(summaries)) {
      near <- near[near <= nrow(summaries)]
      near <- near[!is.na(summaries$source[near]) &
                   summaries$source[near] == "tcx"]
    }
    if (length(near) > 0) {
      if (verbose) {
        cat("redan inläst under annat namn: ", basename(entry$file),
            "\n", sep = "")
      }
      pending[k] <- FALSE
      next
    }
    dup <- matching_hae(entry$row)
    if (length(dup) == 0) {
      # The Apple Watch row is already gone — an earlier leg took the
      # session — so this one is simply part of it.
      append_session(entry$row, entry$parsed, integer(0), entry$file, entry$start)
      pending[k] <- FALSE
      next
    }

    # Legs of one session are siblings by way of the wrist recording they
    # both match, not by matching each other — see cached_garmin_distances().
    others <- setdiff(which(pending), k)
    other_legs <- vapply(others, function(j) {
      shared <- intersect(dup, matching_hae(deferred[[j]]$row))
      if (length(shared) > 0) as.numeric(deferred[[j]]$row$distance) else NA_real_
    }, numeric(1))
    total <- .garmin_total(c(as.numeric(entry$row$distance),
                             cached_garmin_distances(dup),
                             other_legs))
    dup_distance <- if ("distance" %in% names(summaries))
      summaries$distance[dup] else NA_real_

    if (!all(.garmin_wins(dup_distance, total))) {
      # Garmin really did catch only a fragment. Its row is not written
      # at all, and nothing on disk records that, so the file is read and
      # declined again on every import — wasted work, but the outcome is
      # stable and a persisted skip list is a larger change than this
      # warrants.
      n_garmin_fragments <- n_garmin_fragments + 1
      if (verbose) {
        cat("fragment (", round(as.numeric(entry$row$distance)),
            " m mot ", round(as.numeric(summaries$distance[dup[1]])),
            " m), Apple Watch-raden behålls\n", sep = "")
      }
      next
    }

    if (verbose) {
      cat("delpass (", round(as.numeric(entry$row$distance)),
          " m av ", round(total), " m totalt), ersätter Apple Watch-raden\n",
          sep = "")
    }
    append_session(entry$row, entry$parsed, dup, entry$file, entry$start)
    pending[k] <- FALSE
  }

  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
  my_templist[["n_imported"]] <- n_imported
  my_templist[["n_updated"]] <- n_updated
  my_templist[["n_hae_removed"]] <- n_hae_removed
  my_templist[["n_garmin_fragments"]] <- n_garmin_fragments
  return(my_templist)
}

#' Repair myruns entries that are NULL despite having a summaries row
#'
#' Goes through all summaries rows and, for each one where the
#' corresponding myruns entry is NULL or missing, attempts to re-parse
#' the original TCX file.  This repairs the gap left when files were
#' added to summaries but failed to parse into myruns on first import.
#'
#' @param files Character vector of TCX file paths (from \code{get_my_files()}).
#' @param summaries Existing summaries data frame.
#' @param myruns Existing myruns list.
#' @param verbose Logical. Print progress messages.
#' @return List with elements "summaries" and "myruns" (summaries unchanged,
#'   myruns with repaired entries).
#' @export
repair_myruns <- function(files, summaries, myruns, verbose = FALSE) {
  n_summaries <- nrow(summaries)
  file_basenames <- basename(files)

  # Hitta alla rader med saknad myruns
  null_indices <- which(vapply(seq_len(n_summaries), function(i) {
    i > length(myruns) || is.null(myruns[[i]])
  }, logical(1)))

  n_null <- length(null_indices)
  if (n_null == 0) {
    message("myruns: inga saknade poster att reparera.")
    return(list(summaries = summaries, myruns = myruns))
  }

  message("myruns-reparation: ", n_null, " saknade poster, f\u00f6rs\u00f6ker reparera ...")
  n_repaired <- 0L
  n_failed <- 0L
  n_no_file <- 0L

  for (idx in seq_along(null_indices)) {
    i <- null_indices[idx]

    if (idx %% 200 == 0 || idx == 1) {
      message("  ", idx, " / ", n_null, " ...")
    }

    # HAE rows have no on-disk TCX to re-parse; skip silently.
    if ("source" %in% names(summaries) &&
        isTRUE(summaries$source[i] == "hae")) next

    summary_file <- summaries$file[i]
    if (is.na(summary_file) || nchar(summary_file) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    match_idx <- which(file_basenames == basename(summary_file))
    if (length(match_idx) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    file_path <- files[match_idx[1]]

    myruns[[i]] <- tryCatch({
      trackeR::read_container(file_path)
    }, error = function(e) {
      n_failed <<- n_failed + 1L
      NULL
    })

    if (!is.null(myruns[[i]])) {
      n_repaired <- n_repaired + 1L
    }
  }

  message("myruns-reparation klar: ", n_repaired, " reparerade, ",
          n_failed, " misslyckade, ", n_no_file, " utan matchande fil.")

  list(summaries = summaries, myruns = myruns)
}

#' Repair myruns entries with missing per-second heart rate data
#'
#' Finds sessions where summaries has avgHeartRateMoving > 0 but the
#' corresponding myruns entry has no usable HR values (all NA or zero).
#' Re-parses the original TCX file to recover the data.
#'
#' This addresses a historical issue where trackeR silently dropped HR
#' data during import (likely a bug in an older trackeR version or a
#' TCX format variant it didn't handle well at the time).
#'
#' @param files Character vector of TCX file paths.
#' @param summaries Summaries data frame.
#' @param myruns List of trackeRdata objects.
#' @param verbose Logical.  Print progress messages.
#' @return Named list with \code{$summaries} (unchanged) and \code{$myruns}
#'   (repaired entries).
#' @export
repair_myruns_hr <- function(files, summaries, myruns, verbose = FALSE) {
  n_summaries <- nrow(summaries)
  file_basenames <- basename(files)

  # Find sessions with summary HR but no per-second HR
  has_source <- "source" %in% names(summaries)
  problem_indices <- which(vapply(seq_len(n_summaries), function(i) {
    # HAE rows have no on-disk TCX to re-parse; skip.
    if (has_source && isTRUE(summaries$source[i] == "hae")) return(FALSE)
    has_summary_hr <- !is.na(summaries$avgHeartRateMoving[[i]]) &&
                      as.numeric(summaries$avgHeartRateMoving[[i]]) > 0
    if (!has_summary_hr) return(FALSE)
    if (i > length(myruns) || is.null(myruns[[i]])) return(FALSE)
    df <- tryCatch(as.data.frame(myruns[[i]]), error = function(e) NULL)
    if (is.null(df) || !"heart_rate" %in% names(df)) return(TRUE)
    n_hr <- sum(!is.na(df$heart_rate) & df$heart_rate > 0)
    n_hr == 0
  }, logical(1)))

  n_problem <- length(problem_indices)
  if (n_problem == 0) {
    message("myruns HR: inga sessioner att reparera.")
    return(list(summaries = summaries, myruns = myruns))
  }

  message("myruns HR-reparation: ", n_problem,
          " sessioner med summary-HR men saknar per-sekund-HR ...")
  n_repaired <- 0L
  n_failed <- 0L
  n_no_file <- 0L

  for (idx in seq_along(problem_indices)) {
    i <- problem_indices[idx]

    if (idx %% 100 == 0 || idx == 1) {
      message("  ", idx, " / ", n_problem, " ...")
    }

    summary_file <- summaries$file[i]
    if (is.na(summary_file) || nchar(summary_file) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    match_idx <- which(file_basenames == basename(summary_file))
    if (length(match_idx) == 0) {
      n_no_file <- n_no_file + 1L
      next
    }

    file_path <- files[match_idx[1]]

    new_data <- tryCatch(
      trackeR::read_container(file_path),
      error = function(e) NULL
    )

    if (is.null(new_data)) {
      n_failed <- n_failed + 1L
      next
    }

    # Verify the re-parsed data actually has HR
    new_df <- tryCatch(as.data.frame(new_data), error = function(e) NULL)
    if (!is.null(new_df) && "heart_rate" %in% names(new_df) &&
        sum(!is.na(new_df$heart_rate) & new_df$heart_rate > 0) > 0) {
      myruns[[i]] <- new_data
      n_repaired <- n_repaired + 1L
    } else {
      n_failed <- n_failed + 1L
    }
  }

  message("myruns HR-reparation klar: ", n_repaired, " reparerade, ",
          n_failed, " misslyckade, ", n_no_file, " utan matchande fil.")

  list(summaries = summaries, myruns = myruns)
}
