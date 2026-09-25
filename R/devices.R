# Device log: read + query the daterad enhetslogg (watch/firmware
# changes), and small ggplot2 helpers to mark those changes on health
# and Garmin-based plots.
#
# Schema (see $TRANING_DATA/kristian/devices.csv, written by the Python
# CLI/FIT-scan track):
#   valid_from,platform,model,os_version,certainty,origin,note
#   - valid_from: YYYY-MM-DD, the file is newest-first
#   - platform:   apple_watch | garmin
#   - model / os_version: may be empty
#   - certainty:  exact | known_since
#   - origin:     manual | fit | tcx | healthkit — fit/tcx are derived
#     from the historical Garmin FIT/TCX archive, healthkit from an
#     Apple HealthKit export. All four are treated identically
#     everywhere in R/Vayu; origin only matters as provenance for the
#     row, never as a filter condition here.
#   - note:       free text
#
# The file may not exist yet (or ever, for a user who never records
# device changes) — read_device_log() treats a missing file as "no
# changes", not an error, so every downstream consumer degrades to
# "no annotation" rather than crashing.

# Internal helper: resolve the default devices.csv path.
.default_device_log_path <- function() {
  data_root <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  if (is.na(data_root) || !nzchar(data_root)) {
    return(NA_character_)
  }
  file.path(data_root, "kristian", "devices.csv")
}

# Internal helper: the empty tibble shape read_device_log()/device_changes()
# always fall back to, so callers never need to branch on "no data".
.empty_device_log <- function() {
  tibble::tibble(
    valid_from = as.Date(character()),
    platform   = character(),
    model      = character(),
    os_version = character(),
    certainty  = character(),
    origin     = character(),
    note       = character()
  )
}

# Internal helper: coerce a from/to bound (character, Date, or NULL) to
# Date or NULL, without erroring on NA/"".
.as_date_or_null <- function(x) {
  if (is.null(x) || (length(x) == 1 && is.na(x))) {
    return(NULL)
  }
  as.Date(x)
}

# Internal helper: strip an os_version string to its leading numeric run
# ("9.1" -> "9.1", "watchOS 26.6" -> "26.6") so numeric_version() (which
# errors on non-numeric components) can rank it. Mirrors Python's
# log.py:_version_sort_key(). Unparseable/empty input becomes "0",
# which numeric_version() ranks below any real version — "unparseable
# never outranks a real one," the same rule as the Python mirror.
.version_for_compare <- function(os_version) {
  extracted <- stringr::str_extract(os_version, "[0-9]+(\\.[0-9]+)*")
  dplyr::coalesce(extracted, "0")
}

# Internal helper: enforce the devices.csv invariant defensively on
# read — at most one row per (platform, valid_from). devices.csv only
# carries a date, never a time; Python's write_devices()
# (python/traning_cli/devices/log.py) is the primary enforcement point
# and cleans the file on every write, but a file written by hand, or by
# a pre-invariant version of that code, can still be dirty when R reads
# it. Without this, an out-of-order same-day pair — nagelfar: an Apple
# Watch Ultra (gen 1) arriving on watchOS 9.0.1 and updating itself to
# 9.1 later the same day, both dated 2022-10-06 — would misorder
# whichever downstream consumer sorts by valid_from alone (this
# produced a fictitious "downgrade to 9.0.1" in Vayu's device-change
# note). Mirrors Python's collapse_same_day_rows(): within a
# same-(platform, day) group, the row with the highest parsed
# os_version wins and describes that day's actual end state; every
# other row in the group is folded into the winner's note as "samma
# dag: <what it was>". certainty/origin follow the winner unchanged.
# Idempotent — an already-collapsed log round-trips through this
# unchanged (every group already has size 1).
.collapse_same_day_rows <- function(log) {
  if (nrow(log) == 0) {
    return(log)
  }

  groups <- split(log, list(log$platform, log$valid_from), drop = TRUE)
  collapsed <- lapply(groups, function(rows) {
    if (nrow(rows) == 1) {
      return(rows)
    }
    versions <- numeric_version(.version_for_compare(rows$os_version))
    winner_idx <- which.max(versions)
    winner <- rows[winner_idx, ]
    losers <- rows[-winner_idx, , drop = FALSE]
    loser_notes <- vapply(seq_len(nrow(losers)), function(i) {
      l <- losers[i, ]
      what <- if (identical(l$model, winner$model)) {
        l$os_version
      } else {
        trimws(paste(l$model, l$os_version))
      }
      if (nzchar(what)) paste0("samma dag: ", what) else NA_character_
    }, character(1))
    loser_notes <- loser_notes[!is.na(loser_notes)]
    all_notes <- c(if (nzchar(winner$note)) winner$note else NULL, loser_notes)
    winner$note <- paste(all_notes, collapse = "; ")
    winner
  })

  dplyr::bind_rows(collapsed) |> dplyr::arrange(dplyr::desc(.data$valid_from))
}

