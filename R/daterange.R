# Date range parsing and filtering

#' Parse a flexible date expression into a Date object
#'
#' Supported formats:
#' \itemize{
#'   \item \code{"2023"} — start of year (2023-01-01)
#'   \item \code{"2023-03"} — start of month (2023-03-01)
#'   \item \code{"2023-03-04"} — exact date
#'   \item \code{"-3w"} — 3 weeks before reference
#'   \item \code{"-1y"} — 1 year before reference
#'   \item \code{"-6m"} — 6 months before reference
#'   \item \code{"-10d"} — 10 days before reference
#'   \item \code{"3m"} — 3 months after reference (span expression)
#'   \item \code{"1y"} — 1 year after reference (span expression)
#' }
#'
#' @param expr Character string, a date expression.
#' @param reference Date, the reference date for relative expressions. Defaults to \code{Sys.Date()}.
#' @return A \code{Date} object.
#' @export
parse_date_expr <- function(expr, reference = Sys.Date()) {
  if (!nzchar(expr)) {
    stop(
      "Invalid date expression: empty string. ",
      "Valid formats: '2023', '2023-03', '2023-03-04', '-3w', '-1y', '-6m', '-10d', '3m', '1y'"
    )
  }

  # Relative expressions: optional leading minus, number, unit
  if (grepl("^-?[0-9]+(d|w|m|y)$", expr)) {
    negative <- grepl("^-", expr)
    clean <- sub("^-", "", expr)
    n <- as.integer(sub("(d|w|m|y)$", "", clean))
    unit <- sub("^[0-9]+", "", clean)

    delta <- switch(unit,
      d = lubridate::days(n),
      w = lubridate::weeks(n),
      m = lubridate::period(n, "month"),
      y = lubridate::years(n)
    )

    if (negative) {
      return(as.Date(reference - delta))
    } else {
      return(as.Date(reference + delta))
    }
  }

  # Absolute: year only
  if (grepl("^[0-9]{4}$", expr)) {
    return(as.Date(paste0(expr, "-01-01")))
  }

  # Absolute: year-month
  if (grepl("^[0-9]{4}-[0-9]{2}$", expr)) {
    return(as.Date(paste0(expr, "-01")))
  }

  # Absolute: year-month-day
  if (grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", expr)) {
    parsed <- as.Date(expr)
    if (is.na(parsed)) {
      stop("Invalid date expression: '", expr, "' could not be parsed as a date.")
    }
    return(parsed)
  }

  stop(
    "Invalid date expression: '", expr, "'. ",
    "Valid formats: '2023', '2023-03', '2023-03-04', '-3w', '-1y', '-6m', '-10d', '3m', '1y'"
  )
}

#' Build a date range from CLI flag values
#'
#' Returns a list with \code{from} and \code{to} as \code{Date} objects or \code{NULL}.
#'
#' @param after Character string or NULL. Start of range (inclusive). Parsed by \code{parse_date_expr()}.
#' @param before Character string or NULL. End of range (exclusive). Parsed by \code{parse_date_expr()}.
#' @param span Character string or NULL. Duration from \code{after}. Requires \code{after};
#'   incompatible with \code{before}. E.g. \code{"3m"}, \code{"1y"}.
#' @return A list with elements \code{from} (Date or NULL) and \code{to} (Date or NULL).
#' @export
build_date_range <- function(after = NULL, before = NULL, span = NULL) {
  if (!is.null(span) && !is.null(before)) {
    stop("--span and --before are mutually exclusive")
  }
  if (!is.null(span) && is.null(after)) {
    stop("--span requires --after")
  }

  from <- if (!is.null(after)) parse_date_expr(after) else NULL
  to   <- if (!is.null(before)) parse_date_expr(before) else NULL

  if (!is.null(span)) {
    to <- parse_date_expr(span, reference = from)
  }

  if (!is.null(from) && !is.null(to) && from >= to) {
    warning("Date range is empty: 'from' (", from, ") is not before 'to' (", to, ")")
  }

  list(from = from, to = to)
}

#' Filter a data frame by a date range on a given column
#'
#' Single source of truth for date-window filtering, used by both the
#' basic report functions (on \code{sessionStart}) and the advanced
#' metric reports/plots (on \code{sessionStart} or a daily \code{date}
#' column). Comparisons are done directly on \code{from}/\code{to}
#' (\code{Date} objects) against \code{date_col}, which may itself be
#' \code{Date} or \code{POSIXct} — \code{lubridate} (an Import of this
#' package, always loaded alongside it) registers the group generics that
#' make \code{Date}/\code{POSIXct} comparisons well-defined and
#' timezone-aware (comparison happens in \code{date_col}'s own tzone, so a
#' local-midnight session sorts into the correct calendar day). Do
#' \strong{not} pre-convert with \code{as.Date()} here: \code{as.Date()} on
#' a \code{POSIXct} defaults to \strong{UTC} truncation unless \code{tz} is
#' passed explicitly, which silently shifts sessions near local midnight
#' into the wrong calendar day for any zone with a non-zero UTC offset
#' (e.g. Europe/Stockholm) — this was a latent bug in the pre-consolidation
#' \code{.filter_date_range()} (former \code{R/plot.R}) for its four
#' \code{sessionStart} call sites (EF, HRE, RHR, decoupling).
#'
#' @param summaries A tibble with a date-like column named \code{date_col}.
#' @param date_range A list with \code{from} and \code{to} elements, as returned by
#'   \code{build_date_range()}. Either element may be \code{NULL}.
#' @param date_col Character, name of the date-like column to filter on.
#'   Defaults to \code{"sessionStart"}.
#' @param closed_upper Logical. \code{FALSE} (default) treats \code{to} as an
#'   exclusive upper bound (\code{<}) — use for \code{POSIXct}/session-level
#'   columns, where a datetime is a momentary event that may still be in
#'   progress. \code{TRUE} treats \code{to} as inclusive (\code{<=}) — use for
#'   \code{Date} columns representing a finalised calendar day (daily
#'   aggregates: ACWR, monotony/strain, PMC, HR-zones, PI-zones, run-mix). See
#'   \code{docs/dev/filter-consistency.md}.
#' @return The filtered tibble.
#' @export
filter_by_daterange <- function(summaries, date_range, date_col = "sessionStart",
                                 closed_upper = FALSE) {
  from <- date_range$from
  to   <- date_range$to

  if (is.null(from) && is.null(to)) {
    return(summaries)
  }

  if (!is.null(from)) {
    summaries <- dplyr::filter(summaries, .data[[date_col]] >= from)
  }

  if (!is.null(to)) {
    summaries <- if (closed_upper) {
      dplyr::filter(summaries, .data[[date_col]] <= to)
    } else {
      dplyr::filter(summaries, .data[[date_col]] < to)
    }
  }

  summaries
}

# Filter a data frame by date range on date_col, or fall back to the last
# n rows (by date_col) when no from/to bound was given. Always returns
# rows ordered newest first — callers display top-to-bottom. Built on
# filter_by_daterange() so the from/to semantics (including closed_upper)
# stay identical to the plain-filter case.
.filter_or_tail <- function(data, n, from, to, date_col, closed_upper = FALSE) {
  if (!is.null(from) || !is.null(to)) {
    data <- filter_by_daterange(data, list(from = from, to = to),
                                 date_col = date_col, closed_upper = closed_upper)
  } else {
    data <- utils::tail(data, n = n)
  }
  dplyr::arrange(data, dplyr::desc(.data[[date_col]]))
}
