# R/session_prose.R
#
# Qualitative Swedish post-workout prose for the per-pass Garmin
# notification. Replaces the prior quantitative line ("Löpning X km,
# Y/km, puls Z") on the user's request.
#
# Tone: blended functional bidrag + roll i veckan. No mechanism-level
# language (no AMPK / PGC-1α / mitokondrier).
# Fabrication-safety: every line corresponds to a claim verified in a
# primer. See the cite tables below — adding a new line requires a
# matching citation in research/_analys/.
#
# Primers referenced (run_text → primer file → primary citekeys):
#   functional zone language   → adaptive-signal-per-zone__primer.md →
#                                 Seiler2009, Seiler2010, Stoggl2014,
#                                 EsteveLanao2007
#   recovery cost & next-hard  → recovery-window__primer.md →
#                                 Stanley2013 (24-48h HRV-suppression by
#                                 intensity zone — primary), Seiler2007
#                                 (acute VT1-binary recovery threshold),
#                                 Buchheit2014 (synthesis), Coggan2003
#                                 (volume cost), RodriguezMarroyo2017
#                                 (extreme load), Carrard2021 (FOR/NFOR/OTS)
#   Z2-accumulation warning    → adaptive-signal-per-zone__implications.md
#                                 §Recommended notification text templates
#                                 (sources: EsteveLanao2007, Stoggl2014)
#   "two HIT/week" rule        → Seiler2010 verbatim — quoted in
#                                 adaptive-signal-per-zone__primer.md §1
#   TSB / form narrative       → tsb-narrative__primer.md → Coggan2003,
#                                 Palladino2015, Morton1997, Busso2003,
#                                 Sanders2018
#
# Output format: 1--3 short Swedish sentences. Each call returns a single
# string suitable for a push notification body.

# ---- Line 1: type + functional purpose -------------------------------------

# Source per row: see comments. All prose is paraphrased from the primer
# implications-doc "Recommended notification text templates", translated
# to Swedish, kept to one short clause.
.session_line_functional <- function(type) {
  switch(type,
    # Z1, low cost. Source: Stoggl2014 (HVT description), Seiler2009 (Z1
    # rapid ANS recovery from <2 mM lactate sessions).
    recovery =
      "Lugnt löppass — aktiv återhämtning, låg belastning.",
    # Source: Stoggl2014 ("HVT leads to improved fat and glucose
    # utilization (Romijn et al., 1993), which is beneficial for long
    # lasting endurance events"); Seiler2010 (LIT volume builds
    # peripheral adaptations).
    endurance =
      "Distanspass — aerob bas, stödjer all hårdare träning.",
    # Source: Seiler2009 Table 3 (extended Z1 → glycogen depletion +
    # increased fat oxidation). Coggan2003 caveat on volume cost handled
    # in line 2.
    long =
      "Långpass — uthållighetens grund, bygger aerob bas och bränsleekonomi.",
    # Source: Stoggl2014 (THR concept) + EsteveLanao2007 (Z2 "tempo
    # pace" definition).
    tempo =
      "Tröskelpass — tränar att hålla en hård, jämn fart.",
    # Source: Seiler2009 Table 6 (threshold-interval formats);
    # Stoggl2014 (THR group sessions).
    threshold_intervals =
      "Tröskelintervaller — lyfter laktattröskeln genom upprepad exponering.",
    # Source: Stoggl2014 (HIIT: increased stroke volume, O2 extraction,
    # buffer capacity); Seiler2010 (Zone 4-5 typical durations 15-60 min).
    vo2max =
      "Kvalitetspass — VO2max-stimulus mot taket av aerob kapacitet.",
    # Source: Lucia2003a (cycling TT analog: "must tolerate high
    # constant workloads at or above ~90% VO2max during entire TT").
    race_pace =
      "Race-pace — maximal aerob stress, race-specifik fart.",
    race =
      "Race-pace — maximal aerob stress, race-specifik fart.",
    # Folklore-level — flagged in session-taxonomy primer §Classification
    # notes #3 (Gosta Holmer, Seiler2009 historical section).
    fartlek =
      "Fartlek — aerob bas med ostrukturerad fartväxling.",
    # Folklore — no primary peer-reviewed source. Flagged in
    # session-taxonomy primer §Classification notes #4.
    hill =
      "Backintervaller — neuromuskulär drivkraft mot lutning.",
    NA_character_)
}

