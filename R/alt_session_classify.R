# R/alt_session_classify.R
#
# Sport-agnostic classification of non-running sessions on duration ×
# intensity. The running taxonomy in R/session_classify.R is built on
# session types (tempo, threshold intervals, long run) that only mean
# something for running; paddling, strength work and ball sports need a
# taxonomy that says how long and how hard, and nothing more.
#
# Output feeds the alternative-training lines in day_summary_prose().
#
# Key sources (all read in the design work behind this module, see
# research/_analys/):
#   Seiler 2010            — session-taxonomy__primer.md §2 (5-zone table,
#                            collapsed to the 3-zone research model)
#   Stanley 2013           — recovery-window__primer.md §1a (HRV
#                            suppression by intensity band)
#   Stöggl & Sperlich 2014 — session-taxonomy__primer.md §3 (HVT sessions
#                            "90 min, 150-240 min continuous")
#   Seiler 2007            — recovery-window__primer.md §1b (<=120 min
#                            below VT1 = minimal ANS disturbance)
#   Coggan 2003            — recovery-window__primer.md §2d (very long
#                            workouts may take more than 24 h)
#   Impellizzeri 2019 /
#     Sanders 2017         — training-load-trimp__primer.md, cross-cutting
#                            point 4 (mean HR underestimates intermittent
#                            load)

# ---- Bands ------------------------------------------------------------------

# Duration bands. 90 min is the shortest HVT session Stöggl & Sperlich
# 2014 prescribed and coincides with the existing `long` threshold for
# running; 120 min is the ceiling of what Seiler 2007 actually tested
# below VT1, so the top band marks "beyond the evidence" rather than a
# separate physiological claim.
#
# 45 min has no source. session-taxonomy__primer.md §Classification
# notes #1 says so explicitly ("No specific citation for this threshold
# — coaching folklore"); we reuse it only so the alternative taxonomy
# breaks where the running one already breaks.
.ALT_DUR_SHORT <- 45
.ALT_DUR_LONG <- 90
.ALT_DUR_VERY_LONG <- 120

# Modality families. The split exists for one reason: Stöggl & Sperlich
# 2014's aerobic-base claim was made about endurance athletes in
# endurance modalities, so a strength or yoga session must not inherit
# "bygger aerob bas". Unknown sports fall in `other`, the more cautious
# branch.
#
# `skridskosporter` is deliberately NOT here: HealthKit's "Skating
# Sports" mixes long-distance skating (aerobic) with figure and inline
# skating, and the sessions can't be told apart from the name — the same
# reason it stays in the `wintersport` bucket rather than `endurance`
# (R/sport_filter.R). Leaving it in `other` means figure skating never
# inherits "bygger aerob bas".
.SPORT_MODALITY <- list(
  aerobic = c("running", "cycling", "walking", "swimming", "paddelsporter",
              "rodd")
)

# Mean-HR reliability per modality. For intermittent work mean HR
# *underestimates* the load (Impellizzeri 2019, Sanders 2017), so a
# `hard` verdict is a lower bound we can trust while a `low` verdict is
# not something to build prose on. Used by the prose layer, not by the
# classification itself.
# `skridskosporter` is intermittent here for the same reason it is
# `other` above: a low verdict on mixed skating shouldn't be trusted
# enough to say "lugnt".
.SPORT_HR_RELIABILITY <- list(
  continuous = c("running", "cycling", "walking", "swimming",
                 "paddelsporter", "rodd")
)

#' Modality family for a sport value
#'
#' @param sport Canonical sport-column value.
#' @return "aerobic" or "other" (unknown sports → "other").
#' @keywords internal
.sport_modality <- function(sport) {
  if (is.null(sport) || length(sport) == 0 || is.na(sport[1])) return("other")
  if (tolower(sport[1]) %in% .SPORT_MODALITY$aerobic) "aerobic" else "other"
}

