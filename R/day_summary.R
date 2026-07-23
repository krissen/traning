# R/day_summary.R
#
# End-of-day qualitative summary across ALL sports for a given date.
# Triggered by a systemd timer at ~21:30 on kailash; produces Swedish
# prose suitable for a single push notification.
#
# In contrast to session_prose() (per-pass, running only), day_summary
# aggregates Garmin + HAE workouts (already merged into `summaries` by
# import_hae_workouts()) and frames the day's stimulus in week context.
#
# Tone: funktion/bidrag + roll i veckan. No mechanism-level language.
#
# Sources for prose claims:
#   - Seiler 2010 ("two HIT/week sufficient" verbatim)
#     research/_analys/adaptive-signal-per-zone__primer.md §2
#   - Esteve-Lanao 2007 (>20% Z2 = no further benefit)
#     research/_analys/session-taxonomy__primer.md §4
#   - Treff 2019 (Polarization Index formula PI = log10((Z1/Z2)*Z3*100))
#     research/_analys/hr-zone-distribution__primer.md §5
#   - TSB / CTL narrative bands → tsb-narrative__primer.md
#   - Carrard 2021 (overreaching is duration-dependent — leading-indicator
#     wording for deep-negative TSB) → tsb-narrative__implications.md §Caveats #4

# ---- Helpers ---------------------------------------------------------------

# ---- Canonical sport-day unit ----------------------------------------------
#
# The one place that decides what "a session" is: one calendar day of
# one sport, however many auto-pause segments the source split it into.
# Every surface — the "Dagens pass" inventory, the dominant-effort
# class, the weekly stats, and the per-pass "Tidigare idag" line — reads
# its sessions from here, so n_segments, km and min can never disagree
# between them (the 5-pass-vs-3-pass and 3x15-min bugs were four
# aggregations giving four answers).
#
# `classify = TRUE` additionally attaches the intensity / duration /
# recovery-cost verdict from .classify_alt_unit(): intensity comes from
# the hardest qualifying segment, not a day-average, so a hard block
# inside an easy day is never smoothed away.
#
# Filtering is the caller's job and happens AFTER aggregation (min on
# the unit total, never on a raw segment), so the same outing counts the
# same everywhere.
.day_sport_units <- function(sessions, hr_max = NULL, classify = FALSE,
                             seg_floor = 10) {
  empty <- tibble::tibble(
    date = as.Date(character(0)), sport = character(0),
    n_segments = integer(0), km = numeric(0), min = numeric(0))
  if (classify) {
    empty <- empty %>% dplyr::mutate(
      intensity = character(0), duration_band = character(0),
      recovery_cost = character(0), class = character(0),
      modality = character(0), hr_reliability = character(0),
      confidence = character(0), hard = logical(0))
  }
  if (is.null(sessions) || !inherits(sessions, "data.frame") ||
      nrow(sessions) == 0) {
    return(empty)
  }

  df <- sessions %>%
    dplyr::mutate(
      .date = as.Date(.data$sessionStart),
      .km   = as.numeric(.data$distance) / 1000,
      .min  = as.numeric(.data$durationMoving, units = "mins"),
      .hr   = as.numeric(.data$avgHeartRateMoving),
      # A missing sport is coalesced to "" rather than dropped: the
      # session still happened, so it belongs in the inventory. The ""
      # key groups cleanly (unlike NA) and .sport_label_sv("") renders
      # the honest generic "Aktivitet" — hiding the row behind "Vilodag"
      # would be the worse error.
      sport = ifelse(is.na(.data$sport) | !nzchar(.data$sport), "",
                     .data$sport)
    ) %>%
    dplyr::filter(is.finite(.data$.min), .data$.min > 0)
  if (nrow(df) == 0) return(empty)

  agg <- df %>%
    dplyr::group_by(date = .data$.date, sport = .data$sport) %>%
    dplyr::summarise(
      n_segments = dplyr::n(),
      km  = sum(.data$.km, na.rm = TRUE),
      min = sum(.data$.min),
      .groups = "drop"
    ) %>%
    dplyr::arrange(dplyr::desc(.data$km), dplyr::desc(.data$min))

  if (!classify) return(agg)

  verdicts <- lapply(seq_len(nrow(agg)), function(i) {
    seg <- df[df$.date == agg$date[i] & df$sport == agg$sport[i], ]
    .classify_alt_unit(seg$.min, seg$.hr, agg$sport[i], hr_max = hr_max,
                       seg_floor = seg_floor)
  })
  agg %>% dplyr::mutate(
    intensity     = vapply(verdicts, function(v) v$intensity %||% NA_character_,
                           character(1)),
    duration_band = vapply(verdicts, function(v) v$duration_band, character(1)),
    recovery_cost = vapply(verdicts, function(v) v$recovery_cost %||%
                             NA_character_, character(1)),
    class         = vapply(verdicts, function(v) v$class %||% NA_character_,
                           character(1)),
    modality      = vapply(verdicts, function(v) v$modality, character(1)),
    hr_reliability = vapply(verdicts, function(v) v$hr_reliability,
                            character(1)),
    confidence    = vapply(verdicts, function(v) v$confidence, character(1)),
    hard          = vapply(verdicts, function(v) identical(v$intensity, "hard"),
                           logical(1))
  )
}

