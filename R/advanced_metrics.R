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

  # Full date spine with rest days as 0
  date_spine <- tibble::tibble(
    date = seq(min(daily$date), max(daily$date), by = "day")
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

  date_spine <- tibble::tibble(
    date = seq(min(daily$date), max(daily$date), by = "day")
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

  runs %>%
    dplyr::left_join(rolling, by = "sessionStart") %>%
    dplyr::select(sessionStart, distance_km, recovery_hr, recovery_hr_rolling28)
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

  # Build full date spine — rest days = 0 TRIMP
  date_spine <- tibble::tibble(
    date = seq(min(daily_trimp$date), max(daily_trimp$date), by = "day")
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
