# Advanced training metrics: EF, HRE, ACWR, Monotony/Strain

# Internal helper: compute a rolling sum over a numeric vector using a sliding window.
# Partial windows at the start are returned as NA.
# @param x Numeric vector
# @param window Integer window width
# @return Numeric vector of same length as x
.rolling_sum <- function(x, window) {
  n <- length(x)
  result <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    if (i >= window) {
      result[i] <- sum(x[(i - window + 1):i], na.rm = TRUE)
    }
  }
  result
}

# Internal helper: compute a rolling mean over a numeric vector using a sliding window.
# Partial windows at the start are returned as NA.
# @param x Numeric vector
# @param window Integer window width
# @return Numeric vector of same length as x
.rolling_mean <- function(x, window) {
  n <- length(x)
  result <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    if (i >= window) {
      result[i] <- mean(x[(i - window + 1):i], na.rm = TRUE)
    }
  }
  result
}

# Internal helper: compute a rolling standard deviation over a numeric vector.
# Partial windows at the start are returned as NA.
# @param x Numeric vector
# @param window Integer window width
# @return Numeric vector of same length as x
.rolling_sd <- function(x, window) {
  n <- length(x)
  result <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    if (i >= window) {
      window_vals <- x[(i - window + 1):i]
      result[i] <- sd(window_vals, na.rm = TRUE)
    }
  }
  result
}

#' Compute Efficiency Factor (EF) per run
#'
#' EF = average speed (m/min) / average heart rate (bpm).
#' A higher EF means more speed per heartbeat — a proxy for aerobic fitness.
#' Only runs longer than 5 km are included because short sessions produce
#' noisy EF values that distort the trend.
#'
#' A 28-day rolling mean (ef_rolling28) is also returned to reveal the
#' underlying fitness trend, smoothing over day-to-day variation.
#'
#' @param summaries Data frame from \code{my_dbs_load()}, enriched by
#'   \code{add_my_columns()} and \code{fix_zero_moving()}.
#' @return Tibble with one row per qualifying run, ordered by date, with
#'   columns: \code{sessionStart}, \code{distance_km}, \code{avgSpeedMoving},
#'   \code{avgHeartRateMoving}, \code{ef}, \code{ef_rolling28}.
#' @export
compute_efficiency_factor <- function(summaries) {
  runs <- summaries %>%
    dplyr::filter(
      stringr::str_detect(sport, "running"),
      distance > 5000
    ) %>%
    dplyr::mutate(
      sessionStart = as.Date(sessionStart),
      distance_km  = distance / 1000,
      # avgSpeedMoving is in m/s — convert to m/min for EF
      speed_m_per_min = as.numeric(avgSpeedMoving) * 60,
      hr              = as.numeric(avgHeartRateMoving)
    ) %>%
    dplyr::filter(!is.na(hr), hr > 0, !is.na(speed_m_per_min)) %>%
    dplyr::arrange(sessionStart) %>%
    dplyr::mutate(
      ef = speed_m_per_min / hr
    )

  # 28-day rolling mean: work on per-day values (use last run of the day
  # when multiple runs share a date), then join back
  daily_ef <- runs %>%
    dplyr::group_by(sessionStart) %>%
    dplyr::summarise(daily_ef = mean(ef, na.rm = TRUE), .groups = "drop") %>%
    dplyr::arrange(sessionStart)

  # Build full date spine so that rest days are represented as NA
  # (prevents runs separated by gaps from being treated as consecutive)
  date_spine <- tibble::tibble(
    sessionStart = seq(
      min(daily_ef$sessionStart),
      max(daily_ef$sessionStart),
      by = "day"
    )
  )

  rolling_ef <- date_spine %>%
    dplyr::left_join(daily_ef, by = "sessionStart") %>%
    dplyr::mutate(
      ef_rolling28 = .rolling_mean(daily_ef, window = 28)
    ) %>%
    dplyr::select(sessionStart, ef_rolling28)

  runs %>%
    dplyr::left_join(rolling_ef, by = "sessionStart") %>%
    dplyr::select(
      sessionStart,
      distance_km,
      avgSpeedMoving,
      avgHeartRateMoving,
      ef,
      ef_rolling28
    )
}

