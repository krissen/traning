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

#' Filter a summaries tibble by a date range
#'
#' @param summaries A tibble with a \code{sessionStart} column (POSIXct).
#' @param date_range A list with \code{from} and \code{to} elements, as returned by
#'   \code{build_date_range()}. Either element may be \code{NULL}.
#' @return The filtered tibble.
#' @export
filter_by_daterange <- function(summaries, date_range) {
  from <- date_range$from
  to   <- date_range$to

  if (is.null(from) && is.null(to)) {
    return(summaries)
  }

  if (!is.null(from) && !is.null(to)) {
    return(dplyr::filter(summaries, sessionStart >= from & sessionStart < to))
  }

  if (!is.null(from)) {
    return(dplyr::filter(summaries, sessionStart >= from))
  }

  dplyr::filter(summaries, sessionStart < to)
}