# ---- Line 2: recovery hint + week-context triggers -------------------------

# Recovery-cost wording per type. Sources (primary, in order of strength):
#   Stanley2013 (recovery-window__primer.md §1) — overnight HRV-suppression
#     stratified by intensity: LI (lactate <2, HRmax <82%) up to 24 h;
#     threshold (lactate 2-4, HRmax 82-89%) 24-48 h; HI (lactate >4,
#     HRmax >90%) at least 48 h. Verbatim window quotations.
#   Seiler2007 (adaptive-signal-per-zone__primer.md §6) — acute same-session
#     ANS recovery: <VT1 returns in 5-10 min (HT); both threshold and
#     >VT2 cost ~30 min (HT) or 60-90 min (T) — VT1 is the binary
#     threshold, not "3 mM lactate" as previously approximated.
#   Coggan2003 — volume cost note for >75 min sessions (long-run line).
.session_line_recovery <- function(type) {
  switch(type,
    # Z1 short / fartlek — system clears within hours (Seiler2007: <VT1
    # → ANS back to baseline in 5-10 min in HT athletes; Stanley2013:
    # LI sessions need at most 24 h overnight).
    recovery = "Låg återhämtningskostnad.",
    endurance = "Låg återhämtningskostnad.",
    fartlek = "Låg återhämtningskostnad.",
    # Long run carries volume-based fatigue distinct from intensity
    # (Coggan2003 Level 2: ">75 min may take more than 24 h").
    long =
      "Måttlig återhämtning trots låg intensitet — volymen kostar.",
    # Stanley2013: threshold (HRmax 82-89%) → 24-48 h HRV suppression.
    # Seiler2007: above-VT1 work costs ~30 min acute ANS recovery
    # regardless of whether it is threshold or above VT2.
    tempo =
      "Måttlig återhämtning, planera lugnare i morgon.",
    threshold_intervals =
      "Måttlig återhämtning, planera lugnare i morgon.",
    # Stanley2013: HI (HRmax >90%, lactate >4 mM) → "at least 48 h".
    # Window 48-72 h documented in recovery-window primer §Cross-cutting.
    vo2max =
      "Hög återhämtningskostnad; nästa kvalitetspass tidigast om 48 h.",
    race_pace =
      "Hög återhämtningskostnad; räkna med 48–72 h innan full återhämtning.",
    race =
      "Hög återhämtningskostnad; räkna med 48–72 h innan full återhämtning.",
    hill =
      "Hög återhämtningskostnad; nästa kvalitetspass tidigast om 48 h.",
    NA_character_)
}

# Z2-accumulation warning. Triggers when rolling 90-day Z2 fraction
# (Garmin zone 3) > 20%. Source:
#   EsteveLanao2007: "when a certain threshold is reached (>20% of
#     total training time), this intensity zone does not seem to
#     induce further beneficial adaptations" (verbatim, primer §4).
#   Stoggl2014: THR group showed no VO2peak improvement (-4.1%, ns).
#   Implications: adaptive-signal-per-zone__implications.md §Z2 sessions.
.line_z2_trap <- function(z2_frac_90d) {
  if (!is.finite(z2_frac_90d) || z2_frac_90d <= 0.20) return(NULL)
  pct <- round(z2_frac_90d * 100)
  paste0("Mellanzon-andelen senaste 90 dagarna ", pct,
         "% — överväg fler riktigt lugna pass eller skarpare intervaller.")
}

