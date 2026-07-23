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

# Aggregate today's sessions per sport. Returns a tibble with columns
# sport, n, km, min.
.day_per_sport <- function(todays) {
  if (nrow(todays) == 0) {
    return(tibble::tibble(sport = character(0), n = integer(0),
                          km = numeric(0), min = numeric(0)))
  }
  todays %>%
    dplyr::mutate(
      .km  = as.numeric(.data$distance) / 1000,
      .min = as.numeric(.data$durationMoving, units = "mins")
    ) %>%
    dplyr::group_by(sport = .data$sport) %>%
    dplyr::summarise(
      n   = dplyr::n(),
      km  = sum(.data$.km, na.rm = TRUE),
      min = sum(.data$.min, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::arrange(dplyr::desc(.data$km))
}

# Format the per-sport line: "Löpning 12.2 km + cykling 9.2 km + gång 2.5 km."
.day_sports_line <- function(per_sport) {
  if (nrow(per_sport) == 0) return(NULL)
  parts <- vapply(seq_len(nrow(per_sport)), function(i) {
    label <- tolower(.sport_label_sv(per_sport$sport[i]))
    n <- per_sport$n[i]; km <- per_sport$km[i]; mn <- per_sport$min[i]
    base <- if (km >= 1) {
      sprintf("%s %.1f km", label, km)
    } else if (mn > 0) {
      sprintf("%s %d min", label, round(mn))
    } else {
      label
    }
    # Annotate with pass-count only when more than one session of the
    # same sport was logged that day. Use parenthetical to avoid the
    # ambiguous "Nx Y km" reading (which could be parsed as "N sessions
    # of Y km each" rather than "N sessions totalling Y km").
    if (n > 1) sprintf("%s (%d pass)", base, n) else base
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
    switch(c$recovery_cost %||% "",
           low = 1L, moderate = 2L, high = 3L, 0L)
  }, integer(1))
  classes[[which.max(costs)]]
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
# Returns NULL when nothing notable to say.
# The 28-day window is the implications-doc default
# (adaptive-signal-per-zone__implications.md §Open questions #1).
.day_week_line <- function(summaries, on_date, hr_max = NULL) {
  z3n <- session_z3_count(summaries, on_date = on_date, days = 7,
                           hr_max = hr_max)
  z2_28 <- session_z2_fraction(summaries, on_date = on_date, days = 28)

  parts <- character()
  if (z3n >= 3) {
    parts <- c(parts,
      sprintf("Veckan: %d hårda pass — håll koll på återhämtningen.", z3n))
  } else if (z3n == 2) {
    parts <- c(parts, "Veckan: 2 kvalitetspass, på spåret.")
  } else if (z3n == 1) {
    parts <- c(parts, "Veckan: 1 kvalitetspass.")
  }

  if (is.finite(z2_28) && z2_28 > 0.20) {
    parts <- c(parts,
      sprintf("Mellanzon-andel %d%% senaste 28 dagarna.",
              round(z2_28 * 100)))
  }

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

  quality <- .readiness_quality_note(readiness$kvalitet,
                                      readiness$components %||% list())

  # At minimal quality the verdict is withheld entirely, and this is
  # deliberately *not* what the morning push does with the same field.
  # Do not "fix" the inconsistency: the two differ because they do
  # different things with the number.
  #
  # The morning states the figure and stops — nothing in
  # health_insight_readiness() derives an instruction from status or
  # score; it lists the components behind the verdict and names the
  # missing ones inline. (The one imperative that can appear in that
  # notification, the HRV-downtrend line, is computed from HRV history
  # and not from the verdict at all.) The evening attaches an
  # instruction to the same figure: the Röd branch below tells the
  # reader to rest or go easy tomorrow.
  #
  # So the morning at worst shows a wrong number, while the evening
  # turns that wrong number into a wrong instruction. On 2026-07-21 the
  # verdict was not merely thin but inverted — Röd 21 against an actual
  # 85 Grön once the gap was backfilled — and it carried advice. A
  # parenthesis does not rescue a figure read in passing, still less
  # one with an imperative attached.
  #
  # (An earlier version of this comment argued that the morning may be
  # qualified because it re-renders as components land. That is not a
  # reliable basis: health_insight_update()'s re-render trigger fires
  # only when a previously absent component becomes present, so a dead
  # feed produces no correction and the morning verdict stands all day
  # — this branch's own scenario.)
  if (!quality$trustworthy) {
    thin <- if (length(quality$missing) > 0) {
      sprintf("Dagsformen kan inte bedömas — %s saknas för dagen.",
              paste(quality$missing, collapse = "/"))
    } else {
      "Dagsformen kan inte bedömas — underlaget är för tunt."
    }
    if (is.null(tsb_text)) return(thin)
    return(paste(thin, tsb_text))
  }

  score <- readiness$score
  ball <- switch(status,
                 "Grön" = "\U0001F7E2",
                 "Gul"  = "\U0001F7E1",
                 "Röd"  = "\U0001F534",
                 "")
  score_str <- if (is.finite(score)) sprintf(" %.0f", score) else ""
  prefix <- paste0("Dagsform ", if (nzchar(ball)) paste0(ball, " ") else "",
                   status, score_str, quality$suffix)

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

# Does the day's active_energy look like a workout happened, even though
# none was logged? Metrics carry a shadow of training: a substantial
# session that never synced still leaves an unmistakable energy imprint.
# Measured 2026-05..07: rest days median ~1900 kJ (max 2589), workout
# days ~4000, and 2026-07-21 (the paddling that never synced) 7804 — four
# times the rest baseline.
#
# The test is personal and self-calibrating: today's active_energy above
# the 90th percentile of the trailing 30 days — the top tenth of one's
# own recent daily energy. A fixed multiple of a rest baseline drifts
# with season and fitness and needs a hand-picked number; the percentile
# does not. Validated on the live cache: 21 Jul (7804) is above its
# window q90 → "high"; 14 Jun (1248) and 16 Jul (2589) are not → "rest";
# zero false positives on real rest days.
#
# Returns "high", "rest", or "insufficient" (too little history, or no
# reading for the day). Callers hedge on "high" and "insufficient" and
# only trust a genuine rest day on "rest".
#
# Deliberate blind spot: a light missed session (~2100 kJ) is
# indistinguishable from an active rest day (~2600) and reads "rest".
# That is the accepted small harm — a quiet degradation, not a false
# claim — and walks are logged as workouts (Utomhus_Gang), so a big walk
# arrives as a session rather than only as energy, which caps the NEAT
# false-positive rate.
.day_energy_verdict <- function(health_daily, date,
                                 window_days = 30, min_days = 14) {
  if (is.null(health_daily) || !inherits(health_daily, "data.frame") ||
      nrow(health_daily) == 0 ||
      !all(c("date", "metric", "value") %in% names(health_daily))) {
    return("insufficient")
  }
  ae <- health_daily[health_daily$metric == "active_energy",
                     c("date", "value")]
  ae <- ae[!is.na(ae$value), ]
  if (nrow(ae) == 0) return("insufficient")
  ae$date <- as.Date(ae$date)
  today <- ae$value[ae$date == date]
  if (length(today) == 0) return("insufficient")
  today <- max(today)
  win <- ae$value[ae$date < date & ae$date >= date - window_days]
  if (length(win) < min_days) return("insufficient")
  q90 <- as.numeric(stats::quantile(win, 0.90, names = FALSE))
  if (today > q90) "high" else "rest"
}

# Rest-day guard: zero sessions can mean "rested" or "the workout feed
# died". Returns the workout flow from data_freshness() when the day's
# emptiness is not trustworthy, NULL when "Vilodag." stands.
#
# Decision tree, in order:
#   1. Positive evidence the cache is incomplete — a queue in flight, or
#      a stuck import — hedges regardless of energy: the data provably
#      has not landed.
#   2. Otherwise, if the workout flow is fresh, nothing to hedge.
#   3. Workout flow stale. If metrics are ALSO stale (or there is too
#      little energy history to judge), both sources are silent — an
#      unambiguous outage — so hedge.
#   4. Metrics fresh but workouts stale: the ambiguous case. Let the
#      day's active_energy break the tie — a session-less day carrying a
#      workout-sized energy imprint almost certainly means a session
#      that did not sync (hedge); rest-level energy means genuine rest
#      (NULL).
#
# A stale metric feed on its own never turns a genuine rest day into a
# data-missing claim — it only escalates the ambiguous case to "can't
# rule out a missed sync".
#
# Only current-day summaries are guarded. A summary for a day well in
# the past is computed from an archive that has long since been
# completed, so a feed that is quiet *today* says nothing about it —
# and measuring against Sys.time() there would retro-flag every
# historical rest day.
#
# The check must never delay or break the 21:30 notification: the whole
# probe is wrapped in tryCatch and the HTTP timeout is short.
.day_freshness_guard <- function(date, summaries, health_daily,
                                  freshness = NULL) {
  # The date gate is unconditional. Conjoining it with `is.null(freshness)`
  # would let an injected verdict reach a historical day, which is the
  # one case the gate exists to prevent — an injection seam must not
  # double as an escape hatch from an invariant.
  if (date < Sys.Date() - 1) return(NULL)
  fresh <- freshness %||% tryCatch(
    data_freshness(health_daily = health_daily, summaries = summaries,
                   status_fetch = function() .receiver_status(timeout = 3L)),
    error = function(e) NULL)
  workouts <- fresh$flows$workouts
  if (is.null(workouts)) return(NULL)

  # 1a. A queue the receiver has taken in but not yet imported makes the
  # flow demonstrably alive — and the day's material demonstrably
  # incomplete. The doctor check reads the first meaning; here we need
  # the second, because sessions sitting in that queue are exactly the
  # ones missing from `summaries` when we would otherwise say "Vilodag."
  if (isTRUE(workouts$in_flight)) {
    workouts$prose <- workouts$prose_pending
    return(workouts)
  }
  # 1b. A stuck import is positive proof the cache is incomplete.
  if (identical(workouts$queue_state, "stuck")) return(workouts)

  # 2. Workout flow fresh — a genuine rest day.
  if (isTRUE(workouts$ok)) return(NULL)

  # 3. Both flows silent — an unambiguous outage, or too little energy
  # history to judge. Hedge.
  metrics <- fresh$flows$metrics
  if (is.null(metrics) || !isTRUE(metrics$ok)) return(workouts)
  verdict <- .day_energy_verdict(health_daily, date)
  if (verdict == "insufficient") return(workouts)

  # 4. Metrics fresh: the energy imprint breaks the tie.
  if (verdict == "high") return(workouts)
  NULL
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
#' @param freshness Optional pre-computed \code{data_freshness()} list.
#'   NULL = probe the receiver (current-day summaries only). Supply
#'   this in tests to avoid network access.
#' @return Character string. Always non-empty; "Vilodag." on full
#'   rest days when no PMC context is computable, or a
#'   data-is-missing line when the feed has gone quiet.
#' @export
day_summary_prose <- function(summaries, date = Sys.Date(),
                               hr_max = NULL, hr_rest = NULL,
                               health_daily = NULL,
                               freshness = NULL) {
  date <- as.Date(date)

  # Loaded before the empty-summaries branch: the freshness guard uses
  # the newest health-metric day as fallback when the receiver does not
  # answer, and that branch is exactly where the guard matters most.
  if (is.null(health_daily)) {
    health_daily <- tryCatch(load_health_data(),
                              error = function(e) NULL)
  }

  if (is.null(summaries) || nrow(summaries) == 0) {
    stale <- .day_freshness_guard(date, summaries, health_daily, freshness)
    if (!is.null(stale)) {
      return(paste0("Inga registrerade pass — ", stale$prose))
    }
    return("Vilodag.")
  }

  todays <- summaries %>%
    dplyr::filter(as.Date(.data$sessionStart) == date)
  per_sport <- .day_per_sport(todays)

  if (nrow(todays) == 0 || sum(per_sport$min, na.rm = TRUE) < 1) {
    stale <- .day_freshness_guard(date, summaries, health_daily, freshness)
    if (!is.null(stale)) {
      # No state line in the hedge case. The guard fires here only when
      # the cache is missing sessions — a stuck/interrupted sync, or a
      # session-less day whose energy imprint says a workout went
      # unsynced — so .day_state_line()'s TSB half, computed from that
      # incomplete `summaries`, is unreliable *here specifically*. (On a
      # genuine rest day the guard returns NULL, the cache is complete,
      # and TSB is correct — that path keeps its state line below.)
      # Appending it in the hedge case revived the original contradiction
      # one class over: "underlaget är ofullständigt. Form på topp — bra
      # läge för kvalitet eller tävling.", a confident training cue built
      # on data we just called incomplete (cf. the 2026-05-09 note on
      # .day_state_line). The readiness half can be fresh, but it travels
      # with the unreliable TSB half through one function, so the honest
      # move is to drop the whole line.
      return(paste0("Inga registrerade pass — ", stale$prose))
    }
    state <- .day_state_line(summaries, health_daily, date, hr_max, hr_rest)
    if (!is.null(state)) return(paste("Vilodag.", state))
    return("Vilodag.")
  }

  parts <- character()
  l_sports <- .day_sports_line(per_sport)
  if (!is.null(l_sports)) parts <- c(parts, l_sports)

  cls <- .day_running_class(todays, summaries, hr_max = hr_max)
  n_running <- sum(stringr::str_detect(tolower(todays$sport), "running"))
  l_purpose <- .day_purpose_line(cls, n_running)
  if (!is.null(l_purpose)) parts <- c(parts, l_purpose)

  l_state <- .day_state_line(summaries, health_daily, date, hr_max, hr_rest)
  if (!is.null(l_state)) parts <- c(parts, l_state)

  l_week <- .day_week_line(summaries, date, hr_max = hr_max)
  if (!is.null(l_week)) parts <- c(parts, l_week)

  paste(parts, collapse = " ")
}
