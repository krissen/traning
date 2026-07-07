# R/session_classify.R
#
# Research-grounded classification of completed running sessions into a
# closed taxonomy. Used by session_prose() to drive the qualitative
# post-workout notification.
#
# All classification rules and thresholds in this file are anchored to
# primary literature read in full text. Citekeys reference primers in
# research/_analys/ — every rule has a Source: comment.
#
# Key sources:
#   Seiler & Tønnessen 2009  — research/_analys/session-taxonomy__primer.md §1
#   Seiler 2010              — research/_analys/session-taxonomy__primer.md §2
#   Stöggl & Sperlich 2014   — research/_analys/session-taxonomy__primer.md §3
#   Esteve-Lanao et al. 2007 — research/_analys/session-taxonomy__primer.md §4
#   Foster et al. 2001       — research/_analys/training-load-trimp__primer.md §3
#
# Conventions: Garmin's 5-zone model collapses to the 3-zone research model
# (Seiler 2010, Treff 2019) as: Z1_research = Garmin zones 1+2; Z2_research =
# Garmin zone 3; Z3_research = Garmin zones 4+5. The boundary at ~82% HRmax
# approximates VT1 and ~88% HRmax approximates VT2.
#   Source: research/_analys/hr-zone-distribution__primer.md §5 (Treff2019)
#           research/_analys/hr-zone-distribution__implications.md §Q.

# ---- Internal: zone-time helpers -------------------------------------------

# Pull seconds-in-zone from a summaries row, returning a length-5 numeric
# vector or NULL when no zone data is present.
.session_zone_seconds <- function(session) {
  cols <- paste0("garmin_hrTimeInZone_", 1:5)
  if (!all(cols %in% names(session))) return(NULL)
  v <- as.numeric(unlist(session[1, cols]))
  if (all(is.na(v)) || sum(v, na.rm = TRUE) <= 0) return(NULL)
  v[is.na(v)] <- 0
  v
}

# Collapse Garmin 5-zone seconds → 3-zone fractions (Z1, Z2, Z3 research).
# Source: hr-zone-distribution__primer.md §5 (Treff 2019 mapping).
.collapse_zones_3 <- function(zone_seconds) {
  if (is.null(zone_seconds)) return(NULL)
  total <- sum(zone_seconds)
  if (total <= 0) return(NULL)
  list(
    z1 = (zone_seconds[1] + zone_seconds[2]) / total,
    z2 = zone_seconds[3] / total,
    z3 = (zone_seconds[4] + zone_seconds[5]) / total,
    total_sec = total
  )
}

# ---- classify_session ------------------------------------------------------