#' Mean-HR reliability class for a sport value
#'
#' @param sport Canonical sport-column value.
#' @return "continuous" or "intermittent" (unknown sports →
#'   "intermittent", the branch that suppresses low-intensity claims).
#' @keywords internal
.sport_hr_reliability <- function(sport) {
  if (is.null(sport) || length(sport) == 0 || is.na(sport[1])) {
    return("intermittent")
  }
  if (tolower(sport[1]) %in% .SPORT_HR_RELIABILITY$continuous) {
    "continuous"
  } else {
    "intermittent"
  }
}

#' Intensity band from mean HR as a fraction of HRmax
#'
#' Three bands on the same VT1 / VT2 anchors the running classifier
#' uses (\code{.HR_PCT_VT1} / \code{.HR_PCT_VT2} in
#' R/session_classify.R), collapsed from Seiler 2010's five zones:
#' low < 82%, moderate 82-87.9%, hard >= 88%.
#'
#' @param hr_pct Mean HR / HRmax, or NA.
#' @return "low", "moderate", "hard", or NA_character_.
#' @keywords internal
.alt_intensity_band <- function(hr_pct) {
  if (!is.finite(hr_pct)) return(NA_character_)
  if (hr_pct < .HR_PCT_VT1) return("low")
  if (hr_pct < .HR_PCT_VT2) return("moderate")
  "hard"
}

#' Duration band in minutes
#'
#' @param duration_min Session duration in minutes.
#' @return "short", "medium", "long", or "very_long"; NA when the
#'   duration isn't usable.
#' @keywords internal
.alt_duration_band <- function(duration_min) {
  if (!is.finite(duration_min) || duration_min <= 0) return(NA_character_)
  if (duration_min < .ALT_DUR_SHORT) return("short")
  if (duration_min < .ALT_DUR_LONG) return("medium")
  if (duration_min < .ALT_DUR_VERY_LONG) return("long")
  "very_long"
}

#' Recovery cost from intensity plus the volume rule
#'
#' Sources per branch:
#' \itemize{
#'   \item hard → high: Stanley 2013, "at least 48 h following
#'     high-intensity exercise".
#'   \item moderate → moderate: Stanley 2013, 24-48 h after threshold
#'     work.
#'   \item low but >= 90 min → moderate: Coggan 2003, complete recovery
#'     from very long workouts may take more than 24 h. Same rule that
#'     gives the running long run a moderate cost despite Z1.
#' }
#' The volume rule survives a missing HR reading — it depends on time
#' only — which is why an unclassifiable but long session still returns
#' "moderate".
#'
#' @param intensity "low", "moderate", "hard" or NA.
#' @param duration_min Session duration in minutes.
#' @return "low", "moderate", "high", or NA_character_.
#' @keywords internal
.alt_recovery_cost <- function(intensity, duration_min) {
  long_enough <- is.finite(duration_min) && duration_min >= .ALT_DUR_LONG
  if (is.null(intensity) || length(intensity) == 0 || is.na(intensity)) {
    return(if (long_enough) "moderate" else NA_character_)
  }
  if (identical(intensity, "hard")) return("high")
  if (identical(intensity, "moderate")) return("moderate")
  if (long_enough) return("moderate")
  "low"
}

# ---- classify_alt_session ---------------------------------------------------

.classify_alt_unknown <- function() {
  list(class = NA_character_, intensity = NA_character_,
       duration_band = NA_character_, duration_min = NA_real_,
       recovery_cost = NA_character_, confidence = "unknown",
       modality = "other", hr_reliability = "intermittent",
       sport = NA_character_, signals = list(), sources = character())
}