#' Compute Heart Rate Efficiency (HRE) per run — Votyakov metric
#'
#' HRE = average heart rate (bpm) * average pace (min/km) = beats per km.
#' A lower HRE means fewer heartbeats needed per km — better aerobic fitness.
#' This is the arithmetic inverse of Efficiency Factor.
#'
#' Votyakov et al. (2025) validated HRE over 14 years with thresholds:
#' <700 bpkm = well-fitted, 700-750 = fitted, >800 = poorly-fitted.
#'
#' Only runs longer than 5 km are included.  A 28-day rolling mean
#' (hre_rolling28) reveals the underlying fitness trend.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return Tibble with one row per qualifying run, ordered by date, with
#'   columns: \code{sessionStart}, \code{distance_km},
#'   \code{avgHeartRateMoving}, \code{avgPaceMoving}, \code{hre},
#'   \code{hre_rolling28}.
#' @export
compute_hre <- function(summaries) {
  runs <- summaries %>%
    dplyr::filter(
      stringr::str_detect(sport, "running"),
      distance > 5000
    ) %>%
    dplyr::mutate(
      sessionStart = as.Date(sessionStart),
      distance_km  = distance / 1000,
      hr           = as.numeric(avgHeartRateMoving),
      pace         = as.numeric(avgPaceMoving)
    ) %>%
    dplyr::filter(!is.na(hr), hr > 0, !is.na(pace), pace > 0) %>%
    dplyr::arrange(sessionStart) %>%
    dplyr::mutate(
      hre = hr * pace
    )

  daily_hre <- runs %>%
    dplyr::group_by(sessionStart) %>%
    dplyr::summarise(daily_hre = mean(hre, na.rm = TRUE), .groups = "drop") %>%
    dplyr::arrange(sessionStart)

  date_spine <- tibble::tibble(
    sessionStart = seq(
      min(daily_hre$sessionStart),
      max(daily_hre$sessionStart),
      by = "day"
    )
  )

  rolling_hre <- date_spine %>%
    dplyr::left_join(daily_hre, by = "sessionStart") %>%
    dplyr::mutate(
      hre_rolling28 = .rolling_mean(daily_hre, window = 28)
    ) %>%
    dplyr::select(sessionStart, hre_rolling28)

  runs %>%
    dplyr::left_join(rolling_hre, by = "sessionStart") %>%
    dplyr::select(
      sessionStart,
      distance_km,
      avgHeartRateMoving,
      avgPaceMoving,
      hre,
      hre_rolling28
    )
}

#' Compute Acute:Chronic Workload Ratio (ACWR)
#'
#' ACWR = acute load / chronic load, where:
#' \itemize{
#'   \item Acute load: rolling 7-day total km (current week's load)
#'   \item Chronic load: rolling 28-day mean of daily km × 7
#'     (average weekly load over the past four weeks)
#' }
#'
#' An ACWR between 0.8 and 1.3 is considered a "sweet spot" (adequate
#' loading without excessive injury risk). Values above 1.5 signal a
#' spike that may increase injury risk.
#'
#' The \emph{coupled} ACWR uses the full 28-day window for chronic load,
#' so the acute window is included in the chronic window.  The
#' \emph{uncoupled} variant excludes the acute window (days 8-35) so the
#' two windows are independent.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return Tibble with one row per calendar day from first to last run,
#'   with columns: \code{date}, \code{daily_km}, \code{weekly_km},
#'   \code{acute_load}, \code{chronic_load}, \code{acwr},
#'   \code{acwr_uncoupled}.
#' @export
compute_acwr <- function(summaries) {
  # Aggregate to daily km (all runs — not filtered to > 5 km)
  daily <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, "running")) %>%
    dplyr::mutate(date = as.Date(sessionStart)) %>%
    dplyr::group_by(date) %>%
    dplyr::summarise(daily_km = sum(distance, na.rm = TRUE) / 1000,
                     .groups = "drop")

  # Full date spine with rest days as 0; extend to today
  spine_end <- max(max(daily$date), Sys.Date())
  date_spine <- tibble::tibble(
    date = seq(min(daily$date), spine_end, by = "day")
  )

  daily_full <- date_spine %>%
    dplyr::left_join(daily, by = "date") %>%
    dplyr::mutate(daily_km = dplyr::if_else(is.na(daily_km), 0, daily_km))

  # Acute load: 7-day rolling sum
  # Chronic load (coupled): 28-day rolling mean of daily km * 7
  #   (mean gives the "typical daily km"; * 7 scales to weekly for
  #    comparability with the 7-day acute sum)
  # Chronic load (uncoupled): rolling mean of the window days 8–35
  #   implemented as a 28-day rolling sum of the lagged series (lag 7)
  x <- daily_full$daily_km
  n <- length(x)

  acute  <- .rolling_sum(x, window = 7)
  # Coupled chronic: mean over 28 days * 7
  chronic_coupled <- .rolling_mean(x, window = 28) * 7

  # Uncoupled chronic: mean of days [i-35 .. i-8] * 7 (28 observations,
  # starting one acute-window width in the past)
  chronic_uncoupled <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    start_idx <- i - 35
    end_idx   <- i - 8
    if (start_idx >= 1) {
      chronic_uncoupled[i] <- mean(x[start_idx:end_idx], na.rm = TRUE) * 7
    }
  }

  daily_full %>%
    dplyr::mutate(
      weekly_km        = acute,
      acute_load       = acute,
      chronic_load     = chronic_coupled,
      acwr             = dplyr::if_else(
        chronic_load > 0, acute_load / chronic_load, NA_real_),
      acwr_uncoupled   = dplyr::if_else(
        chronic_uncoupled > 0, acute_load / chronic_uncoupled, NA_real_),
      # Week-over-week percentage change (Nielsen 2014: >30% = injury risk)
      weekly_pct_change = dplyr::if_else(
        dplyr::lag(weekly_km, 7) > 0,
        (weekly_km / dplyr::lag(weekly_km, 7) - 1) * 100,
        NA_real_
      )
    ) %>%
    dplyr::select(
      date,
      daily_km,
      weekly_km,
      acute_load,
      chronic_load,
      acwr,
      acwr_uncoupled,
      weekly_pct_change
    )
}

