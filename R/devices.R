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
#   - origin:     manual | fit
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

#' Read the device log
#'
#' Reads the daterad device-change log written by the Python
#' \code{traning devices} CLI / FIT scan. A missing file is not an
#' error — it means no device changes have been recorded yet, so an
#' empty (but correctly typed) tibble is returned.
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
    dplyr::arrange(dplyr::desc(.data$valid_from))
}

#' Device changes within a period
#'
#' Filters a device log (as returned by \code{read_device_log()}) to a
#' platform and/or date range. \code{after}/\code{before} bound
#' \code{valid_from} inclusively on both ends; \code{NULL} means
#' unbounded on that side.
#'
#' @param log Tibble from \code{read_device_log()}.
#' @param platform Optional platform filter (\code{"apple_watch"} or
#'   \code{"garmin"}). \code{NULL} = no filter.
#' @param after Optional lower date bound (character or Date).
#' @param before Optional upper date bound (character or Date).
#' @return Tibble, same shape as \code{log}, newest first.
#' @export
device_changes <- function(log, platform = NULL, after = NULL, before = NULL) {
  if (is.null(log) || nrow(log) == 0) {
    return(.empty_device_log())
  }

  out <- log

  if (!is.null(platform)) {
    out <- out |> dplyr::filter(.data$platform == !!platform)
  }

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
.device_change_layers <- function(changes) {
  if (is.null(changes) || nrow(changes) == 0) {
    return(list())
  }

  changes$.x <- changes$valid_from
  changes$.label <- .device_change_label(changes)

  list(
    ggplot2::geom_vline(
      data = changes, ggplot2::aes(xintercept = .x),
      colour = traning_palette$secondary, linetype = "dashed",
      linewidth = 0.5, alpha = 0.6
    ),
    ggplot2::geom_text(
      data = changes, ggplot2::aes(x = .x, y = Inf, label = .label),
      angle = 90, hjust = 1.1, vjust = -0.3, size = 2.6,
      colour = traning_palette$secondary
    )
  )
}