#' Classify a completed running session
#'
#' Returns the session-type label, the dominant zone, a recovery-cost tag,
#' and the signals used to make the call. Designed to feed
#' \code{session_prose()} for the post-workout notification.
#'
#' Classification priority (per
#' research/_analys/session-taxonomy__implications.md §Recommendations):
#' \enumerate{
#'   \item RPE-primary if \code{garmin_directWorkoutRpe} is finite (Foster 2001
#'     validated session RPE; cutoffs follow the implications-doc
#'     approximation, mapped from Garmin's 0--100 scale to Borg CR-10 by /10).
#'   \item Zone-fraction + duration heuristic when RPE is missing.
#'   \item Heart-rate average + duration fallback when neither RPE nor
#'     zone data is present.
#' }
#'
#' Labels (closed list) and primary citation per type are documented in
#' research/_analys/session-taxonomy__primer.md cross-cutting synthesis.
#'
#' @param session One-row data frame / tibble from \code{summaries}
#'   (a single completed run).
#' @param hr_max Optional HRmax (bpm). Used only for the HR-fallback path.
#'   Default NULL → estimated from \code{summaries} via
#'   \code{get_hr_max()}.
#' @param summaries Optional summaries table for HRmax auto-detection.
#'   Used only when \code{hr_max} is NULL.
#' @return A list with elements:
#'   \itemize{
#'     \item \code{type} — one of "recovery", "endurance", "long",
#'       "tempo", "threshold_intervals", "vo2max", "race_pace",
#'       "fartlek", "hill", "unknown"
#'     \item \code{zone} — dominant research zone: "Z1", "Z2", "Z3", or NA
#'     \item \code{recovery_cost} — "low", "moderate", "high"
#'     \item \code{confidence} — "high" (RPE), "medium" (zones), "low" (HR
#'       fallback), or "unknown"
#'     \item \code{signals} — list of computed inputs (rpe, z1/z2/z3 fractions,
#'       duration_min, mean_hr_pct)
#'     \item \code{sources} — character vector of citekeys backing the label
#'   }
#' @export
classify_session <- function(session, hr_max = NULL, summaries = NULL) {
  if (is.null(session) || nrow(session) == 0) {
    return(.classify_unknown())
  }
  s <- session[1, , drop = FALSE]

  duration_min <- if (!is.null(s$durationMoving)) {
    as.numeric(s$durationMoving, units = "mins")
  } else NA_real_
  if (!is.finite(duration_min) || duration_min <= 0) {
    return(.classify_unknown())
  }

  # 1. RPE-primary
  rpe_raw <- if ("garmin_directWorkoutRpe" %in% names(s)) {
    as.numeric(s$garmin_directWorkoutRpe[1])
  } else NA_real_
  rpe_cr10 <- if (is.finite(rpe_raw)) rpe_raw / 10 else NA_real_

  zone_sec <- .session_zone_seconds(s)
  zones <- .collapse_zones_3(zone_sec)

  if (is.finite(rpe_cr10)) {
    return(.classify_from_rpe(rpe_cr10, duration_min, zones))
  }

  # 2. Zone-fraction heuristic
  if (!is.null(zones)) {
    return(.classify_from_zones(zones, duration_min))
  }

  # 3. HR-average fallback (least precise — flagged "low" confidence)
  hr_avg <- if (!is.null(s$avgHeartRateMoving)) {
    as.numeric(s$avgHeartRateMoving[1])
  } else NA_real_
  if (is.finite(hr_avg)) {
    if (is.null(hr_max) && !is.null(summaries)) {
      hr_max <- tryCatch(get_hr_max(summaries, sport = "running"),
                         error = function(e) NULL)
    }
    if (is.null(hr_max) || !is.finite(hr_max)) return(.classify_unknown())
    return(.classify_from_hr_avg(hr_avg / hr_max, duration_min))
  }

  .classify_unknown()
}

# ---- Internal classifiers --------------------------------------------------

# RPE → type. Cutoffs from
# research/_analys/session-taxonomy__implications.md §What is missing #1.
# Foster 2001 validated session RPE on the Borg CR-10 scale; the precise
# cutoffs (4, 6, 7, 8) are the implications-doc approximation, not a
# Foster2001-stated boundary — they reflect the description in Foster2001
# Methods (the CR-10 anchors) re-applied to running.
.classify_from_rpe <- function(rpe_cr10, duration_min, zones) {
  type <- if (rpe_cr10 <= 3) {
    if (duration_min < 45) "recovery" else "endurance"
  } else if (rpe_cr10 <= 5) {
    if (duration_min >= 90) "long" else "endurance"
  } else if (rpe_cr10 <= 7) {
    "tempo"
  } else if (rpe_cr10 <= 8) {
    "threshold_intervals"
  } else if (rpe_cr10 <= 9) {
    "vo2max"
  } else {
    "race_pace"
  }
  list(
    type = type,
    zone = .type_to_zone(type),
    recovery_cost = .type_to_recovery_cost(type),
    confidence = "high",
    signals = list(rpe_cr10 = rpe_cr10, duration_min = duration_min,
                   zones = zones),
    sources = c("Foster2001",  # session RPE validated
                "Seiler2009", "Seiler2010",
                "EsteveLanao2005")  # running-specific distribution data
  )
}