# Z3-count-this-week guard. Source: Seiler2010 verbatim
# "about two HIT training sessions per week seems to be sufficient
# for inducing physiological adaptations and performance gains
# without inducing excessive stress over the long term."
# Implications: adaptive-signal-per-zone__implications.md §Z3 sessions.
.line_z3_weekly <- function(z3_count_7d) {
  if (!is.finite(z3_count_7d)) return(NULL)
  if (z3_count_7d == 2) {
    return(paste0("Andra kvalitetspasset i veckan — på spåret."))
  }
  if (z3_count_7d >= 3) {
    return(paste0("Tredje hårda passet på 7 dagar — håll koll på återhämtningssignalerna."))
  }
  NULL
}

# ---- TSB context (optional 3rd line) ---------------------------------------

# Decision tree from tsb-narrative__implications.md §Recommendations.
# Inputs: today's TSB and CTL, plus prior TSB for trend.
# Sources cited per branch (numeric thresholds = TrainingPeaks practitioner
# convention, not validated for runners — labelled as such in the primer).
.line_tsb_context <- function(pmc_today, pmc_prev = NULL) {
  if (is.null(pmc_today)) return(NULL)
  tsb <- pmc_today$tsb
  ctl <- pmc_today$ctl
  if (!is.finite(tsb) || !is.finite(ctl)) return(NULL)

  ctl_delta_str <- if (!is.null(pmc_prev) && is.finite(pmc_prev$ctl)) {
    d <- ctl - pmc_prev$ctl
    if (abs(d) >= 0.1) sprintf(" CTL %+.1f.", d) else ""
  } else ""

  ctl_rising <- !is.null(pmc_prev) && is.finite(pmc_prev$ctl) &&
    (ctl - pmc_prev$ctl) > 0

  # Bands from tsb-narrative__implications.md §Recommended notification
  # language. Numeric cutoffs are TrainingPeaks coaching convention
  # (Allen2010 / Coggan2003); evidentiary status flagged in primer.
  base <- if (tsb > 10) {
    "Form på topp — bra läge för kvalitet eller tävling."
  } else if (tsb >= -5) {
    "I balans mellan träning och form."
  } else if (tsb >= -20) {
    if (ctl_rising) "Produktiv bygg-fas." else "Bär trötthet utan att forma."
  } else {
    # TSB < -20: the "deeply negative" zone. Per Carrard2021 the term
    # "overreaching" is a duration-and-supercompensation-dependent
    # diagnosis — TSB alone is a leading indicator. Phrase guards
    # against false claim per
    # tsb-narrative__implications.md §Caveats #4.
    "Djup belastning — överväg vila om mönstret hålls."
  }
  paste0(base, ctl_delta_str)
}

# ---- Main entry ------------------------------------------------------------