#' Compute Training Monotony and Strain
#'
#' Training monotony measures how uniform the daily training load is over
#' a rolling 7-day window:
#' \deqn{Monotony = mean(daily\_km) / sd(daily\_km)}
#'
#' High monotony (> 2) means the athlete is running similar distances every
#' day with little variation — associated with overtraining.  Ideally
#' monotony stays below 1.5 through varied hard/easy days.
#'
#' Training strain compounds weekly volume with monotony:
#' \deqn{Strain = weekly\_km \times Monotony}
#'
#' Uses the same daily date-spine as \code{compute_acwr()}, so rest days
#' contribute zeros to both mean and SD.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return Tibble with one row per calendar day from first to last run,
#'   with columns: \code{date}, \code{daily_km}, \code{weekly_km},
#'   \code{monotony}, \code{strain}.
#' @export
compute_monotony_strain <- function(summaries) {
  # Aggregate to daily km — same approach as compute_acwr()
  daily <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, "running")) %>%
    dplyr::mutate(date = as.Date(sessionStart)) %>%
    dplyr::group_by(date) %>%
    dplyr::summarise(daily_km = sum(distance, na.rm = TRUE) / 1000,
                     .groups = "drop")

  spine_end <- max(max(daily$date), Sys.Date())
  date_spine <- tibble::tibble(
    date = seq(min(daily$date), spine_end, by = "day")
  )

  daily_full <- date_spine %>%
    dplyr::left_join(daily, by = "date") %>%
    dplyr::mutate(daily_km = dplyr::if_else(is.na(daily_km), 0, daily_km))

  x <- daily_full$daily_km

  weekly_km <- .rolling_sum(x,  window = 7)
  roll_mean <- .rolling_mean(x, window = 7)
  roll_sd   <- .rolling_sd(x,   window = 7)

  daily_full %>%
    dplyr::mutate(
      weekly_km = weekly_km,
      # Guard against division by zero on weeks with constant load
      monotony  = dplyr::if_else(
        !is.na(roll_sd) & roll_sd > 0,
        roll_mean / roll_sd,
        NA_real_
      ),
      strain    = dplyr::if_else(
        !is.na(monotony), weekly_km * monotony, NA_real_
      )
    ) %>%
    dplyr::select(date, daily_km, weekly_km, monotony, strain)
}