# Zone fractions + duration → type. Heuristic order per
# research/_analys/session-taxonomy__implications.md §What is missing #2.
.classify_from_zones <- function(zones, duration_min) {
  z1 <- zones$z1; z2 <- zones$z2; z3 <- zones$z3

  type <- if (z3 >= 0.40) {
    "race_pace"             # Z3-dominant → race / race-pace effort
  } else if (z3 >= 0.20) {
    "vo2max"                # short Z3 bouts dominate → VO2max work
  } else if (z2 + z3 >= 0.30 && z2 < 0.40) {
    "threshold_intervals"   # mixed Z2/Z3 with Z1 recovery → intervals
  } else if (z2 >= 0.40) {
    "tempo"                 # sustained Z2 → continuous tempo/threshold
  } else if (z3 < 0.10 && z2 < 0.20) {
    if (duration_min > 90)       "long"
    else if (duration_min >= 40) "endurance"
    else                          "recovery"
  } else {
    # Mixed signature without clear dominant zone — treat as endurance
    # with note. Source: implications doc — "favour lower intensity
    # classification when signal is ambiguous".
    if (duration_min >= 40) "endurance" else "recovery"
  }
  list(
    type = type,
    zone = .type_to_zone(type),
    recovery_cost = .type_to_recovery_cost(type),
    confidence = "medium",
    signals = list(z1 = z1, z2 = z2, z3 = z3,
                   duration_min = duration_min),
    sources = c("Seiler2009", "Seiler2010", "Treff2019",
                "EsteveLanao2005",  # running-specific 71/21/8 distribution
                "EsteveLanao2007",  # RCT comparing Z1- vs Z2-heavy programs
                "Neal2013")         # POL > THR crossover RCT
  )
}

# Mean-HR-as-%HRmax fallback. Lowest confidence — Seiler 2009 / 2010
# explicitly warn that mean HR underestimates intensity for sessions with
# warm-up / cool-down. Meixner 2025 further shows that fixed %HRmax-
# boundary zones produce CV 22-29% in resulting power output across
# individuals — the "low" confidence tag here understates uncertainty.
# Used only when neither RPE nor zone data exist.
.classify_from_hr_avg <- function(hr_pct, duration_min) {
  type <- if (hr_pct < 0.72) {
    if (duration_min > 90)       "long"
    else if (duration_min >= 40) "endurance"
    else                          "recovery"
  } else if (hr_pct < 0.82) {
    if (duration_min >= 90) "long" else "endurance"
  } else if (hr_pct < 0.88) {
    "tempo"
  } else if (hr_pct < 0.92) {
    "threshold_intervals"
  } else {
    "vo2max"
  }
  list(
    type = type,
    zone = .type_to_zone(type),
    recovery_cost = .type_to_recovery_cost(type),
    confidence = "low",
    signals = list(mean_hr_pct = hr_pct, duration_min = duration_min),
    sources = c("Seiler2010")
  )
}

.classify_unknown <- function() {
  list(type = "unknown", zone = NA_character_,
       recovery_cost = NA_character_, confidence = "unknown",
       signals = list(), sources = character())
}

# Type → research zone. Source: session-taxonomy primer cross-cutting
# synthesis table (intensity column).
.type_to_zone <- function(type) {
  switch(type,
    recovery = "Z1", endurance = "Z1", long = "Z1",
    tempo = "Z2", threshold_intervals = "Z2",
    vo2max = "Z3", race_pace = "Z3", race = "Z3", hill = "Z3",
    fartlek = "Z1",
    NA_character_)
}

# Type → recovery-cost tag. Source:
# research/_analys/recovery-window__primer.md §Cross-cutting synthesis +
# session-taxonomy__implications.md §What is missing #6.
# Long run = "moderate" despite Z1 because Coggan 2003 notes >75 min runs
# leave volume-based fatigue distinct from intensity (recovery-window primer).
.type_to_recovery_cost <- function(type) {
  switch(type,
    recovery = "low", endurance = "low", fartlek = "low",
    long = "moderate",
    tempo = "moderate", threshold_intervals = "moderate",
    vo2max = "high", race_pace = "high", race = "high", hill = "high",
    NA_character_)
}

# ---- Rolling counters ------------------------------------------------------