# Aggregate today's sessions per sport for the "Dagens pass" inventory.
# Thin wrapper over .day_sport_units() (no classification, no filter):
# the inventory lists everything the user did, so it never drops a unit.
.day_per_sport <- function(todays) {
  u <- .day_sport_units(todays, classify = FALSE)
  tibble::tibble(sport = u$sport, n = u$n_segments, km = u$km, min = u$min)
}

# One sport's contribution to a day: "löpning 12.2 km",
# "paddling 26.0 km / 6 h 5 min", "styrketräning 45 min",
# "cykling 9.5 km (2 pass)".
#
# Long efforts get both figures: distance alone told the reader nothing
# about a six-hour paddle, and for a 2.5-hour long run the time is just
# as informative. Sports without a distance (strength, yoga) only ever
# had the time. The 90-minute gate is the same `long` threshold the
# session classifiers use.
#
# Shared by the day summary and the "Tidigare idag" line in
# session_prose(), so the two notifications describe the same session
# the same way.
.per_sport_fragment <- function(label, n, km, mn) {
  label <- tolower(label)
  dur <- .fmt_duration_sv(mn)
  base <- if (is.finite(km) && km >= 1) {
    if (is.finite(mn) && mn >= .ALT_DUR_LONG && !is.na(dur)) {
      sprintf("%s %s km / %s", label, fmt_dec_sv(km), dur)
    } else {
      sprintf("%s %s km", label, fmt_dec_sv(km))
    }
  } else if (is.finite(mn) && mn > 0 && !is.na(dur)) {
    sprintf("%s %s", label, dur)
  } else {
    label
  }
  # Annotate with pass-count only when more than one session of the
  # same sport was logged that day. Use parenthetical to avoid the
  # ambiguous "Nx Y km" reading (which could be parsed as "N sessions
  # of Y km each" rather than "N sessions totalling Y km").
  if (n > 1) sprintf("%s (%d pass)", base, n) else base
}

# Format the per-sport line: "Löpning 12.2 km + cykling 9.2 km + gång 2.5 km."
.day_sports_line <- function(per_sport) {
  if (nrow(per_sport) == 0) return(NULL)
  parts <- vapply(seq_len(nrow(per_sport)), function(i) {
    .per_sport_fragment(.sport_label_sv(per_sport$sport[i]),
                        per_sport$n[i], per_sport$km[i], per_sport$min[i])
  }, character(1))
  paste0("Dagens pass: ", paste(parts, collapse = " + "), ".")
}

