# Sport filtering for sport-agnostic reports.
#
# Replaces the hard-coded ``str_detect(sport, "running")`` filters that
# used to be scattered across report and metric functions.  Callers pass
# a ``sport`` argument; this resolves it to a vector of bucket names and
# filters ``summaries`` accordingly.

# Curated sport buckets — group several raw sport values under one label.
.SPORT_BUCKETS <- list(
  endurance = c("running", "cycling", "walking", "swimming"),
  ballsport = c("badminton", "bordtennis", "fotboll", "tennis",
                "paddelsporter", "hockey", "fitness-spel"),
  wintersport = c("skridskosporter", "snosporter", "utforsakning"),
  gym = c("strength", "karntraning", "ovrigt")
)

# Swedish → canonical English aliases for the sport-column values.
.SPORT_ALIASES <- list(
  "löpning"  = "running",
  "lopning"  = "running",
  "cykling"  = "cycling",
  "cykel"    = "cycling",
  "gång"     = "walking",
  "gang"     = "walking",
  "promenad" = "walking",
  "simning"  = "swimming",
  "styrka"   = "strength",
  "styrketräning" = "strength"
)

#' Resolve a sport argument to a vector of raw sport-column values
#'
#' Handles direct sport names, Swedish aliases, curated buckets
#' (\code{"endurance"}, \code{"ballsport"}, \code{"gym"},
#' \code{"wintersport"}), the special values \code{"all"}/\code{"any"}/
#' \code{NULL} (no filter), and vectors mixing any of the above.
#'
#' @param sport Character scalar or vector, or NULL.
#' @return Character vector of raw sport values, or \code{NULL} for "all".
#' @keywords internal
.resolve_sport_bucket <- function(sport) {
  if (is.null(sport)) return(NULL)
  if (length(sport) == 0) return(NULL)
  if (length(sport) == 1 && (identical(sport, "all") ||
                              identical(sport, "any"))) return(NULL)

  out <- character(0)
  for (s in sport) {
    if (is.null(s) || is.na(s) || !nzchar(s)) next
    s_lower <- tolower(s)
    if (s_lower %in% c("all", "any")) return(NULL)
    if (!is.null(.SPORT_BUCKETS[[s_lower]])) {
      out <- c(out, .SPORT_BUCKETS[[s_lower]])
    } else if (!is.null(.SPORT_ALIASES[[s_lower]])) {
      out <- c(out, .SPORT_ALIASES[[s_lower]])
    } else {
      out <- c(out, s_lower)
    }
  }
  unique(out)
}

#' Filter a summaries data frame by sport bucket
#'
#' Centralised replacement for inline \code{stringr::str_detect(sport,
#' "running")}.  When \code{sport} is \code{NULL} or \code{"all"}, returns
#' summaries unchanged.
#'
#' Matching is done with \code{stringr::str_detect()} so that sport values
#' like \code{"trail running"} or \code{"running (treadmill)"} still match
#' \code{"running"}.  Raw HAE values like \code{"cycling"}, \code{"walking"},
#' \code{"strength"} match exactly.
#'
#' @param summaries Data frame with a \code{sport} column.
#' @param sport Character (scalar or vector) — see
#'   \code{\link{.resolve_sport_bucket}}.
#' @return Filtered data frame.
#' @keywords internal
.filter_sport <- function(summaries, sport = "running") {
  buckets <- .resolve_sport_bucket(sport)
  if (is.null(buckets)) return(summaries)
  if (!"sport" %in% names(summaries)) return(summaries[0, , drop = FALSE])
  pattern <- paste(buckets, collapse = "|")
  dplyr::filter(summaries, stringr::str_detect(sport, pattern))
}