#' Generate qualitative post-workout prose for the latest running session
#'
#' Replaces the previous quantitative one-liner. Output is Swedish and
#' suitable for a push notification body — typically 2–4 short
#' sentences (functional + recovery, plus state/context/week-trigger
#' lines when applicable).
#'
#' Per-pass prose is currently scoped to running. Other sports fall back
#' to a sport-aware quantitative line via \code{.session_prose_fallback()}
#' so the existing multi-sport tests in \code{test-report-multisport.R}
#' keep their contract for cycling / walking / strength.
#'
#' @param summaries Garmin summaries data frame from \code{my_dbs_load()}.
#' @param sport Sport bucket (default \code{"running"}). Non-running
#'   sports return the legacy quantitative line.
#' @param on_date Reference date (default = today). Used for the rolling
#'   Z3 count and PMC delta lookup.
#' @param hr_max Optional HRmax. NULL = auto-detect via \code{get_hr_max()}.
#' @param hr_rest Optional HRrest. NULL = compute_pmc default.
#' @param include_tsb Whether to append a state line (TSB + readiness
#'   blend) if PMC can be computed (default TRUE).
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}. NULL = auto-load. Used to derive the
#'   morning readiness verdict so Gul/Röd days don't get an upbeat
#'   "Form på topp" override.
#' @param readiness Optional pre-built readiness list (with elements
#'   \code{status}, \code{score}, ...). Used by tests to inject a
#'   verdict without going through \code{health_insight_readiness()}.
#' @param trigger_source Which source the notification is reacting to.
#'   \code{"any"} (default) keeps the legacy "latest by timestamp"
#'   semantics for arbitrary callers. \code{"garmin"} prefers TCX rows
#'   when picking the latest session — relevant because Garmin-trigger
#'   imports can pull in HAE bursts whose tail() can mask the actual
#'   Garmin run. \code{report_insight()} (the Garmin-trigger entry
#'   point) opts in explicitly.
#' @return A character string with the full prose. Returns
#'   \code{"Ingen data."} when summaries is empty for the sport.
#' @export
session_prose <- function(summaries, sport = "running", on_date = NULL,
                           hr_max = NULL, hr_rest = NULL,
                           include_tsb = TRUE,
                           health_daily = NULL,
                           readiness = NULL,
                           trigger_source = "any") {
  if (is.null(summaries) || nrow(summaries) == 0) return("Ingen data.")

  runs <- .filter_sport(summaries, sport)
  if (nrow(runs) == 0) return("Ingen data.")

  # Pick latest with TCX priority when triggered from Garmin. Otherwise
  # fall through to plain tail() behaviour. Returns NULL on empty.
  latest <- .session_latest_garmin(runs, trigger_source = trigger_source)
  if (is.null(latest) || nrow(latest) == 0) return("Ingen data.")
  if (is.null(on_date)) on_date <- as.Date(latest$sessionStart[1])
  # Coerce caller-supplied "YYYY-MM-DD" strings so downstream date
  # arithmetic (e.g. `on_date - 1` inside .day_state_line()) works for
  # both Date and character inputs.
  on_date <- as.Date(on_date)

  # Non-running sports → legacy quantitative line.
  if (!stringr::str_detect(tolower(sport), "running")) {
    return(.session_prose_fallback(latest, runs, sport))
  }

  cls <- classify_session(latest, hr_max = hr_max, summaries = summaries)

  # Unknown classification → legacy fallback so the user sees something
  # rather than a blank line.
  if (cls$type == "unknown") {
    return(.session_prose_fallback(latest, runs, sport))
  }

  parts <- character()
  l1 <- .session_line_functional(cls$type)
  if (!is.na(l1)) parts <- c(parts, l1)
  l2 <- .session_line_functional_recovery(cls)
  if (length(l2) > 0) parts <- c(parts, l2)

  # State line: blends morning-readiness verdict with TSB band. Shares
  # the .day_state_line() helper from R/day_summary.R so a fix to the
  # narrative logic propagates to both per-pass and 21:30 summaries.
  # See research/_analys/tsb-narrative__implications.md §Caveats for
  # why readiness must override TSB phrasing on Gul/Röd days.
  if (isTRUE(include_tsb)) {
    if (is.null(readiness) && is.null(health_daily)) {
      health_daily <- tryCatch(load_health_data(),
                                error = function(e) NULL)
    }
    state <- tryCatch(
      .day_state_line(summaries, health_daily, on_date,
                       hr_max = hr_max, hr_rest = hr_rest,
                       readiness = readiness),
      error = function(e) NULL
    )
    if (!is.null(state)) parts <- c(parts, state)
  }

  # "Tidigare idag" — other passes the user has logged today, with the
  # classified session removed. Filters out HAE autopause-noise (<1 km
  # AND <10 min). Returns NULL when there's nothing notable to add.
  ctx <- .session_today_context_line(
    .session_other_today(summaries, latest, on_date)
  )
  if (!is.null(ctx)) parts <- c(parts, ctx)

  # Rolling-context triggers (Z2-trap >20%, Z3-count ≥2/week).
  if (identical(cls$zone, "Z2")) {
    z2 <- session_z2_fraction(summaries, on_date = on_date, days = 90)
    extra <- .line_z2_trap(z2)
    if (!is.null(extra)) parts <- c(parts, extra)
  }
  if (identical(cls$zone, "Z3")) {
    z3n <- session_z3_count(summaries, on_date = on_date, days = 7,
                             hr_max = hr_max)
    extra <- .line_z3_weekly(z3n)
    if (!is.null(extra)) parts <- c(parts, extra)
  }

  paste(parts, collapse = " ")
}