#' Count Z3 (high-intensity) running sessions in the last N days
#'
#' Used to detect the "third hard session this week" overload pattern.
#'
#' Sources (in order of primacy):
#'   Foster, Casado, Esteve-Lanao, Haugen & Seiler (2022) — primary
#'     mechanistic argument: AMPK signalling saturates with small Z3
#'     volumes, so additional Z3 sessions yield diminishing returns
#'     while accumulating recovery cost.
#'     research/_analys/adaptive-signal-per-zone__primer.md §9
#'   Seiler (2010) — corroborating observational evidence: "about two
#'     HIT training sessions per week seems to be sufficient" (verbatim).
#'     research/_analys/adaptive-signal-per-zone__implications.md §Recommendations #4
#'
#' @param summaries Garmin summaries table.
#' @param on_date Date or POSIXct anchor (default \code{Sys.Date()}).
#' @param days Window length in days (default 7).
#' @param hr_max Optional HRmax for the HR fallback inside classifier.
#' @return Integer count of Z3-classified sessions in the window.
#' @export
session_z3_count <- function(summaries, on_date = Sys.Date(), days = 7,
                              hr_max = NULL) {
  if (is.null(summaries) || nrow(summaries) == 0) return(0L)
  on_date <- as.Date(on_date)
  start <- on_date - (days - 1)

  runs <- summaries %>%
    dplyr::filter(stringr::str_detect(tolower(.data$sport), "running")) %>%
    dplyr::filter(as.Date(.data$sessionStart) >= start,
                  as.Date(.data$sessionStart) <= on_date)
  if (nrow(runs) == 0) return(0L)

  zones <- vapply(seq_len(nrow(runs)), function(i) {
    res <- classify_session(runs[i, , drop = FALSE],
                            hr_max = hr_max, summaries = summaries)
    res$zone %||% NA_character_
  }, character(1))
  sum(zones == "Z3", na.rm = TRUE)
}

#' Rolling Z2-fraction (research Z2 = Garmin zone 3) over the last N days
#'
#' Implements the moderate-intensity rolling-share signal — input to the
#' "diminishing returns above ~20% Z2" hedge in the post-workout prose.
#'
#' Sources:
#'   Esteve-Lanao 2007 — RCT showing >25% Z2 produced smaller gains than
#'     a Z1-heavy program (matched total load).
#'   Stöggl & Sperlich 2014 — THR group plateaued in well-trained athletes.
#'   MoranMacdonald2025 — counter: at matched HIIT, adding Z2 (240 min/wk)
#'     gave no extra benefit. Reframes Z2 as "diminishing returns" rather
#'     than "trap" (master's thesis, not peer-reviewed).
#'
#' Reliability caveat: Garmin zone fractions are based on %HRmax (often
#' Tanaka-derived), not VT1/VT2-anchored zones. Meixner2025 (N=50
#' cyclists) shows fixed %HRmax boundaries produce CV 22-29% in resulting
#' power output — i.e., the "Z2 fraction" we compute may be off by
#' multiple zone intervals at the individual level. Treat the 20%-trigger
#' as best-effort signal, not a hard threshold.
#'   research/_analys/hr-zone-prescription__implications.md §Reliability ranking
#'   research/_analys/adaptive-signal-per-zone__implications.md §Classification reliability
#'
#' @param summaries Garmin summaries table.
#' @param on_date Date anchor (default \code{Sys.Date()}).
#' @param days Window length in days (default 90).
#' @return Numeric in [0,1], or NA when no zone data exists in window.
#' @export
session_z2_fraction <- function(summaries, on_date = Sys.Date(), days = 90) {
  if (is.null(summaries) || nrow(summaries) == 0) return(NA_real_)
  cols <- paste0("garmin_hrTimeInZone_", 1:5)
  if (!all(cols %in% names(summaries))) return(NA_real_)

  on_date <- as.Date(on_date)
  start <- on_date - (days - 1)

  runs <- summaries %>%
    dplyr::filter(stringr::str_detect(tolower(.data$sport), "running")) %>%
    dplyr::filter(as.Date(.data$sessionStart) >= start,
                  as.Date(.data$sessionStart) <= on_date)
  if (nrow(runs) == 0) return(NA_real_)

  total <- sum(unlist(runs[, cols]), na.rm = TRUE)
  if (total <= 0) return(NA_real_)
  z3_garmin <- sum(as.numeric(runs$garmin_hrTimeInZone_3), na.rm = TRUE)
  z3_garmin / total
}
