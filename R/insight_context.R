# Insight context line — adds one prioritized "trend" sentence to the
# daily readiness notification. Picks at most one of:
#
#   1. "Comeback" streak: today had a run AND the previous run was at
#      least `threshold_days` calendar days ago (default 3). The day
#      count matches Swedish usage — "Första löpningen på 3 dagar"
#      means today minus last-run-date == 3, i.e. 2 rest days in
#      between.
#   2. ACWR commentary: low (< 0.8) or elevated (> 1.3).
#   3. HRV trend: 7-day linear slope < -0.5 ms/day.
#   4. Alcohol: energy from a logged evening, plus a recovery
#      comparison when a measure clears the gate.
#
# The first match wins; later helpers are only consulted if the
# higher-priority one is silent. Keeps the notification readable —
# no chance of three trend lines piling onto the morning push.
#
# Opt-out: TRANING_NOTIFY_CONTEXT=false in .Renviron.

.notify_context_enabled <- function() {
  v <- tolower(Sys.getenv("TRANING_NOTIFY_CONTEXT", unset = "true"))
  !v %in% c("false", "0", "no", "off")
}


# --- Comeback / streak ------------------------------------------------------

#' Generate a streak-comeback line when today is the first run after a layoff
#'
#' Triggers when today contains a run and the previous run was
#' \code{threshold_days} or more calendar days ago. The day count
#' equals \code{on_date - max(prior_run_dates)} (so 3 = 2 rest days
#' between the two runs); the wording on the Swedish side reads
#' "Första löpningen på N dagar." which matches that arithmetic.
#'
#' @keywords internal
.insight_streak_line <- function(summaries, on_date,
                                  threshold_days = 3L) {
  on_date <- as.Date(on_date)
  if (is.null(summaries) || nrow(summaries) == 0L) return(NULL)
  runs <- .filter_sport(summaries, "running")
  if (nrow(runs) == 0L) return(NULL)

  # Drop sessions whose sessionStart didn't parse — otherwise an NA
  # propagates through max(prior) and the comparison below errors
  # ("missing value where TRUE/FALSE needed").
  run_dates <- unique(as.Date(runs$sessionStart))
  run_dates <- run_dates[!is.na(run_dates)]
  if (length(run_dates) == 0L) return(NULL)
  if (!(on_date %in% run_dates)) return(NULL)

  prior <- run_dates[run_dates < on_date]
  if (length(prior) == 0L) return(NULL)

  days_since_last_run <- as.integer(on_date - max(prior))
  if (days_since_last_run >= threshold_days) {
    return(sprintf("Första löpningen på %d dagar.",
                   days_since_last_run))
  }
  NULL
}


# --- ACWR commentary --------------------------------------------------------

#' Generate an ACWR commentary line when the ratio sits in a noteworthy band
#'
#' Uses whole-system ACWR (\code{sport="all"}, auto-mode "trimp") so the
#' commentary in the morning push reflects the same scope as the rest of
#' the daily picture — vandring och cykling räknas också. The km-based
#' running ACWR is still available via \code{report_acwr()}.
#'
#' @keywords internal
.insight_acwr_line <- function(summaries, on_date, health_daily = NULL) {
  if (is.null(summaries) || nrow(summaries) == 0L) return(NULL)
  acwr_tbl <- tryCatch(
    compute_acwr(summaries, sport = "all", health_daily = health_daily),
    error = function(e) NULL
  )
  if (is.null(acwr_tbl) || nrow(acwr_tbl) == 0L) return(NULL)
  row <- acwr_tbl[acwr_tbl$date == as.Date(on_date), , drop = FALSE]
  if (nrow(row) == 0L) return(NULL)

  acwr <- row$acwr[[1]]
  if (!is.finite(acwr) || acwr <= 0) return(NULL)

  if (acwr < 0.8) {
    return(sprintf("ACWR %s — låg belastning, bra återhämtning.",
                   fmt_dec_sv(acwr, digits = 2)))
  }
  if (acwr > 1.5) {
    return(sprintf("ACWR %s — hög belastning, skadetröskeln i sikte.",
                   fmt_dec_sv(acwr, digits = 2)))
  }
  if (acwr > 1.3) {
    return(sprintf("ACWR %s — något hög belastning, försiktigt framåt.",
                   fmt_dec_sv(acwr, digits = 2)))
  }
  NULL
}


# --- HRV trend --------------------------------------------------------------

#' Generate an HRV downtrend line when the 7-day slope is meaningfully negative
#' @keywords internal
.insight_hrv_trend_line <- function(health_daily, on_date,
                                     slope_threshold = -0.5,
                                     window_days = 7L,
                                     min_samples = 5L) {
  if (is.null(health_daily) || nrow(health_daily) == 0L) return(NULL)
  hrv <- health_daily[health_daily$metric == "heart_rate_variability",
                      , drop = FALSE]
  if (nrow(hrv) < min_samples) return(NULL)

  hrv$date <- as.Date(hrv$date)
  hrv <- hrv[order(hrv$date), ]
  window_end   <- as.Date(on_date)
  window_start <- window_end - (as.integer(window_days) - 1L)
  in_window <- hrv[hrv$date >= window_start & hrv$date <= window_end, ]
  in_window <- in_window[!is.na(in_window$value), ]
  if (nrow(in_window) < min_samples) return(NULL)

  # Linear least squares on (day_offset, value). lsfit() avoids the
  # weight of pulling in lm()/summary().
  x <- as.numeric(in_window$date - window_start)
  y <- in_window$value
  fit <- tryCatch(stats::lsfit(x, y), error = function(e) NULL)
  if (is.null(fit)) return(NULL)
  slope <- fit$coefficients[[2]]

  if (is.finite(slope) && slope < slope_threshold) {
    return("HRV sjunkande trend — ta det lugnt idag.")
  }
  NULL
}


# --- Composer ---------------------------------------------------------------

#' Pick at most one insight-context line, by priority
#'
#' Priority order is fixed:
#' \enumerate{
#'   \item Comeback streak (\code{.insight_streak_line}).
#'   \item ACWR commentary (\code{.insight_acwr_line}).
#'   \item HRV downtrend (\code{.insight_hrv_trend_line}).
#'   \item Alcohol (\code{.insight_alcohol_line}).
#' }
#'
#' Alcohol sits last on purpose. The three lines above it are about
#' training state, which is what the morning push exists to report; the
#' alcohol line is an annotation on that state, and an annotation should
#' never displace the thing it annotates.
#'
#' Returns \code{NULL} when no helper has anything to say.
#'
#' @keywords internal
.insight_context_line <- function(summaries, health_daily, on_date,
                                   alcohol = NULL) {
  candidates <- list(
    function() .insight_streak_line(summaries, on_date),
    function() .insight_acwr_line(summaries, on_date,
                                    health_daily = health_daily),
    function() .insight_hrv_trend_line(health_daily, on_date),
    function() .insight_alcohol_line(alcohol, health_daily, on_date,
                                       summaries = summaries)
  )
  for (fn in candidates) {
    line <- tryCatch(fn(), error = function(e) NULL)
    if (!is.null(line) && length(line) == 1L && nzchar(line)) return(line)
  }
  NULL
}