# Classify the dominant running session of the day, if any. Returns NULL
# when no running session was performed.
.day_running_class <- function(todays, summaries, hr_max = NULL) {
  runs <- todays %>%
    dplyr::filter(stringr::str_detect(tolower(.data$sport), "running"))
  if (nrow(runs) == 0) return(NULL)
  # If multiple running sessions, take the highest recovery-cost one
  # (high beats moderate beats low) — matches user intuition that a
  # quality session "owns the day" even if a recovery jog followed.
  classes <- lapply(seq_len(nrow(runs)), function(i) {
    classify_session(runs[i, , drop = FALSE], hr_max = hr_max,
                     summaries = summaries)
  })
  costs <- vapply(classes, function(c) {
    .recovery_cost_rank(c$recovery_cost)
  }, integer(1))
  classes[[which.max(costs)]]
}

# Format a duration the way the prose reads it out: "45 min", "2 h 15
# min", "6 h". Durations within five minutes of a whole hour — on
# either side — are read as that whole hour, so a six-hour paddle is
# announced as "6 h" rather than "5 h 58 min".
.fmt_duration_sv <- function(min) {
  if (!is.finite(min)) return(NA_character_)
  if (min < 90) return(sprintf("%d min", round(min)))
  h <- floor(min / 60)
  m <- round(min - h * 60)
  if (m > 55) { h <- h + 1; m <- 0 }
  if (m < 5) sprintf("%d h", h) else sprintf("%d h %d min", h, m)
}

# Non-running units of a session set, classified, sorted so the
# dominant effort is first: highest recovery cost, ties to longest.
# Shared by .day_alt_class() (today) and .alt_week_stats() (the week) so
# both count and classify the same units.
.alt_units <- function(sessions, summaries = NULL, hr_max = NULL,
                        min_minutes = 20) {
  if (is.null(hr_max)) {
    hr_max <- tryCatch(get_hr_max(summaries, sport = "all"),
                       error = function(e) NULL)
  }
  u <- .day_sport_units(sessions, hr_max = hr_max, classify = TRUE)
  if (nrow(u) == 0) return(u)
  is_run <- stringr::str_detect(tolower(u$sport), "running")
  is_run[is.na(is_run)] <- FALSE
  u <- u[!is_run & u$min >= min_minutes, , drop = FALSE]
  if (nrow(u) == 0) return(u)
  # Highest recovery cost owns the day; ties go to the longest effort —
  # same rule .day_running_class() applies to running.
  rank <- vapply(u$recovery_cost, .recovery_cost_rank, integer(1))
  u[order(-rank, -u$min), , drop = FALSE]
}

# Turn one row of .alt_units() back into the classify_alt_session()-shape
# list the prose helpers expect.
.alt_unit_to_class <- function(u_row) {
  list(
    class = u_row$class, intensity = u_row$intensity,
    duration_band = u_row$duration_band, duration_min = u_row$min,
    recovery_cost = u_row$recovery_cost, confidence = u_row$confidence,
    modality = u_row$modality, hr_reliability = u_row$hr_reliability,
    sport = u_row$sport
  )
}

# Classify the dominant non-running effort of the day, if any. Returns
# NULL when nothing alternative was done (or nothing long enough).
.day_alt_class <- function(todays, summaries, hr_max = NULL,
                            min_minutes = 20) {
  u <- .alt_units(todays, summaries = summaries, hr_max = hr_max,
                  min_minutes = min_minutes)
  if (nrow(u) == 0) return(NULL)
  .alt_unit_to_class(u[1, , drop = FALSE])
}

# ---- Alternative-training prose fragments ----------------------------------
#
# Composed from a functional fragment plus an optional recovery
# fragment rather than 12 hard-coded sentences, so every claim only has
# to be sourced once.

# Family `aerobic`. "Bygger aerob bas" / "stor aerob volym" rest on
# Stöggl & Sperlich 2014's HVT description (improved fat and glucose
# utilisation, beneficial for long-lasting endurance events) — the same
# source that already carries the endurance and long-run lines in
# .session_line_functional(). "Räknas som kvalitet i veckans dos" is
# Seiler 2010's HIT-frequency rule.
.alt_text_aerobic <- function(class) {
  switch(class,
    low_short = ,
    low_medium =
      "Lugnt alternativpass — rörelse till låg kostnad.",
    low_long =
      "Långt lågintensivt pass — bygger aerob bas.",
    low_very_long =
      "Mycket långt lågintensivt pass — stor aerob volym.",
    moderate_short =
      "Kort pass i mellanzonen.",
    moderate_medium = ,
    moderate_long =
      paste("Alternativpass i mellanzonen — kostar återhämtning trots",
            "att det inte är löpning."),
    moderate_very_long =
      "Långt pass i mellanzonen — hög sammanlagd belastning.",
    hard_short = ,
    hard_medium =
      "Hårt alternativpass — räknas som kvalitet i veckans dos.",
    hard_long = ,
    hard_very_long =
      "Långt och hårt alternativpass — tung post i veckan.",
    NULL)
}