#' Read the device log
#'
#' Reads the daterad device-change log written by the Python
#' \code{traning devices} CLI / FIT scan. A missing file is not an
#' error — it means no device changes have been recorded yet, so an
#' empty (but correctly typed) tibble is returned. Defensively enforces
#' the file's own invariant — at most one row per
#' \code{(platform, valid_from)} — via \code{.collapse_same_day_rows()},
#' in case the file on disk predates that invariant or was hand-edited;
#' the write-time enforcement in \code{python/traning_cli/devices/log.py}
#' is the primary source of truth.
#'
#' @param path Path to \code{devices.csv}. Defaults to
#'   \code{$TRANING_DATA/kristian/devices.csv}.
#' @return Tibble with columns \code{valid_from} (Date), \code{platform},
#'   \code{model}, \code{os_version}, \code{certainty}, \code{origin},
#'   \code{note} — sorted newest first.
#' @export
read_device_log <- function(path = .default_device_log_path()) {
  if (is.na(path) || !nzchar(path) || !file.exists(path)) {
    return(.empty_device_log())
  }

  raw <- utils::read.csv(
    path,
    stringsAsFactors = FALSE,
    colClasses = "character",
    encoding = "UTF-8"
  )

  required_cols <- c(
    "valid_from", "platform", "model", "os_version",
    "certainty", "origin", "note"
  )
  missing_cols <- setdiff(required_cols, names(raw))
  if (length(missing_cols) > 0) {
    warning(
      "Device log missing expected column(s): ",
      paste(missing_cols, collapse = ", "), " (", path, ")"
    )
    return(.empty_device_log())
  }

  if (nrow(raw) == 0) {
    return(.empty_device_log())
  }

  raw |>
    tibble::as_tibble() |>
    dplyr::transmute(
      valid_from = as.Date(.data$valid_from),
      platform   = .data$platform,
      model      = dplyr::coalesce(.data$model, ""),
      os_version = dplyr::coalesce(.data$os_version, ""),
      certainty  = .data$certainty,
      origin     = .data$origin,
      note       = dplyr::coalesce(.data$note, "")
    ) |>
    .collapse_same_day_rows() |>
    dplyr::arrange(dplyr::desc(.data$valid_from))
}

#' Device changes within a period
#'
#' Filters a device log (as returned by \code{read_device_log()}) to a
#' platform and/or date range. \code{after}/\code{before} bound
#' \code{valid_from} inclusively on both ends; \code{NULL} means
#' unbounded on that side.
#'
#' Also attaches an \code{is_model_change} column: \code{TRUE} when a
#' row is an actual device swap, \code{FALSE} when it's a firmware/OS
#' bump on the same device as the next older row (see
#' \code{.is_device_model_change()}). Classification is computed
#' against each platform's FULL recorded history in \code{log} —
#' before \code{after}/\code{before} narrow the result — specifically
#' so the oldest row inside a requested window is compared against the
#' real previous device, not misclassified as a swap just because nothing
#' older happens to be in the returned window (nagelfar: the row before
#' the window still has to be visible to this comparison).
#'
#' @param log Tibble from \code{read_device_log()} (or another call to
#'   \code{device_changes()}) — must carry the platform's full history
#'   for \code{is_model_change} to be correct; passing an
#'   already-windowed subset here would reintroduce the boundary bug
#'   this function exists to avoid.
#' @param platform Optional platform filter (\code{"apple_watch"} or
#'   \code{"garmin"}). \code{NULL} = no filter (classification is still
#'   done per platform, never across platforms).
#' @param after Optional lower date bound (character or Date).
#' @param before Optional upper date bound (character or Date).
#' @return Tibble, \code{log}'s columns plus \code{is_model_change},
#'   newest first.
#' @export
device_changes <- function(log, platform = NULL, after = NULL, before = NULL) {
  empty <- dplyr::mutate(.empty_device_log(), is_model_change = logical())
  if (is.null(log) || nrow(log) == 0) {
    return(empty)
  }

  out <- log

  if (!is.null(platform)) {
    out <- out |> dplyr::filter(.data$platform == !!platform)
  }
  if (nrow(out) == 0) {
    return(empty)
  }

  # Classify against each platform's full history (everything in `out`
  # so far — platform-filtered but NOT yet date-filtered) before the
  # date window below narrows what's returned.
  out <- out |> dplyr::arrange(dplyr::desc(.data$valid_from))
  out <- dplyr::bind_rows(lapply(split(out, out$platform), function(rows) {
    rows$is_model_change <- .is_device_model_change(rows)
    rows
  }))

  after_date <- .as_date_or_null(after)
  before_date <- .as_date_or_null(before)

  if (!is.null(after_date)) {
    out <- out |> dplyr::filter(.data$valid_from >= after_date)
  }
  if (!is.null(before_date)) {
    out <- out |> dplyr::filter(.data$valid_from <= before_date)
  }

  out |> dplyr::arrange(dplyr::desc(.data$valid_from))
}