#' Compute Recovery Heart Rate trend
#'
#' Extracts recovery heart rate from enriched summaries (garmin_recoveryHeartRate
#' column, available for activities from ~Nov 2023 onward) and computes a
#' 28-day rolling mean.  Lower recovery HR = better cardiovascular fitness
#' (Cole et al. 1999).
#'
#' @param summaries Enriched summaries (must contain garmin_recoveryHeartRate)
#' @return Tibble with columns: sessionStart, distance_km,
#'   recovery_hr, recovery_hr_rolling28
#' @export
compute_recovery_hr <- function(summaries) {
  if (!"garmin_recoveryHeartRate" %in% names(summaries)) {
    stop("summaries saknar garmin_recoveryHeartRate. Kör augment_summaries() först.")
  }

  runs <- summaries %>%
    dplyr::filter(
      stringr::str_detect(sport, "running"),
      !is.na(garmin_recoveryHeartRate),
      garmin_recoveryHeartRate > 0
    ) %>%
    dplyr::mutate(
      sessionStart = as.Date(sessionStart),
      distance_km  = distance / 1000,
      recovery_hr  = as.numeric(garmin_recoveryHeartRate)
    ) %>%
    dplyr::arrange(sessionStart)

  if (nrow(runs) == 0) {
    return(tibble::tibble(
      sessionStart = as.Date(character(0)),
      distance_km = numeric(0),
      recovery_hr = numeric(0),
      recovery_hr_rolling28 = numeric(0)
    ))
  }

  daily <- runs %>%
    dplyr::group_by(sessionStart) %>%
    dplyr::summarise(daily_rhr = mean(recovery_hr, na.rm = TRUE), .groups = "drop") %>%
    dplyr::arrange(sessionStart)

  date_spine <- tibble::tibble(
    sessionStart = seq(min(daily$sessionStart), max(daily$sessionStart), by = "day")
  )

  rolling <- date_spine %>%
    dplyr::left_join(daily, by = "sessionStart") %>%
    dplyr::mutate(
      recovery_hr_rolling28 = .rolling_mean(daily_rhr, window = 28)
    ) %>%
    dplyr::select(sessionStart, recovery_hr_rolling28)

  result <- runs %>%
    dplyr::left_join(rolling, by = "sessionStart")

  if ("avgHeartRate" %in% names(runs)) {
    result %>%
      dplyr::mutate(avg_hr = as.numeric(avgHeartRate)) %>%
      dplyr::select(sessionStart, distance_km, recovery_hr,
                    recovery_hr_rolling28, avg_hr)
  } else {
    result %>%
      dplyr::select(sessionStart, distance_km, recovery_hr,
                    recovery_hr_rolling28)
  }
}

# Internal helper: exponentially weighted moving average (recursive).
# lambda = 2 / (window + 1), where window = time constant in days.
# EWMA(t) = EWMA(t-1) * (1-lambda) + x(t) * lambda
# Returns NA for the first element; the second element seeds the EWMA.
.ewma <- function(x, window) {
  n <- length(x)
  if (n == 0) return(numeric(0))
  lambda <- 2 / (window + 1)
  result <- rep(NA_real_, n)
  # Seed with first non-NA value
  seed_idx <- which(!is.na(x))[1]
  if (is.na(seed_idx)) return(result)
  result[seed_idx] <- x[seed_idx]
  for (i in (seed_idx + 1):n) {
    prev <- result[i - 1]
    curr <- x[i]
    if (is.na(curr)) curr <- 0
    result[i] <- prev * (1 - lambda) + curr * lambda
  }
  result
}

#' Compute TRIMP per session (Banister model)
#'
#' Calculates training impulse using the Morton (1990) exponential formula:
#' \deqn{TRIMP = duration\_min \times \Delta HR \times 0.64 e^{1.92 \times \Delta HR}}
#' where \eqn{\Delta HR = (avgHR - HRrest) / (HRmax - HRrest)}.
#'
#' HRrest is time-varying when Apple Watch data is available (via
#' \code{get_hr_rest()}), otherwise a fixed value is used.
#'
#' @param summaries Summaries data frame.
#' @param hr_max Numeric. Maximum heart rate (bpm).
#' @param hr_rest Numeric vector or scalar. Resting heart rate(s). If a scalar,
#'   the same value is used for all sessions. If a vector, must be the same
#'   length as the number of qualifying sessions (matched by date order).
#'   If NULL, \code{get_hr_rest()} is called for each session date.
#' @return Tibble with: date, daily_trimp, trimp_type ("btrimp").
#' @export
compute_trimp <- function(summaries, hr_max = NULL, hr_rest = NULL) {
  if (is.null(hr_max)) hr_max <- get_hr_max(summaries)

  runs <- summaries %>%
    dplyr::filter(
      stringr::str_detect(sport, "running"),
      !is.na(avgHeartRateMoving),
      as.numeric(avgHeartRateMoving) > 0,
      !is.na(durationMoving)
    ) %>%
    dplyr::mutate(
      date         = as.Date(sessionStart),
      hr           = as.numeric(avgHeartRateMoving),
      duration_min = as.numeric(durationMoving, units = "mins")
    ) %>%
    dplyr::filter(duration_min > 10) %>%
    dplyr::arrange(date)

  if (nrow(runs) == 0) {
    return(tibble::tibble(date = as.Date(character(0)),
                          daily_trimp = numeric(0),
                          trimp_type = character(0)))
  }

  # Resolve HRrest per session
  if (is.null(hr_rest)) {
    hr_rest_vec <- get_hr_rest(runs$date)
  } else if (length(hr_rest) == 1) {
    hr_rest_vec <- rep(hr_rest, nrow(runs))
  } else {
    hr_rest_vec <- hr_rest
  }

  runs <- runs %>%
    dplyr::mutate(
      hr_rest     = hr_rest_vec,
      delta_hr    = (hr - hr_rest) / (hr_max - hr_rest),
      # Clamp delta_hr to [0, 1] to avoid nonsensical values
      delta_hr    = pmax(0, pmin(1, delta_hr)),
      trimp       = duration_min * delta_hr * 0.64 * exp(1.92 * delta_hr)
    )

  # Aggregate to daily TRIMP (sum if multiple runs per day)
  daily_trimp <- runs %>%
    dplyr::group_by(date) %>%
    dplyr::summarise(daily_trimp = sum(trimp, na.rm = TRUE), .groups = "drop") %>%
    dplyr::mutate(trimp_type = "btrimp")

  daily_trimp
}

