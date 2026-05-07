# Sport filtering for sport-agnostic reports.
#
# Replaces the hard-coded ``str_detect(sport, "running")`` filters that
# used to be scattered across report and metric functions.  Callers pass
# a ``sport`` argument; this resolves it to a vector of bucket names and
# filters ``summaries`` accordingly.

# Swedish display labels for the most common sport buckets, used in
# user-facing prose (push notifications, headers).  Falls back to a
# generic "Aktivitet" when an unmapped value is passed.
.SPORT_LABELS_SV <- list(
  "running"      = "Löpning",
  "cycling"      = "Cykling",
  "walking"      = "Gång",
  "swimming"     = "Simning",
  "strength"     = "Styrketräning",
  "karntraning"  = "Kärnträning",
  "ovrigt"       = "Aktivitet",
  "endurance"    = "Konditionspass",
  "ballsport"    = "Bollsport",
  "wintersport"  = "Vintersport",
  "gym"          = "Gymträning"
)

#' Swedish display label for a sport bucket
#'
#' Used in user-facing prose like push notifications.
#' @keywords internal
.sport_label_sv <- function(sport) {
  if (is.null(sport) || length(sport) == 0) return("Aktivitet")
  if (length(sport) > 1) return("Aktivitet")
  if (identical(sport, "all") || identical(sport, "any")) return("Aktivitet")
  s_lower <- tolower(sport)
  label <- .SPORT_LABELS_SV[[s_lower]]
  if (!is.null(label)) return(label)
  # Fallback: capitalize first letter of the raw value
  paste0(toupper(substr(s_lower, 1, 1)), substr(s_lower, 2, nchar(s_lower)))
}

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
#' Each bucket is matched as a literal substring (via
#' \code{stringr::fixed()}), so values like \code{"trail running"} or
#' \code{"running (treadmill)"} still match \code{"running"} without
#' interpreting parentheses or other regex metacharacters.
#'
#' @param summaries Data frame with a \code{sport} column.
#' @param sport Character (scalar or vector) — see
#'   \code{\link{.resolve_sport_bucket}}.
#' @return Filtered data frame.
#' @keywords internal
.filter_sport <- function(summaries, sport = "running") {
  matches <- .sport_match_mask(summaries, sport)
  if (all(matches)) return(summaries)
  if (!any(matches)) return(summaries[0, , drop = FALSE])
  dplyr::filter(summaries, matches)
}

#' Logical mask telling which rows of \code{summaries} match \code{sport}
#'
#' Same matching rules as \code{.filter_sport()} but returns a logical
#' vector aligned to \code{summaries} so callers that need positional
#' alignment (e.g. \code{compute_decoupling()} indexing into
#' \code{myruns[[i]]}) can keep their indices.
#'
#' Treats \code{NULL}, \code{character(0)}, \code{"all"} and \code{"any"}
#' as "match everything", and an explicit-but-unrecognised sport input
#' (e.g. \code{""}, \code{NA_character_}) as "match nothing" — never as
#' silent pass-through.
#'
#' @param summaries Data frame with a \code{sport} column.
#' @param sport Character (scalar or vector), or NULL.
#' @return Logical vector with \code{length(.) == nrow(summaries)}.
#' @keywords internal
.sport_match_mask <- function(summaries, sport = "running") {
  n <- nrow(summaries)
  buckets <- .resolve_sport_bucket(sport)
  if (is.null(buckets)) return(rep(TRUE, n))
  if (length(buckets) == 0) return(rep(FALSE, n))
  if (!"sport" %in% names(summaries)) return(rep(FALSE, n))
  matches <- Reduce(`|`, lapply(buckets, function(b) {
    stringr::str_detect(summaries$sport, stringr::fixed(b))
  }))
  # str_detect returns NA when the input is NA, which propagates into
  # all()/any() and causes "missing value where TRUE/FALSE needed" in
  # callers like .filter_sport(). Treat NA sport values as no match.
  matches[is.na(matches)] <- FALSE
  matches
}