#' Classify a non-running session on duration and intensity
#'
#' Sport-agnostic counterpart to \code{\link{classify_session}}: instead
#' of a running session type it returns an intensity band, a duration
#' band and the recovery cost that follows from them. Sessions without a
#' usable mean HR get a duration band only — no intensity is invented,
#' and the class is prefixed \code{"nohr_"} so callers can suppress
#' intensity claims in prose.
#'
#' The HRmax anchor is \code{get_hr_max(summaries, sport = "all")}, the
#' same denominator \code{\link{compute_trimp}} uses by default. Using
#' the running anchor here would let a session be called "hard" against
#' one denominator while its TRIMP is computed against another.
#'
#' All results carry \code{confidence = "low"} (or \code{"none"} without
#' HR): mean HR underestimates sessions with warm-up and cool-down, and
#' fixed %HRmax boundaries are individually uncertain.
#'
#' @param session One-row data frame from \code{summaries}.
#' @param hr_max Optional HRmax (bpm). NULL → derived from
#'   \code{summaries}.
#' @param summaries Optional summaries table for HRmax auto-detection.
#' @return A list with elements \code{class}, \code{intensity},
#'   \code{duration_band}, \code{duration_min}, \code{recovery_cost},
#'   \code{confidence}, \code{modality}, \code{hr_reliability},
#'   \code{sport}, \code{signals} and \code{sources}.
#' @export
classify_alt_session <- function(session, hr_max = NULL, summaries = NULL) {
  if (is.null(session) || !inherits(session, "data.frame") ||
      nrow(session) == 0) {
    return(.classify_alt_unknown())
  }
  s <- session[1, , drop = FALSE]

  duration_min <- if (!is.null(s$durationMoving)) {
    as.numeric(s$durationMoving, units = "mins")
  } else NA_real_
  if (!is.finite(duration_min) || duration_min <= 0) {
    return(.classify_alt_unknown())
  }

  sport <- if ("sport" %in% names(s)) as.character(s$sport[1]) else NA_character_

  hr_avg <- if (!is.null(s$avgHeartRateMoving)) {
    as.numeric(s$avgHeartRateMoving[1])
  } else NA_real_
  if (is.finite(hr_avg) && hr_avg > 0 && is.null(hr_max) &&
      !is.null(summaries)) {
    hr_max <- tryCatch(get_hr_max(summaries, sport = "all"),
                       error = function(e) NULL)
  }
  hr_pct <- if (is.finite(hr_avg) && hr_avg > 0 && !is.null(hr_max) &&
                is.finite(hr_max) && hr_max > 0) {
    max(0, min(1, hr_avg / hr_max))
  } else NA_real_

  .alt_result(sport, hr_pct, duration_min)
}

# Build the result list from the two signals. Split out so the
# per-sport day aggregate in R/day_summary.R can classify a summed
# session without rebuilding a one-row data frame.
.alt_result <- function(sport, hr_pct, duration_min) {
  duration_band <- .alt_duration_band(duration_min)
  if (is.na(duration_band)) return(.classify_alt_unknown())

  intensity <- .alt_intensity_band(hr_pct)
  has_hr <- !is.na(intensity)

  list(
    class = if (has_hr) paste(intensity, duration_band, sep = "_")
            else paste0("nohr_", duration_band),
    intensity = intensity,
    duration_band = duration_band,
    duration_min = duration_min,
    recovery_cost = .alt_recovery_cost(intensity, duration_min),
    confidence = if (has_hr) "low" else "none",
    modality = .sport_modality(sport),
    hr_reliability = .sport_hr_reliability(sport),
    sport = sport,
    signals = list(mean_hr_pct = hr_pct, duration_min = duration_min),
    sources = c("Seiler2010", "Stanley2013", "Stoggl2014", "Coggan2003")
  )
}

# Ordinal recovery cost, so "highest cost owns the day" comparisons can
# be made across sessions and against the running class. NA (no HR, short
# session) ranks below "low" — it is an absence of evidence, not a
# measured low cost.
.recovery_cost_rank <- function(cost) {
  if (is.null(cost) || length(cost) == 0 || is.na(cost)) return(0L)
  switch(cost, low = 1L, moderate = 2L, high = 3L, 0L)
}