# Family `other` — strength, studio work, ball sports. No adaptation
# claims: the library holds no read source on strength training, yoga
# or ball sports, so the text only describes the session's role in our
# own bookkeeping.
#
# The low_* branch is currently unreachable (every `other` sport is
# also `intermittent`, which is handled by the neutral wording above);
# it is kept so a continuous non-aerobic modality wouldn't fall through
# to NULL.
.alt_text_other <- function(class, label) {
  base <- switch(class,
    low_short = ,
    low_medium = ,
    low_long = ,
    low_very_long = ,
    moderate_short =
      sprintf("%s — utanför löpdosen, men med i veckans totalbelastning.",
              label),
    moderate_medium = ,
    moderate_long = ,
    moderate_very_long =
      sprintf("%s i mellanzonen — kostar återhämtning.", label),
    hard_short = ,
    hard_medium = ,
    hard_long = ,
    hard_very_long =
      sprintf("%s på hög puls — räknas som kvalitet i veckans dos.", label),
    NULL)
  if (is.null(base)) return(NULL)
  if (class %in% c("low_long", "low_very_long")) {
    base <- paste(base, "Volymen kostar.")
  }
  base
}

# Functional fragment for the dominant alternative session.
.alt_line_functional <- function(alt, label, dur) {
  cls <- alt$class
  if (is.null(cls) || is.na(cls)) return(NULL)

  # No HR: state what the session was and how long it lasted, nothing
  # else. "Stor volym i veckan" is a claim about the dose, not the
  # intensity, so the volume rule survives.
  if (startsWith(cls, "nohr_")) {
    if (alt$duration_min >= .ALT_DUR_LONG) {
      return(sprintf("%s %s — stor volym i veckan.", label, dur))
    }
    return(sprintf("%s %s.", label, dur))
  }

  # Mean HR underestimates intermittent work, so a low verdict is not
  # evidence of a low load. Never call such a session "lugnt".
  if (identical(alt$hr_reliability, "intermittent") &&
      identical(alt$intensity, "low")) {
    return(sprintf("%s %s — med i veckans totalbelastning.", label, dur))
  }

  if (identical(alt$modality, "aerobic")) return(.alt_text_aerobic(cls))
  .alt_text_other(cls, label)
}

# Recovery fragment. Wording is lifted from .session_line_recovery() so
# the per-pass and the end-of-day notification sound the same for the
# same physiological situation.
.alt_line_recovery <- function(alt) {
  cost <- alt$recovery_cost
  if (is.null(cost) || is.na(cost)) return(NULL)
  # Without HR there is no intensity claim to make, and every recovery
  # wording contains one.
  if (identical(alt$confidence, "none")) return(NULL)
  if (identical(cost, "high")) {
    return("Hög återhämtningskostnad; nästa kvalitetspass tidigast om 48 h.")
  }
  if (identical(cost, "moderate")) {
    if (identical(alt$intensity, "low")) {
      return("Måttlig återhämtning trots låg intensitet — volymen kostar.")
    }
    return("Måttlig återhämtning, planera lugnare i morgon.")
  }
  NULL
}