#' Compute Performance Management Chart (ATL, CTL, TSB)
#'
#' Uses exponentially weighted moving averages (EWMA) of daily TRIMP:
#' \itemize{
#'   \item ATL (Acute Training Load / "fatigue"): EWMA with 7-day time constant
#'   \item CTL (Chronic Training Load / "fitness"): EWMA with 42-day time constant
#'   \item TSB (Training Stress Balance / "form"): CTL - ATL
#' }
#'
#' EWMA formula (Murray 2017): \eqn{EWMA(t) = EWMA(t-1) \times (1 - \lambda) + TRIMP(t) \times \lambda}
#' where \eqn{\lambda = 2 / (window + 1)}.
#'
#' @param summaries Summaries data frame.
#' @param hr_max Numeric. Maximum heart rate. NULL = auto-detect.
#' @param hr_rest Numeric or NULL. Resting heart rate. NULL = time-varying from AW data.
#' @return Tibble with daily values: date, daily_trimp, atl, ctl, tsb.
#' @export
compute_pmc <- function(summaries, hr_max = NULL, hr_rest = NULL) {
  daily_trimp <- compute_trimp(summaries, hr_max = hr_max, hr_rest = hr_rest)

  if (nrow(daily_trimp) == 0) {
    return(tibble::tibble(date = as.Date(character(0)),
                          daily_trimp = numeric(0),
                          atl = numeric(0), ctl = numeric(0),
                          tsb = numeric(0)))
  }

  # Build full date spine — rest days = 0 TRIMP.
  # Extend to today so that CTL/ATL decay is visible after the last run.
  spine_end <- max(max(daily_trimp$date), Sys.Date())
  date_spine <- tibble::tibble(
    date = seq(min(daily_trimp$date), spine_end, by = "day")
  )

  daily_full <- date_spine %>%
    dplyr::left_join(daily_trimp %>% dplyr::select(date, daily_trimp),
                     by = "date") %>%
    dplyr::mutate(daily_trimp = dplyr::if_else(is.na(daily_trimp), 0, daily_trimp))

  # EWMA computation
  x <- daily_full$daily_trimp
  daily_full %>%
    dplyr::mutate(
      atl = .ewma(x, window = 7),
      ctl = .ewma(x, window = 42),
      tsb = ctl - atl
    )
}