# ---- Latest-pass selection -----------------------------------------------

# Pick latest session with optional Garmin (TCX) priority.
#
# When the Garmin trigger fires it can sweep in a burst of newly-
# deduped HAE workouts whose timestamps happen to fall after the
# actual Garmin run. Without this filter the post-workout prose would
# describe a stray HAE walking segment rather than the run the
# notification is reacting to.
#
# Falls back to "any source" when no TCX is present so an HAE-only
# day still gets prose instead of "Ingen data.".
.session_latest_garmin <- function(runs, trigger_source = "any") {
  if (is.null(runs) || nrow(runs) == 0) return(NULL)
  filtered <- runs
  if (identical(trigger_source, "garmin") &&
      "source" %in% names(runs)) {
    src <- runs$source
    filtered <- runs[is.na(src) | src == "tcx", , drop = FALSE]
    if (nrow(filtered) == 0) filtered <- runs  # HAE-only fallback
  }
  filtered <- filtered %>% dplyr::arrange(.data$sessionStart)
  utils::tail(filtered, 1)
}

# ---- "Tidigare idag" context ---------------------------------------------

# Return sessions that share the date with `latest` but are not the
# latest session itself. Filters out HAE autopause noise (very short
# segments) so the context line doesn't list 8 cycling micro-segments.
.session_other_today <- function(summaries, latest, on_date,
                                  min_km = 1.0, min_min = 10) {
  empty <- tibble::tibble()
  if (is.null(summaries) || !inherits(summaries, "data.frame") ||
      nrow(summaries) == 0) {
    return(empty)
  }
  on_date <- as.Date(on_date)
  latest_ts <- latest$sessionStart[1]

  others <- summaries %>%
    dplyr::filter(as.Date(.data$sessionStart) == on_date,
                  .data$sessionStart != latest_ts)
  if (nrow(others) == 0) return(others)

  km   <- as.numeric(others$distance) / 1000
  mins <- as.numeric(others$durationMoving, units = "mins")
  is_tcx <- if ("source" %in% names(others)) {
    is.na(others$source) | others$source == "tcx"
  } else rep(TRUE, nrow(others))

  # Keep all TCX (Garmin) sessions verbatim. For HAE, require either
  # ≥1 km OR ≥10 min so autopaused micro-segments drop out. NA in
  # distance/duration → treat the size-check as FALSE so the row is
  # only kept via the TCX path; without this guard, an NA-only row
  # leaks an `NA sport` fragment into the "Tidigare idag" line.
  size_ok <- (is.finite(km)   & km   >= min_km) |
             (is.finite(mins) & mins >= min_min)
  keep <- is_tcx | size_ok
  keep[is.na(keep)] <- FALSE
  others[keep, , drop = FALSE]
}

# Format the other-passes-today line. Reuses .day_per_sport() so the
# sport ordering / wording matches what day_summary_prose() produces.
.session_today_context_line <- function(other_today) {
  if (is.null(other_today) || nrow(other_today) == 0) return(NULL)
  per <- .day_per_sport(other_today)
  if (nrow(per) == 0) return(NULL)
  parts <- vapply(seq_len(nrow(per)), function(i) {
    label <- tolower(.sport_label_sv(per$sport[i]))
    n  <- per$n[i]
    km <- per$km[i]
    mn <- per$min[i]
    base <- if (km >= 1) sprintf("%s %.1f km", label, km)
             else if (mn > 0) sprintf("%s %d min", label, round(mn))
             else label
    if (n > 1) sprintf("%s (%d pass)", base, n) else base
  }, character(1))
  paste0("Tidigare idag: ", paste(parts, collapse = " + "), ".")
}

# Compose the optional second line with recovery hint + Z2/Z3 triggers.
# Keeps line-2 logic in one place so tests can target it.
.session_line_functional_recovery <- function(cls) {
  out <- character()
  rec <- .session_line_recovery(cls$type)
  if (!is.na(rec)) out <- c(out, rec)
  out
}