# Compose the alternative-training line. `run_recovery_cost` is the cost
# the day's running already claimed — when it matches or exceeds the
# alternative one the recovery fragment is dropped, so the notification
# doesn't say the same thing twice.
.day_alt_purpose_line <- function(alt, run_recovery_cost = NULL) {
  if (is.null(alt)) return(NULL)
  label <- .sport_label_sv(alt$sport)
  dur <- .fmt_duration_sv(alt$duration_min)
  if (is.na(dur)) return(NULL)

  functional <- .alt_line_functional(alt, label, dur)
  if (is.null(functional)) return(NULL)

  rec <- .alt_line_recovery(alt)
  if (!is.null(rec) &&
      .recovery_cost_rank(run_recovery_cost) >=
        .recovery_cost_rank(alt$recovery_cost)) {
    rec <- NULL
  }
  paste(c(functional, rec), collapse = " ")
}

# Weekly alternative-training dose. Hours are what the athlete
# recognises and the only figure that survives a missing HR reading;
# the TRIMP share is what decides whether the running-specific numbers
# still describe the week.
#
# health_daily is deliberately NULL in both TRIMP calls — everyday
# movement must not enter the denominator, or a step-heavy week drowns
# both running and alternative training.
.alt_week_stats <- function(summaries, on_date, days = 7, hr_max = NULL,
                             hr_rest = NULL, min_minutes = 20) {
  empty <- list(hours = 0, share = NA_real_, hard_count = 0L,
                nohr_fraction = NA_real_, n = 0L)
  if (is.null(summaries) || nrow(summaries) == 0) return(empty)

  on_date <- as.Date(on_date)
  start <- on_date - (days - 1)
  win <- summaries %>%
    dplyr::filter(as.Date(.data$sessionStart) >= start,
                  as.Date(.data$sessionStart) <= on_date)
  if (nrow(win) == 0) return(empty)

  if (is.null(hr_max)) {
    hr_max <- tryCatch(get_hr_max(summaries, sport = "all"),
                       error = function(e) NULL)
  }

  # Hours, hard-count and the no-HR share are unit quantities: a sport-
  # day is one session however many segments it holds, so a segmented
  # six-hour paddle is one unit (never four hard passes), and a
  # 3x15-min day is one 45-min unit that clears the 20-min gate (the
  # gate is applied after aggregation, never per segment).
  u <- .alt_units(win, summaries = summaries, hr_max = hr_max,
                  min_minutes = min_minutes)
  if (nrow(u) == 0) return(empty)

  # The TRIMP share is deliberately row-based: compute_trimp() already
  # aggregates per day and applies its own 10-min floor, so it is a
  # separate quantity, not a fifth definition of a session. It answers
  # "what fraction of the week's load was non-running", which is a load
  # ratio, not a session count.
  is_run <- stringr::str_detect(tolower(win$sport), "running")
  is_run[is.na(is_run)] <- FALSE
  alt_rows <- win[!is_run, , drop = FALSE]
  trimp_sum <- function(df) {
    res <- tryCatch(
      compute_trimp(df, hr_max = hr_max, hr_rest = hr_rest,
                    sport = "all", health_daily = NULL),
      error = function(e) NULL)
    if (is.null(res) || nrow(res) == 0) return(NA_real_)
    sum(res$daily_trimp, na.rm = TRUE)
  }
  t_alt <- trimp_sum(alt_rows)
  t_tot <- trimp_sum(win)
  share <- if (is.finite(t_alt) && is.finite(t_tot) && t_tot > 0) {
    t_alt / t_tot
  } else NA_real_

  total_min <- sum(u$min)
  nohr_min <- sum(u$min[u$confidence == "none"])
  list(
    hours = total_min / 60,
    share = share,
    hard_count = as.integer(sum(u$hard)),
    nohr_fraction = if (total_min > 0) nohr_min / total_min else NA_real_,
    n = nrow(u)
  )
}

# Format the weekly alternative-dose line. Returns NULL below the
# mention threshold.
#
# The 25% / 3 h gate is pragmatic, not research-backed: 25% is the
# point where a quarter of the week's load sits outside running and the
# running-specific numbers stop describing the week, and 3 h is the
# reserve gate for weeks where HR is missing and the share can't be
# trusted.
.alt_week_dose_line <- function(alt_week) {
  hours <- alt_week$hours
  share <- alt_week$share
  if (!is.finite(hours) || hours <= 0) return(NULL)
  mention <- (is.finite(share) && share >= 0.25) || hours >= 3
  if (!mention) return(NULL)

  # "%d%%" without a space, matching the Z2 share ("53%") that can
  # appear in the same sentence.
  nohr <- alt_week$nohr_fraction
  share_trustworthy <- is.finite(share) &&
    (!is.finite(nohr) || nohr < 0.25)
  if (!share_trustworthy) {
    return(sprintf("Alternativt: %s h.", fmt_dec_sv(hours)))
  }
  sprintf("Alternativt: %s h (%d%% av veckans belastning).",
          fmt_dec_sv(hours), round(share * 100))
}

