# Advanced training metrics: Efficiency Factor, ACWR, and Training Monotony/Strain

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
        chronic_uncoupled > 0, acute_load / chronic_uncoupled, NA_real_)
    ) %>%
    dplyr::select(
      date,
      daily_km,
      weekly_km,
      acute_load,
      chronic_load,
      acwr,
      acwr_uncoupled
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