#' Append rolling-context lines (Z2-trap, Z3-count) to existing prose
#'
#' Separated from \code{session_prose()} so that callers can choose to
#' compute the heavier rolling aggregates only when needed (e.g. they
#' aren't useful for a standalone unit test of the classifier).
#'
#' @param base Existing prose string.
#' @param summaries Summaries data frame.
#' @param cls Output of \code{classify_session()} for the latest run.
#' @param on_date Reference date.
#' @return Appended prose; \code{base} unchanged when no triggers fire.
#' @export
session_prose_with_context <- function(base, summaries, cls,
                                        on_date = Sys.Date()) {
  if (is.null(cls) || cls$type == "unknown") return(base)
  parts <- base
  if (cls$zone == "Z2") {
    z2 <- session_z2_fraction(summaries, on_date = on_date, days = 90)
    extra <- .line_z2_trap(z2)
    if (!is.null(extra)) parts <- paste(parts, extra)
  }
  if (cls$zone == "Z3") {
    z3n <- session_z3_count(summaries, on_date = on_date, days = 7)
    extra <- .line_z3_weekly(z3n)
    if (!is.null(extra)) parts <- paste(parts, extra)
  }
  parts
}

# ---- Fallback (legacy quantitative line) -----------------------------------

# Used for non-running sports and for runs where classification fails.
# Format mirrors the pre-2026-05 report_insight() output so multi-sport
# tests keep their contract.
.session_prose_fallback <- function(latest, runs, sport) {
  label <- .sport_label_sv(sport)
  km <- round(as.numeric(latest$distance[1]) / 1000, 1)
  pace_val <- as.numeric(latest$avgPaceMoving[1])
  hr_val <- as.numeric(latest$avgHeartRateMoving[1])

  parts <- paste0(label, " ", km, " km")
  if (!is.na(pace_val)) {
    parts <- paste0(parts, ", ", dec_to_mmss(pace_val), "/km")
  }
  if (!is.na(hr_val)) {
    parts <- paste0(parts, ", puls ", round(hr_val, 0))
  }
  base <- parts

  # Reuse the previous "positive highlight" logic verbatim — pace/distance
  # vs current month average. (Original report_insight contract.)
  this_month <- runs %>% dplyr::filter(
    format(.data$sessionStart, "%Y-%m") ==
      format(latest$sessionStart[1], "%Y-%m"),
    .data$sessionStart < latest$sessionStart[1]
  )
  positive <- NULL
  if (nrow(this_month) >= 2 && !is.na(pace_val)) {
    avg_pace <- mean(as.numeric(this_month$avgPaceMoving), na.rm = TRUE)
    avg_km <- mean(as.numeric(this_month$distance) / 1000, na.rm = TRUE)
    diff_sec <- if (is.na(avg_pace)) NA_real_ else (pace_val - avg_pace) * 60
    if (!is.na(diff_sec) && diff_sec < -5) {
      positive <- paste0("Snabbare än månadens snitt (",
                         dec_to_mmss(avg_pace), ")")
    } else if (!is.na(avg_km) && km > avg_km * 1.1) {
      positive <- paste0("Längre än månadens snitt (",
                         round(avg_km, 1), " km)")
    }
  } else if (nrow(this_month) >= 2) {
    avg_km <- mean(as.numeric(this_month$distance) / 1000, na.rm = TRUE)
    if (!is.na(avg_km) && km > avg_km * 1.1) {
      positive <- paste0("Längre än månadens snitt (",
                         round(avg_km, 1), " km)")
    }
  }
  if (is.null(positive)) {
    month_runs <- runs %>% dplyr::filter(
      format(.data$sessionStart, "%Y-%m") ==
        format(latest$sessionStart[1], "%Y-%m")
    )
    month_km <- round(sum(as.numeric(month_runs$distance) / 1000), 0)
    positive <- paste0("Månadens total: ", month_km, " km")
  }
  paste0(base, ". ", positive, ".")
}