# Compose the dominant-purpose line: "Tröskelpass dominerade dagens
# stimulus." or NULL when no running was done.
.day_purpose_line <- function(running_class, n_running) {
  if (is.null(running_class) || running_class$type == "unknown") return(NULL)
  type_sv <- switch(running_class$type,
    recovery = "lugnt löppass", endurance = "distanspass",
    long = "långpass", tempo = "tröskelpass",
    threshold_intervals = "tröskelintervaller",
    vo2max = "kvalitetspass",
    race_pace = "race-pace", race = "race-pace",
    fartlek = "fartlek", hill = "backintervaller",
    NULL)
  if (is.null(type_sv)) return(NULL)
  if (n_running > 1) {
    sprintf("Tyngdpunkt: %s.",
            paste0(toupper(substr(type_sv, 1, 1)),
                   substr(type_sv, 2, nchar(type_sv))))
  } else {
    sprintf("%s%s.", toupper(substr(type_sv, 1, 1)),
            substr(type_sv, 2, nchar(type_sv)))
  }
}

# Compose the week-context line. Combines:
#   - Z3-count-this-week (Seiler 2010 "two HIT/week" rule)
#   - rolling 28-day Z2 fraction (Esteve-Lanao 2007 / Stoggl 2014)
#   - the week's alternative-training dose
# Returns NULL when nothing notable to say.
# The 28-day window is the implications-doc default
# (adaptive-signal-per-zone__implications.md §Open questions #1).
#
# session_z3_count() and session_z2_fraction() are running-only and stay
# that way — session_prose() uses the former for per-pass text, and
# quietly widening it would move the meaning of two notifications at
# once. The lines they feed are therefore labelled "(löpning)" instead:
# a week with three hard paddling sessions and no running used to
# produce no week line at all, while the text it did produce claimed to
# describe the whole week.
#
# The overload warning is the exception: Seiler 2010's conclusion is
# about the number of high-intensity endurance sessions, not the number
# of runs, so the combined count drives it. Because mean HR
# underestimates intermittent work, the alternative count can only miss
# a hard session — it can't invent one, so the warning may fail to fire
# but will never fire falsely.
#
# Two HRmax arguments on purpose. When both are NULL each metric
# auto-detects its own anchor — `hr_max` the running one for the
# running-only counters, `hr_max_alt` the all-sport one for the
# alternative figures and compute_trimp() — so an auto-detected run
# doesn't get scored against an all-sport ceiling or vice versa. An
# *explicit* hr_max, by contrast, is a global override the caller has
# chosen for the whole summary (same contract as compute_trimp()'s
# hr_max), and day_summary_prose() passes it to both; overriding the
# denominator everywhere at once is the caller's intent, not a mix-up.
.day_week_line <- function(summaries, on_date, hr_max = NULL,
                            hr_rest = NULL, hr_max_alt = NULL) {
  z3_run <- session_z3_count(summaries, on_date = on_date, days = 7,
                              hr_max = hr_max)
  z2_28 <- session_z2_fraction(summaries, on_date = on_date, days = 28)
  alt_week <- .alt_week_stats(summaries, on_date, days = 7,
                               hr_max = hr_max_alt, hr_rest = hr_rest)
  z3_alt <- alt_week$hard_count
  z3_tot <- z3_run + z3_alt

  parts <- character()
  if (z3_tot >= 3) {
    parts <- c(parts, sprintf(
      paste("Veckan: %d hårda pass totalt (%d löpning, %d alternativt)",
            "— håll koll på återhämtningen."),
      z3_tot, z3_run, z3_alt))
  } else {
    if (z3_run == 2) {
      parts <- c(parts, "Veckan (löpning): 2 kvalitetspass, på spåret.")
    } else if (z3_run == 1) {
      parts <- c(parts, "Veckan (löpning): 1 kvalitetspass.")
    }
    if (z3_alt >= 1) {
      parts <- c(parts, sprintf("Plus %d %s alternativpass.", z3_alt,
                                if (z3_alt == 1) "hårt" else "hårda"))
    }
  }

  if (is.finite(z2_28) && z2_28 > 0.20) {
    parts <- c(parts,
      sprintf("Mellanzon-andel (löpning) %d%% senaste 28 dagarna.",
              round(z2_28 * 100)))
  }

  dose <- .alt_week_dose_line(alt_week)
  if (!is.null(dose)) parts <- c(parts, dose)

  if (length(parts) == 0) return(NULL)
  paste(parts, collapse = " ")
}