# --- Plot annotation helpers --------------------------------------------

# Internal helper: short Swedish label for a device-change row, e.g.
# "Ultra · watchOS 26.6". Falls back to note, then a generic label,
# so a row with only certainty/origin filled in still renders something.
.device_change_label <- function(changes) {
  label <- dplyr::case_when(
    nzchar(changes$model) & nzchar(changes$os_version) ~
      paste(changes$model, changes$os_version, sep = " · "),
    nzchar(changes$model) ~ changes$model,
    nzchar(changes$os_version) ~ changes$os_version,
    nzchar(changes$note) ~ changes$note,
    TRUE ~ "Enhetsbyte"
  )
  label
}

# Internal helper: bounds for the device-change window, matching the
# effective date range of a plot. `from`/`to` win when given (a caller
# explicitly filtered the plot to a range); otherwise fall back to the
# min/max of the plotted data's own dates, so an unbounded plot doesn't
# pull in changes from outside what's actually drawn.
.plot_date_bounds <- function(from, to, dates) {
  list(
    after = if (!is.null(from)) .as_date_or_null(from) else suppressWarnings(min(dates, na.rm = TRUE)),
    before = if (!is.null(to)) .as_date_or_null(to) else suppressWarnings(max(dates, na.rm = TRUE))
  )
}

# Internal helper: flag which rows of a (desc-sorted) device-change
# tibble represent an actual model swap, as opposed to a firmware/OS
# bump on the same device. A row counts as a model change when its
# `model` is non-empty and differs from the next OLDER row's model
# (or there is no older row in view — the earliest known device in
# the window is always worth labelling). Garmin firmware history in
# particular can carry 20+ rows for the same handful of watches, so
# this is what lets .device_change_layers() thin the label set down
# to "device swaps" while still drawing every change as a line.
.is_device_model_change <- function(changes) {
  n <- nrow(changes)
  if (n == 0) {
    return(logical(0))
  }
  # changes is newest-first; row i's chronologically-older neighbour is
  # row i+1. The oldest row (last) has no older neighbour → NA -> TRUE.
  older_model <- c(changes$model[-1], NA_character_)
  nzchar(changes$model) & (is.na(older_model) | changes$model != older_model)
}

# Internal helper: build the geom_vline + geom_text layer pair marking
# device changes on a plot. Returns list() (a no-op when added to a
# ggplot) when there's nothing to show, so callers can unconditionally
# do `p <- p + .device_change_layers(...)`.
#
# @param changes Tibble from device_changes(), already filtered to the
#   plot's platform and date range. `valid_from` (Date) is used as-is —
#   every caller so far (Apple Watch health plots on Date x-axes,
#   fetch.plot.ef / fetch.plot.decoupling on scale_x_datetime() but
#   backed by a Date `sessionStart` column) plots against a Date-typed
#   x aesthetic.
# @param many_threshold When more than this many changes fall in the
#   window (Garmin firmware history can run to 20+ over the full
#   2004-2026 history), only model swaps get a text label; every change
#   still gets a line, just fainter and unlabelled when it's "the same
#   watch, new firmware". Swap classification is read from `changes`'s
#   own `is_model_change` column when present — device_changes()
#   computes it against each platform's FULL history, which is required
#   for a correct answer at the window's oldest row (see that
#   function's docs); a hand-built `changes` without the column falls
#   back to classifying within just what's here, which is only correct
#   when `changes` already represents the complete history in view.
.device_change_layers <- function(changes, many_threshold = 6) {
  if (is.null(changes) || nrow(changes) == 0) {
    return(list())
  }

  changes$.x <- changes$valid_from
  changes$.label <- .device_change_label(changes)

  many <- nrow(changes) > many_threshold
  is_model_change <- if (!many) {
    rep(TRUE, nrow(changes))
  } else if ("is_model_change" %in% names(changes)) {
    changes$is_model_change
  } else {
    .is_device_model_change(changes)
  }

  labelled <- changes[is_model_change, , drop = FALSE]
  unlabelled <- changes[!is_model_change, , drop = FALSE]

  layers <- list(
    ggplot2::geom_vline(
      data = labelled, ggplot2::aes(xintercept = .x),
      colour = traning_palette$secondary, linetype = "dashed",
      linewidth = 0.5, alpha = 0.6
    ),
    ggplot2::geom_text(
      data = labelled, ggplot2::aes(x = .x, y = Inf, label = .label),
      angle = 90, hjust = 1.1, vjust = -0.3, size = 2.6,
      colour = traning_palette$secondary
    )
  )

  if (nrow(unlabelled) > 0) {
    layers <- c(layers, list(
      ggplot2::geom_vline(
        data = unlabelled, ggplot2::aes(xintercept = .x),
        colour = traning_palette$secondary, linetype = "dotted",
        linewidth = 0.4, alpha = 0.4
      )
    ))
  }

  layers
}
