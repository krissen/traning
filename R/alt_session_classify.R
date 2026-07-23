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

  # A single session is a one-segment unit — same definition as a
  # multi-segment sport-day, so a single row and a day of segments can
  # never disagree about what "a session" is.
  .classify_alt_unit(seg_min = duration_min, seg_hr = hr_avg,
                     sport = sport, hr_max = hr_max)
}

# Pick the hardest band present. low < moderate < hard.
.hardest_intensity <- function(bands) {
  bands <- bands[!is.na(bands)]
  if (length(bands) == 0) return(NA_character_)
  if ("hard" %in% bands) return("hard")
  if ("moderate" %in% bands) return("moderate")
  "low"
}

#' Classify a sport-day unit from its segments
#'
#' The canonical definition of "a session" for prose: one calendar day
#' of one sport, however many auto-pause segments the source split it
#' into. Duration is the summed moving time; intensity is the
#' \emph{hardest} qualifying segment, not a day-average — a 30-minute
#' hard block inside a six-hour easy paddle must not be smoothed away.
#'
#' Intensity resolution (feeds both the day summary and the week stats,
#' so they cannot diverge):
#' \enumerate{
#'   \item Classify every segment of at least \code{seg_floor} minutes
#'     that carries a heart rate. The unit's intensity is the hardest of
#'     those bands. \code{seg_floor} is \code{compute_trimp()}'s own
#'     10-minute floor, so load and description count the same segments.
#'   \item When no segment qualifies, fall back to the duration-weighted
#'     mean HR over the HR-bearing segments — but only when they cover at
#'     least half the unit's time, otherwise a short measured stretch
#'     would be extrapolated across an untracked day.
#'   \item Otherwise no intensity is claimed (\code{nohr_}).
#' }
#' Recovery cost is the higher of the intensity cost and the volume rule
#' on the summed time, so a long easy unit still costs recovery.
#'
#' @param seg_min Numeric vector of segment durations (minutes).
#' @param seg_hr Numeric vector of segment mean HR (bpm), \code{NA} where
#'   absent. Same length as \code{seg_min}.
#' @param sport Canonical sport value.
#' @param hr_max Resolved HRmax (bpm), or NULL.
#' @param seg_floor Minimum segment minutes to count as an intensity
#'   reading (default 10, matching \code{compute_trimp()}).
#' @return Same shape as \code{\link{classify_alt_session}}.
#' @keywords internal
.classify_alt_unit <- function(seg_min, seg_hr, sport, hr_max = NULL,
                               seg_floor = 10) {
  seg_min <- as.numeric(seg_min)
  seg_hr <- as.numeric(seg_hr)
  ok <- is.finite(seg_min) & seg_min > 0
  seg_min <- seg_min[ok]
  seg_hr <- seg_hr[ok]
  total_min <- sum(seg_min)

  duration_band <- .alt_duration_band(total_min)
  if (is.na(duration_band)) return(.classify_alt_unknown())

  pct_of <- function(hr) {
    if (is.finite(hr) && hr > 0 && !is.null(hr_max) &&
        is.finite(hr_max) && hr_max > 0) {
      max(0, min(1, hr / hr_max))
    } else NA_real_
  }

  has_hr <- is.finite(seg_hr) & seg_hr > 0
  qualifying <- has_hr & seg_min >= seg_floor

  intensity <- NA_character_
  mean_hr_pct <- NA_real_
  if (any(qualifying)) {
    pcts <- vapply(seg_hr[qualifying], pct_of, numeric(1))
    bands <- vapply(pcts, .alt_intensity_band, character(1))
    intensity <- .hardest_intensity(bands)
    # Report the pct of the segment that set the verdict.
    mean_hr_pct <- pcts[which.max(vapply(bands, .recovery_cost_rank_intensity,
                                         integer(1)))]
  } else if (any(has_hr)) {
    hr_time <- sum(seg_min[has_hr])
    if (hr_time >= 0.5 * total_min && hr_time > 0) {
      wmean <- sum(seg_hr[has_hr] * seg_min[has_hr]) / hr_time
      mean_hr_pct <- pct_of(wmean)
      intensity <- .alt_intensity_band(mean_hr_pct)
    }
  }

  has_intensity <- !is.na(intensity)
  list(
    class = if (has_intensity) paste(intensity, duration_band, sep = "_")
            else paste0("nohr_", duration_band),
    intensity = intensity,
    duration_band = duration_band,
    duration_min = total_min,
    recovery_cost = .alt_recovery_cost(intensity, total_min),
    confidence = if (has_intensity) "low" else "none",
    modality = .sport_modality(sport),
    hr_reliability = .sport_hr_reliability(sport),
    sport = sport,
    signals = list(mean_hr_pct = mean_hr_pct, duration_min = total_min,
                   n_segments = length(seg_min)),
    sources = c("Seiler2010", "Stanley2013", "Stoggl2014", "Coggan2003")
  )
}

# Rank an intensity band (not a recovery cost) so "hardest" can be found
# by which.max. low < moderate < hard; NA lowest.
.recovery_cost_rank_intensity <- function(band) {
  if (is.null(band) || length(band) == 0 || is.na(band)) return(0L)
  switch(band, low = 1L, moderate = 2L, hard = 3L, 0L)
}

# Ordinal recovery cost, so "highest cost owns the day" comparisons can
# be made across sessions and against the running class. NA (no HR, short
# session) ranks below "low" — it is an absence of evidence, not a
# measured low cost.
.recovery_cost_rank <- function(cost) {
  if (is.null(cost) || length(cost) == 0 || is.na(cost)) return(0L)
  switch(cost, low = 1L, moderate = 2L, high = 3L, 0L)
}