# Daily state line — combines TSB / CTL form context with the morning
# readiness verdict (HRV, sleep, RHR, load, wrist temp). Without this
# blend the day-summary can claim "form på topp" while the morning
# notification flagged Röd, because TSB and readiness use disjoint
# signal sources (training-load vs autonomic / sleep). Real example
# from logs/notifications.jsonl on 2026-05-09:
#   07:41  Dagsform 🟡 Gul 43 (HRV 32 ms, -56 vs 7d). TSB +11.3.
#   11:49  Dagsform uppdaterad: ⇒ 🔴 Röd 40.
#   21:30  "Vilodag. Form på topp — bra läge för kvalitet eller tävling."
# That last line contradicted the day's readiness verdict. Fixed by
# letting Gul/Röd readiness override or qualify the TSB phrasing.
.day_state_line <- function(summaries, health_daily, on_date,
                             hr_max = NULL, hr_rest = NULL,
                             readiness = NULL) {
  tsb_text <- tryCatch({
    pmc <- compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest,
                       health_daily = health_daily)
    if (nrow(pmc) == 0) return(NULL)
    today_idx <- which(pmc$date == on_date)
    prev_idx  <- which(pmc$date == on_date - 1)
    pmc_today <- if (length(today_idx) > 0) pmc[today_idx[1], ] else NULL
    pmc_prev  <- if (length(prev_idx) > 0)  pmc[prev_idx[1],  ] else NULL
    .line_tsb_context(pmc_today, pmc_prev)
  }, error = function(e) NULL)

  # `readiness` is normally derived inside this function; tests can
  # inject a pre-built list directly.
  if (is.null(readiness) && !is.null(health_daily) &&
      inherits(health_daily, "data.frame") &&
      nrow(health_daily) > 0) {
    readiness <- tryCatch(
      health_insight_readiness(
        traning_data(summaries = summaries, health_daily = health_daily),
        hr_max = hr_max, hr_rest = hr_rest,
        on_date = on_date),
      error = function(e) NULL
    )
  }

  status <- if (!is.null(readiness)) readiness$status else NA_character_
  if (is.null(status) || is.na(status) || nchar(status %||% "") == 0) {
    return(tsb_text)
  }

  score <- readiness$score
  ball <- switch(status,
                 "Grön" = "\U0001F7E2",
                 "Gul"  = "\U0001F7E1",
                 "Röd"  = "\U0001F534",
                 "")
  score_str <- if (is.finite(score)) sprintf(" %.0f", score) else ""
  prefix <- paste0("Dagsform ", if (nzchar(ball)) paste0(ball, " ") else "",
                   status, score_str)

  if (status == "Röd") {
    # Hard override — TSB form claim could actively mislead
    # the user when autonomic/sleep signals are degraded.
    paste0(prefix, " — återhämtningssignaler dominerar. Vila eller lugnt imorgon.")
  } else if (status == "Gul") {
    if (is.null(tsb_text)) paste0(prefix, ".")
    else paste0(prefix, ". ", tsb_text)
  } else {
    # Grön — readiness and TSB concur; keep TSB phrasing.
    tsb_text
  }
}