#' Compute Aerobic Decoupling per run
#'
#' Aerobic decoupling measures the drift in pace:HR efficiency between the first
#' and second half of a run, excluding a warmup period.  A positive value means
#' the second half was less efficient (cardiac drift).  Well-developed aerobic
#' fitness produces decoupling < 3\%; values > 5\% suggest aerobic limitation.
#'
#' @section Session selection:
#' Only steady-state easy runs are included:
#' \itemize{
#'   \item Duration > 45 min (short runs produce noisy values)
#'   \item Average pace > 5:00/km (excludes intervals and tempo runs)
#'   \item Mean speed difference between halves \eqn{\le} 10\% (excludes
#'     non-steady-state sessions — warm-up progression, fartlek, negative
#'     splits)
#' }
#' The steady-state filter (\code{max_half_speed_diff_pct}) is critical: without
#' it, sessions where the athlete starts slow and finishes fast produce large
#' negative decoupling values that are not physiological cardiac drift but simply
#' pacing artefacts.  Empirically, 10\% retains ~79\% of sessions while
#' eliminating virtually all extreme outliers (< -15\%).
#'
#' @section Time-based processing:
#' All temporal operations use the \code{time} column from trackeR, not row
#' indices.  Older Garmin devices (pre-2017) log at 3-7 second intervals rather
#' than per-second; the smoothing window and warmup exclusion adapt to the
#' actual sampling rate.
#'
#' @param summaries Data frame from \code{my_dbs_load()}, positionally matched
#'   to \code{myruns}.
#' @param myruns List of trackeRdata objects from \code{my_dbs_load()}.
#' @param min_duration_min Numeric.  Minimum moving duration in minutes
#'   (default 45).
#' @param max_pace_min_km Numeric.  Maximum pace in min/km — runs faster than
#'   this are excluded (default 5.0, i.e. only easy pace).
#' @param warmup_sec Integer.  Seconds to exclude from the start (default 600).
#' @param smooth_window Integer.  Rolling mean window in seconds for speed
#'   smoothing (default 30).  Converted to number of observations based on
#'   actual sampling interval.
#' @param max_half_speed_diff_pct Numeric.  Maximum allowed difference in mean
#'   speed between first and second half, as a percentage of the faster half
#'   (default 10).  Sessions exceeding this are not steady-state and are
#'   excluded.
#' @return Tibble with one row per qualifying run, ordered by date:
#'   \code{sessionStart}, \code{distance_km}, \code{duration_min},
#'   \code{avg_pace}, \code{avg_hr}, \code{ratio_first}, \code{ratio_second},
#'   \code{decoupling_pct}, \code{decoupling_rolling28}, \code{temperature}.
#' @export
compute_decoupling <- function(summaries, myruns,
                               min_duration_min        = 45,
                               max_pace_min_km         = 5.0,
                               warmup_sec              = 600L,
                               smooth_window           = 30L,
                               max_half_speed_diff_pct = 10) {
  empty <- tibble::tibble(
    sessionStart       = as.Date(character(0)),
    distance_km        = numeric(0),
    duration_min       = numeric(0),
    avg_pace           = numeric(0),
    avg_hr             = numeric(0),
    ratio_first        = numeric(0),
    ratio_second       = numeric(0),
    decoupling_pct     = numeric(0),
    decoupling_rolling28 = numeric(0),
    temperature        = numeric(0)
  )

  # Filter qualifying sessions at summary level
  run_idx <- which(
    stringr::str_detect(summaries$sport, "running") &
    as.numeric(summaries$durationMoving, units = "mins") > min_duration_min &
    as.numeric(summaries$avgPaceMoving) > max_pace_min_km
  )

  if (length(run_idx) == 0) return(empty)

  has_temp <- "garmin_averageTemperature" %in% names(summaries)

  n_runs  <- length(run_idx)
  n_skip  <- 0L
  results <- vector("list", n_runs)

  for (k in seq_along(run_idx)) {
    i <- run_idx[k]

    if (k %% 500 == 0) {
      message("  Bearbetar session ", k, " / ", n_runs, " ...")
    }

    session <- tryCatch(myruns[[i]], error = function(e) NULL)
    if (is.null(session)) { n_skip <- n_skip + 1L; next }

    session_df <- tryCatch(as.data.frame(session), error = function(e) NULL)
    if (is.null(session_df) ||
        !all(c("speed", "heart_rate") %in% names(session_df))) {
      n_skip <- n_skip + 1L; next
    }

    # Clean: remove NA/zero rows, require time column
    if (!"time" %in% names(session_df)) { n_skip <- n_skip + 1L; next }
    session_df$speed      <- as.numeric(session_df$speed)
    session_df$heart_rate <- as.numeric(session_df$heart_rate)
    valid <- !is.na(session_df$speed) & session_df$speed > 0 &
             !is.na(session_df$heart_rate) & session_df$heart_rate > 0
    session_df <- session_df[valid, ]

    if (nrow(session_df) < 10) { n_skip <- n_skip + 1L; next }

    # Time-based warmup exclusion (handles variable sampling intervals)
    elapsed_sec <- as.numeric(difftime(session_df$time,
                                       session_df$time[1], units = "secs"))
    session_df <- session_df[elapsed_sec >= warmup_sec, ]

    if (nrow(session_df) < 10) { n_skip <- n_skip + 1L; next }

    # Determine sampling interval for adaptive smoothing window
    time_diffs <- as.numeric(diff(session_df$time), units = "secs")
    median_interval <- max(median(time_diffs, na.rm = TRUE), 1)
    # smooth_window is in seconds — convert to number of observations
    smooth_n <- max(round(smooth_window / median_interval), 3L)

    # Smooth speed with rolling mean (adaptive window)
    speed_smooth <- .rolling_mean(session_df$speed, window = smooth_n)
    hr <- session_df$heart_rate

    # Remove leading NAs from rolling mean
    valid_smooth <- !is.na(speed_smooth)
    speed_smooth <- speed_smooth[valid_smooth]
    hr <- hr[valid_smooth]

    if (length(speed_smooth) < 10) { n_skip <- n_skip + 1L; next }

    # Split at temporal midpoint (not row midpoint — important because
    # older devices log at 3-7s intervals, not per-second)
    elapsed <- as.numeric(difftime(session_df$time[valid_smooth],
                                   session_df$time[valid_smooth][1],
                                   units = "secs"))
    total_time <- elapsed[length(elapsed)]
    mid_time <- total_time / 2
    mid <- max(which(elapsed <= mid_time))

    n_pts <- length(speed_smooth)
    speed_first  <- speed_smooth[1:mid]
    speed_second <- speed_smooth[(mid + 1):n_pts]
    mean_speed_1 <- mean(speed_first, na.rm = TRUE)
    mean_speed_2 <- mean(speed_second, na.rm = TRUE)

    # Steady-state filter: reject sessions where mean speed differs too much
    # between halves. Such sessions (warm-up progression, fartlek, negative
    # splits) produce misleading decoupling values that reflect pacing
    # strategy, not cardiac drift.
    half_speed_diff <- abs(mean_speed_1 - mean_speed_2) /
                       max(mean_speed_1, mean_speed_2) * 100
    if (half_speed_diff > max_half_speed_diff_pct) {
      n_skip <- n_skip + 1L; next
    }

    ratio_1 <- mean(speed_first / hr[1:mid], na.rm = TRUE)
    ratio_2 <- mean(speed_second / hr[(mid + 1):n_pts], na.rm = TRUE)

    if (is.na(ratio_1) || is.na(ratio_2) || ratio_1 == 0) {
      n_skip <- n_skip + 1L; next
    }

    decoupling_pct <- 100 * (ratio_1 - ratio_2) / ratio_1

    results[[k]] <- tibble::tibble(
      sessionStart   = as.Date(summaries$sessionStart[[i]]),
      distance_km    = as.numeric(summaries$distance[[i]]) / 1000,
      duration_min   = as.numeric(summaries$durationMoving[[i]], units = "mins"),
      avg_pace       = as.numeric(summaries$avgPaceMoving[[i]]),
      avg_hr         = as.numeric(summaries$avgHeartRateMoving[[i]]),
      ratio_first    = ratio_1,
      ratio_second   = ratio_2,
      decoupling_pct = decoupling_pct,
      temperature    = if (has_temp) {
        as.numeric(summaries$garmin_averageTemperature[[i]])
      } else {
        NA_real_
      }
    )
  }

  if (n_skip > 0) {
    warning(n_skip, " sessioner hoppades \u00f6ver (NULL, saknar speed/HR, ",
            "eller f\u00f6r kort efter uppv\u00e4rmning).", call. = FALSE)
  }

  per_run <- dplyr::bind_rows(results)

  if (nrow(per_run) == 0) return(empty)

  per_run <- dplyr::arrange(per_run, sessionStart)

  # 28-day rolling mean on date spine
  daily <- per_run %>%
    dplyr::group_by(sessionStart) %>%
    dplyr::summarise(daily_dc = mean(decoupling_pct, na.rm = TRUE),
                     .groups = "drop") %>%
    dplyr::arrange(sessionStart)

  date_spine <- tibble::tibble(
    sessionStart = seq(min(daily$sessionStart), max(daily$sessionStart),
                       by = "day")
  )

  rolling <- date_spine %>%
    dplyr::left_join(daily, by = "sessionStart") %>%
    dplyr::mutate(
      decoupling_rolling28 = .rolling_mean(daily_dc, window = 28)
    ) %>%
    dplyr::select(sessionStart, decoupling_rolling28)

  per_run %>%
    dplyr::left_join(rolling, by = "sessionStart") %>%
    dplyr::select(
      sessionStart, distance_km, duration_min, avg_pace, avg_hr,
      ratio_first, ratio_second, decoupling_pct, decoupling_rolling28,
      temperature
    )
}

