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
    pmc <- compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest)
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
      health_insight_readiness(health_daily, summaries,
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
  n_running <- sum(stringr::str_detect(tolower(todays$sport), "running"))
  l_purpose <- .day_purpose_line(cls, n_running)
  if (!is.null(l_purpose)) parts <- c(parts, l_purpose)

  l_state <- .day_state_line(summaries, health_daily, date, hr_max, hr_rest)
  if (!is.null(l_state)) parts <- c(parts, l_state)

  l_week <- .day_week_line(summaries, date, hr_max = hr_max)
  if (!is.null(l_week)) parts <- c(parts, l_week)

  paste(parts, collapse = " ")
}