# ---- Main entry ------------------------------------------------------------

#' Generate end-of-day qualitative summary prose
#'
#' Aggregates Garmin + HAE sessions for a date and frames the day's
#' stimulus in week and form context. Returns Swedish prose suitable
#' for a single push notification (1--3 short sentences). On rest days,
#' returns "Vilodag." plus an optional form-context line.
#'
#' Triggered by a systemd timer at ~21:30 on kailash; see
#' \code{python/traning_cli/server/deploy/traning-daysummary.timer}.
#'
#' @param summaries Garmin summaries data frame from \code{my_dbs_load()}.
#'   Must already include HAE workouts (i.e., post
#'   \code{import_hae_workouts()}).
#' @param date Date of interest (default today).
#' @param hr_max Optional HRmax. NULL = auto-detect.
#' @param hr_rest Optional HRrest.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}. NULL = auto-load. The day-summary uses
#'   this to align its form-narrative with the morning readiness
#'   verdict (Grön / Gul / Röd) — without it, TSB-only phrasing can
#'   contradict the day's autonomic/sleep state.
#' @return Character string. Always non-empty; "Vilodag." on full
#'   rest days when no PMC context is computable.
#' @export
day_summary_prose <- function(summaries, date = Sys.Date(),
                               hr_max = NULL, hr_rest = NULL,
                               health_daily = NULL) {
  date <- as.Date(date)

  if (is.null(summaries) || nrow(summaries) == 0) {
    return("Vilodag.")
  }

  if (is.null(health_daily)) {
    health_daily <- tryCatch(load_health_data(),
                              error = function(e) NULL)
  }

  todays <- summaries %>%
    dplyr::filter(as.Date(.data$sessionStart) == date)
  per_sport <- .day_per_sport(todays)

  if (nrow(todays) == 0 || sum(per_sport$min, na.rm = TRUE) < 1) {
    base <- "Vilodag."
    state <- .day_state_line(summaries, health_daily, date, hr_max, hr_rest)
    if (!is.null(state)) return(paste(base, state))
    return(base)
  }

  parts <- character()
  l_sports <- .day_sports_line(per_sport)
  if (!is.null(l_sports)) parts <- c(parts, l_sports)

  cls <- .day_running_class(todays, summaries, hr_max = hr_max)
  # na.rm: str_detect() returns NA for an NA sport, and without this the
  # sum is NA and the `n_running > 1` test in .day_purpose_line() errors,
  # dropping the whole summary. A day with a run plus an unmapped
  # (NA-sport) session would otherwise get no prose at all — the same
  # hidden-activity failure as the NANA case, via a different path.
  n_running <- sum(stringr::str_detect(tolower(todays$sport), "running"),
                   na.rm = TRUE)
  l_purpose <- .day_purpose_line(cls, n_running)
  if (!is.null(l_purpose)) parts <- c(parts, l_purpose)

  # One all-sport HRmax anchor for every alternative-training figure in
  # this summary — the same denominator compute_trimp() uses — resolved
  # once so the day line and the week line can't disagree.
  hr_max_alt <- hr_max
  if (is.null(hr_max_alt)) {
    hr_max_alt <- tryCatch(get_hr_max(summaries, sport = "all"),
                            error = function(e) NULL)
  }

  # Alternative training gets its own line, after the running one —
  # running is the main form, so it speaks first. On a day without
  # running this line takes the running line's place.
  alt <- .day_alt_class(todays, summaries, hr_max = hr_max_alt)
  l_alt <- .day_alt_purpose_line(
    alt, run_recovery_cost = if (is.null(cls)) NULL else cls$recovery_cost)
  if (!is.null(l_alt)) parts <- c(parts, l_alt)

  l_state <- .day_state_line(summaries, health_daily, date, hr_max, hr_rest)
  if (!is.null(l_state)) parts <- c(parts, l_state)

  l_week <- .day_week_line(summaries, date, hr_max = hr_max,
                            hr_rest = hr_rest, hr_max_alt = hr_max_alt)
  if (!is.null(l_week)) parts <- c(parts, l_week)

  paste(parts, collapse = " ")
}