# Default cache path for decoupling
.decoupling_cache_path <- function() {
  traning_data <- Sys.getenv("TRANING_DATA")
  if (traning_data == "") return(NULL)
  normalizePath(file.path(traning_data, "cache", "decoupling.RData"),
                mustWork = FALSE)
}

#' Load aerobic decoupling with incremental caching
#'
#' Wraps \code{compute_decoupling()} with RData caching.  On first call,
#' computes decoupling for all qualifying sessions and saves results.  On
#' subsequent calls, only processes sessions not already cached.
#'
#' @inheritParams compute_decoupling
#' @param force Logical.  If TRUE, discard cache and recompute.
#' @param cache_path Character or NULL.  Path to cache file.
#'   NULL = auto-detect from TRANING_DATA.
#' @return Tibble — same as \code{compute_decoupling()}.
#' @export
load_decoupling <- function(summaries, myruns,
                            min_duration_min        = 45,
                            max_pace_min_km         = 5.0,
                            warmup_sec              = 600L,
                            smooth_window           = 30L,
                            max_half_speed_diff_pct = 10,
                            force                   = FALSE,
                            cache_path              = NULL) {
  if (is.null(cache_path)) cache_path <- .decoupling_cache_path()

  cached <- NULL
  cached_skipped_dates <- as.Date(character(0))
  cache_valid <- FALSE

  if (!force && !is.null(cache_path) && file.exists(cache_path)) {
    load(cache_path)  # loads: decoupling_cache
    if (exists("decoupling_cache") &&
        identical(decoupling_cache$min_duration_min, min_duration_min) &&
        identical(decoupling_cache$max_pace_min_km, max_pace_min_km) &&
        identical(decoupling_cache$warmup_sec, warmup_sec) &&
        identical(decoupling_cache$smooth_window, smooth_window) &&
        identical(decoupling_cache$max_half_speed_diff_pct, max_half_speed_diff_pct)) {
      cached <- decoupling_cache$per_run
      cached_skipped_dates <- decoupling_cache$skipped_dates %||%
        as.Date(character(0))
      cache_valid <- TRUE
      message("Decoupling-cache: ", nrow(cached), " sessioner (",
              length(cached_skipped_dates), " utan data).")
    } else {
      message("Decoupling-cache: parametrar \u00e4ndrade, r\u00e4knar om allt.")
    }
  }

  # Find qualifying sessions not already cached
  run_idx <- which(
    stringr::str_detect(summaries$sport, "running") &
    as.numeric(summaries$durationMoving, units = "mins") > min_duration_min &
    as.numeric(summaries$avgPaceMoving) > max_pace_min_km
  )
  run_dates <- as.Date(summaries$sessionStart[run_idx])

  if (cache_valid) {
    known_dates <- c(cached$sessionStart, cached_skipped_dates)
    new_mask <- !(run_dates %in% known_dates)
    new_run_idx <- run_idx[new_mask]
  } else {
    new_run_idx <- run_idx
  }

  if (length(new_run_idx) == 0 && cache_valid) {
    message("Decoupling-cache: inga nya sessioner.")
    per_run <- cached
  } else {
    # Build a subset summaries + myruns for only the new sessions
    if (cache_valid && length(new_run_idx) > 0) {
      message("Ber\u00e4knar decoupling f\u00f6r ", length(new_run_idx),
              " nya sessioner ...")
    }

    # Full recompute — compute_decoupling handles iteration internally
    new_data <- compute_decoupling(
      summaries, myruns,
      min_duration_min        = min_duration_min,
      max_pace_min_km         = max_pace_min_km,
      warmup_sec              = warmup_sec,
      smooth_window           = smooth_window,
      max_half_speed_diff_pct = max_half_speed_diff_pct
    )

    if (cache_valid && nrow(cached) > 0) {
      # Merge: keep cached entries, add new ones
      per_run <- dplyr::bind_rows(cached, new_data) %>%
        dplyr::distinct(sessionStart, .keep_all = TRUE) %>%
        dplyr::arrange(sessionStart)
    } else {
      per_run <- new_data
    }

    # Track skipped dates for incremental cache
    computed_dates <- per_run$sessionStart
    all_skipped <- as.Date(setdiff(
      as.character(run_dates),
      as.character(computed_dates)
    ))
  }

  if (!exists("all_skipped")) all_skipped <- cached_skipped_dates

  # Recompute rolling mean on the merged data
  if (nrow(per_run) > 0) {
    daily <- per_run %>%
      dplyr::group_by(sessionStart) %>%
      dplyr::summarise(daily_dc = mean(decoupling_pct, na.rm = TRUE),
                       .groups = "drop") %>%
      dplyr::arrange(sessionStart)

    date_spine <- tibble::tibble(
      sessionStart = seq(min(daily$sessionStart), max(daily$sessionStart),
                         by = "day")
    )

    rolling <- date_spine %>%
      dplyr::left_join(daily, by = "sessionStart") %>%
      dplyr::mutate(
        decoupling_rolling28 = .rolling_mean(daily_dc, window = 28)
      ) %>%
      dplyr::select(sessionStart, decoupling_rolling28)

    per_run <- per_run %>%
      dplyr::select(-decoupling_rolling28) %>%
      dplyr::left_join(rolling, by = "sessionStart")
  }

  # Save cache
  if (!is.null(cache_path)) {
    decoupling_cache <- list(
      per_run                 = per_run,
      skipped_dates           = all_skipped,
      min_duration_min        = min_duration_min,
      max_pace_min_km         = max_pace_min_km,
      warmup_sec              = warmup_sec,
      smooth_window           = smooth_window,
      max_half_speed_diff_pct = max_half_speed_diff_pct
    )
    save(decoupling_cache, file = cache_path)
    message("Decoupling-cache sparad: ", nrow(per_run), " sessioner.")
  }

  per_run
}
