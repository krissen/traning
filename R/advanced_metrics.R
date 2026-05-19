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

#' Compute Efficiency Factor (EF) per session
#'
#' EF = average speed (m/min) / average heart rate (bpm).
#' A higher EF means more speed per heartbeat — a proxy for aerobic fitness.
#' Sessions of \code{min_distance} or less (default 5 km) are excluded
#' because short sessions produce noisy EF values that distort the trend.
#'
#' A 28-day rolling mean (ef_rolling28) is also returned to reveal the
#' underlying fitness trend, smoothing over day-to-day variation.
#'
#' EF generalises naturally to any sport that records speed and HR
#' (e.g. cycling, walking).
#'
#' @param summaries Data frame from \code{my_dbs_load()}, enriched by
#'   \code{add_my_columns()} and \code{fix_zero_moving()}.
#' @param sport Sport bucket (default \code{"running"}).
#' @param min_distance Numeric. Minimum distance in metres to include
#'   (default 5000).
#' @return Tibble with one row per qualifying session, ordered by date,
#'   with columns: \code{sessionStart}, \code{distance_km},
#'   \code{avgSpeedMoving}, \code{avgHeartRateMoving}, \code{ef},
#'   \code{ef_rolling28}.
#' @export
compute_efficiency_factor <- function(summaries, sport = "running",
                                      min_distance = 5000) {
  empty <- tibble::tibble(
    sessionStart       = as.Date(character(0)),
    distance_km        = numeric(0),
    avgSpeedMoving     = numeric(0),
    avgHeartRateMoving = numeric(0),
    ef                 = numeric(0),
    ef_rolling28       = numeric(0)
  )

  runs <- .filter_sport(summaries, sport) %>%
    dplyr::filter(distance > min_distance) %>%
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

  if (nrow(runs) == 0) return(empty)

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

#' Compute Heart Rate Efficiency (HRE) per session — Votyakov metric
#'
#' HRE = average heart rate (bpm) * average pace (min/km) = beats per km.
#' A lower HRE means fewer heartbeats needed per km — better aerobic fitness.
#' This is the arithmetic inverse of Efficiency Factor.
#'
#' Votyakov et al. (2025) validated HRE over 14 years with thresholds:
#' <700 bpkm = well-fitted, 700-750 = fitted, >800 = poorly-fitted.
#' These thresholds are running-specific; the formula still produces a
#' meaningful "beats per km" value for cycling/walking but the absolute
#' numbers differ.
#'
#' Sessions of \code{min_distance} or less (default 5 km) are excluded.
#' A 28-day rolling mean (hre_rolling28) reveals the underlying trend.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param sport Sport bucket (default \code{"running"}).
#' @param min_distance Numeric. Minimum distance in metres (default 5000).
#' @return Tibble with one row per qualifying session, ordered by date,
#'   with columns: \code{sessionStart}, \code{distance_km},
#'   \code{avgHeartRateMoving}, \code{avgPaceMoving}, \code{hre},
#'   \code{hre_rolling28}.
#' @export
compute_hre <- function(summaries, sport = "running",
                        min_distance = 5000) {
  empty <- tibble::tibble(
    sessionStart       = as.Date(character(0)),
    distance_km        = numeric(0),
    avgHeartRateMoving = numeric(0),
    avgPaceMoving      = numeric(0),
    hre                = numeric(0),
    hre_rolling28      = numeric(0)
  )

  runs <- .filter_sport(summaries, sport) %>%
    dplyr::filter(distance > min_distance) %>%
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

  if (nrow(runs) == 0) return(empty)

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
#'   \item Acute load: rolling 7-day total of daily load
#'   \item Chronic load: rolling 28-day mean of daily load × 7
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
#' Two load modes are supported:
#' \describe{
#'   \item{\code{mode = "km"}}{Daily km from \code{summaries$distance}.
#'     The classic running-injury formulation (Hulin 2016, Gabbett 2016).
#'     Only meaningful within one sport — mixing cycling and running km
#'     blurs spike detection.}
#'   \item{\code{mode = "trimp"}}{Daily Banister TRIMP from
#'     \code{compute_trimp()}. HR-based load composes across sports, so
#'     this is the right mode for whole-system load (\code{sport="all"}).
#'     Background-activity TRIMP from \code{health_daily} folds in when
#'     supplied.}
#' }
#'
#' When \code{mode = NULL} (default), the mode auto-resolves: TRIMP for
#' \code{sport = "all"} (because km doesn't compose across sports), and
#' km for any specific sport bucket.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @param sport Sport bucket (default \code{"running"}).
#' @param mode One of \code{"km"}, \code{"trimp"}, or \code{NULL} (auto;
#'   see Description). Explicit choice overrides the auto-resolution.
#' @param hr_max,hr_rest Optional HR anchors threaded into
#'   \code{compute_trimp()} when \code{mode = "trimp"}.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}; folds background-activity TRIMP into the
#'   load series in TRIMP mode for whole-system buckets.
#' @return Tibble with one row per calendar day from first to last
#'   session, with columns: \code{date}, \code{daily_load},
#'   \code{weekly_load}, \code{daily_km}, \code{weekly_km},
#'   \code{acute_load}, \code{chronic_load}, \code{acwr},
#'   \code{acwr_uncoupled}, \code{weekly_pct_change}, plus a
#'   \code{"mode"} attribute. In TRIMP mode the \code{daily_km} /
#'   \code{weekly_km} columns are \code{NA} (the load is in TRIMP, not
#'   km); use \code{daily_load} / \code{weekly_load} for mode-agnostic
#'   reads.
#' @export
compute_acwr <- function(summaries, sport = "running", mode = NULL,
                          hr_max = NULL, hr_rest = NULL,
                          health_daily = NULL) {
  if (is.null(mode)) {
    # Whole-system requests (NULL / "all" / "any" — same sentinels
    # .filter_sport() treats as "no filter") get TRIMP mode because
    # km doesn't compose across sports. Anything else stays in km
    # mode (the classic Hulin/Gabbett running-injury formulation).
    is_whole_system <- is.null(sport) ||
                       (is.character(sport) && length(sport) == 1L &&
                        sport %in% c("all", "any"))
    mode <- if (is_whole_system) "trimp" else "km"
  }
  mode <- match.arg(mode, c("km", "trimp"))

  empty <- tibble::tibble(
    date              = as.Date(character(0)),
    daily_load        = numeric(0),
    weekly_load       = numeric(0),
    daily_km          = numeric(0),
    weekly_km         = numeric(0),
    acute_load        = numeric(0),
    chronic_load      = numeric(0),
    acwr              = numeric(0),
    acwr_uncoupled    = numeric(0),
    weekly_pct_change = numeric(0)
  )
  attr(empty, "mode") <- mode

  if (mode == "km") {
    # Aggregate to daily km (all sessions — not filtered to > 5 km)
    daily <- .filter_sport(summaries, sport) %>%
      dplyr::mutate(date = as.Date(sessionStart)) %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(daily_load = sum(distance, na.rm = TRUE) / 1000,
                       .groups = "drop")
  } else {
    trimp_tbl <- compute_trimp(summaries, hr_max = hr_max,
                                hr_rest = hr_rest, sport = sport,
                                health_daily = health_daily)
    if (nrow(trimp_tbl) == 0) return(empty)
    daily <- trimp_tbl %>%
      dplyr::transmute(date = .data$date,
                       daily_load = .data$daily_trimp)
  }

  if (nrow(daily) == 0) return(empty)

  # Full date spine with rest days as 0; extend to today
  spine_end <- max(max(daily$date), Sys.Date())
  date_spine <- tibble::tibble(
    date = seq(min(daily$date), spine_end, by = "day")
  )

  daily_full <- date_spine %>%
    dplyr::left_join(daily, by = "date") %>%
    dplyr::mutate(daily_load = dplyr::if_else(is.na(.data$daily_load),
                                               0, .data$daily_load))

  # Acute load: 7-day rolling sum
  # Chronic load (coupled): 28-day rolling mean of daily load * 7
  #   (mean gives the "typical day"; * 7 scales to weekly for
  #    comparability with the 7-day acute sum)
  # Chronic load (uncoupled): rolling mean of the window days 8–35
  x <- daily_full$daily_load
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

  result <- daily_full %>%
    dplyr::mutate(
      weekly_load       = acute,
      acute_load        = acute,
      chronic_load      = chronic_coupled,
      acwr              = dplyr::if_else(
        chronic_load > 0, acute_load / chronic_load, NA_real_),
      acwr_uncoupled    = dplyr::if_else(
        chronic_uncoupled > 0, acute_load / chronic_uncoupled, NA_real_),
      # Week-over-week percentage change (Nielsen 2014: >30% = injury risk)
      weekly_pct_change = dplyr::if_else(
        dplyr::lag(weekly_load, 7) > 0,
        (weekly_load / dplyr::lag(weekly_load, 7) - 1) * 100,
        NA_real_
      )
    )

  if (mode == "km") {
    result$daily_km  <- result$daily_load
    result$weekly_km <- result$weekly_load
  } else {
    # In TRIMP mode the legacy km columns aren't meaningful; emit NA so
    # callers that grab them get an obvious "not applicable" instead of
    # a TRIMP value masquerading as km.
    result$daily_km  <- NA_real_
    result$weekly_km <- NA_real_
  }

  result <- result %>%
    dplyr::select(
      date,
      daily_load,
      weekly_load,
      daily_km,
      weekly_km,
      acute_load,
      chronic_load,
      acwr,
      acwr_uncoupled,
      weekly_pct_change
    )
  attr(result, "mode") <- mode
  result
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
#' @param sport Sport bucket (default \code{"all"} — Foster's monotony
#'   is a system-wide stress metric; mixing all sports gives the truest
#'   measure of training uniformity). Pass \code{"running"} (or another
#'   bucket) for sport-specific monotony.
#' @return Tibble with one row per calendar day from first to last session,
#'   with columns: \code{date}, \code{daily_km}, \code{weekly_km},
#'   \code{monotony}, \code{strain}.
#' @export
compute_monotony_strain <- function(summaries, sport = "all") {
  empty <- tibble::tibble(
    date      = as.Date(character(0)),
    daily_km  = numeric(0),
    weekly_km = numeric(0),
    monotony  = numeric(0),
    strain    = numeric(0)
  )

  # Aggregate to daily km — same approach as compute_acwr()
  daily <- .filter_sport(summaries, sport) %>%
    dplyr::mutate(date = as.Date(sessionStart)) %>%
    dplyr::group_by(date) %>%
    dplyr::summarise(daily_km = sum(distance, na.rm = TRUE) / 1000,
                     .groups = "drop")

  if (nrow(daily) == 0) return(empty)

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
#' @param sport Sport bucket (default \code{"all"} — recovery HR is a
#'   sport-agnostic cardiovascular signal). In practice Garmin only
#'   emits recovery HR for running today, so the all-bucket result is
#'   typically identical to a running-only call; the default change
#'   matters for HAE/cycling watches that begin reporting recovery HR
#'   for other sports.
#' @return Tibble with columns: sessionStart, distance_km,
#'   recovery_hr, recovery_hr_rolling28
#' @export
compute_recovery_hr <- function(summaries, sport = "all") {
  if (!"garmin_recoveryHeartRate" %in% names(summaries)) {
    stop("summaries saknar garmin_recoveryHeartRate. Kör augment_summaries() först.")
  }

  runs <- .filter_sport(summaries, sport) %>%
    dplyr::filter(
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

#' Compute daily TRIMP (Banister model)
#'
#' Calculates per-session training impulse using the Morton (1990)
#' exponential formula and aggregates to daily totals (sum across all
#' qualifying sessions in the same date):
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
#' @param sport Sport bucket (default \code{"all"}). TRIMP is purely
#'   HR-based and works for any sport with HR data, so the default
#'   sums load across every session with an HR reading. Pass
#'   \code{"running"} (or another bucket) to restrict.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}. When supplied and \code{sport} is a
#'   whole-system bucket (\code{"all"} or \code{"walking"}), background
#'   activity TRIMP from daily steps/walking distance is added to the
#'   workout-derived TRIMP via \code{compute_background_trimp()}.
#'   Ignored for sport-specific buckets (running, cycling, etc.) since
#'   background walking is not part of those sports' loads.
#' @return Tibble with: date, daily_trimp, trimp_type ("btrimp").
#'   When background activity is folded in, the returned rows span the
#'   union of workout dates and dates with non-zero background activity.
#' @export
compute_trimp <- function(summaries, hr_max = NULL, hr_rest = NULL,
                          sport = "all", health_daily = NULL) {
  # HR_max anchor mirrors the requested sport bucket so a cycling-only
  # call uses a cycling-based max. The multi-sport default keeps the
  # same "all" scope so the readiness PMC, the weekly recap and the
  # sport-mix plot (.sport_mix_data() in plot_multisport.R) share one
  # denominator — otherwise the same data would render at different
  # TRIMP scales across views. "all" also lets cycling-only datasets
  # produce a data-driven max instead of falling through to env/age.
  if (is.null(hr_max)) hr_max <- get_hr_max(summaries, sport = sport)

  # Whole-system sport (NULL / "all" / "any" — the .sport_match_mask()
  # no-filter sentinels) plus the "walking" bucket fold in background
  # walking distance. Sport-specific buckets (running, cycling, …)
  # only see their own sport, so daily background steps shouldn't
  # inflate their load.
  add_background <- !is.null(health_daily) && (
    is.null(sport) ||
    (is.character(sport) && length(sport) == 1L &&
     sport %in% c("all", "any", "walking"))
  )

  runs <- .filter_sport(summaries, sport) %>%
    dplyr::filter(
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

  empty_daily <- tibble::tibble(date = as.Date(character(0)),
                                 daily_trimp = numeric(0),
                                 trimp_type = character(0))

  if (nrow(runs) == 0) {
    # No qualifying HR workouts. The high-step / no-workout case is
    # exactly the user-facing scenario this branch protects: a day with
    # 30k steps and no logged run still has to land in CTL. Fall through
    # to the background-fold-in path so the daily total is non-zero.
    if (!add_background) return(empty_daily)
    bg <- compute_background_trimp(health_daily, hr_max = hr_max,
                                    hr_rest = hr_rest,
                                    summaries = summaries)
    if (nrow(bg) == 0) return(empty_daily)
    return(
      bg %>%
        dplyr::transmute(
          date = .data$date,
          daily_trimp = .data$background_trimp,
          trimp_type = "btrimp"
        ) %>%
        dplyr::arrange(date)
    )
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

  # Fold in background-activity TRIMP for whole-system buckets. Sport-
  # specific buckets (running, cycling, …) only see their own sport,
  # so daily steps and walking distance shouldn't inflate their load.
  # `add_background` was already resolved above (we needed it for the
  # nrow(runs) == 0 path).
  if (add_background) {
    bg <- compute_background_trimp(health_daily, hr_max = hr_max,
                                    hr_rest = hr_rest,
                                    summaries = summaries)
    if (nrow(bg) > 0) {
      daily_trimp <- dplyr::full_join(daily_trimp, bg, by = "date") %>%
        dplyr::mutate(
          workout_trimp    = dplyr::coalesce(daily_trimp, 0),
          background_trimp = dplyr::coalesce(background_trimp, 0),
          daily_trimp      = workout_trimp + background_trimp,
          trimp_type       = "btrimp"
        ) %>%
        dplyr::select(date, daily_trimp, trimp_type) %>%
        dplyr::arrange(date)
    }
  }

  daily_trimp
}

#' Compute background-activity TRIMP from daily steps and energy
#'
#' Converts non-workout daily activity (background walking captured by
#' the watch when no workout was started) into a synthetic Banister
#' TRIMP so that whole-system load metrics (\code{compute_pmc()},
#' readiness) include high-step days. Without this a 30k-step day with
#' no logged workout would contribute zero to CTL/ATL/TSB even though
#' it represents real physical strain.
#'
#' Model: take daily \code{walking_running_distance} (km) from HAE,
#' subtract distance covered by running and walking workouts the same
#' day (so workout km aren't double-counted), convert the remainder to
#' an equivalent walking duration at 12 min/km, and apply the same
#' Banister exponential as \code{compute_trimp()} at a fixed HR ratio
#' of 0.30 (typical vardagsgång: hr_rest + 30 \% of reserve). When the
#' \code{walking_running_distance} metric is missing for a day, falls
#' back to \code{active_energy / 250} kJ as a coarse km equivalent.
#'
#' The HR-ratio is intentionally fixed: per-minute HR for background
#' activity isn't available, and using a conservative typical value
#' avoids over-estimating load on commute-heavy days.
#'
#' @param health_daily Long-format tibble from \code{load_health_data()}
#'   (columns date, metric, value, source).
#' @param hr_max,hr_rest Currently unused (HR ratio is fixed); kept in
#'   the signature so callers can thread the same anchors used by
#'   \code{compute_trimp()} without conditional plumbing.
#' @param summaries Optional Garmin/HAE summaries data frame; when
#'   supplied, distance from running and walking workouts on the same
#'   date is subtracted from the daily walking_running_distance to
#'   avoid double-counting workout km that the watch also recorded as
#'   background distance.
#' @param min_per_km Walking pace assumed for the km→minutes
#'   conversion. Default 12 (5 km/h).
#' @param hr_ratio Banister delta-HR (0..1) for background activity.
#'   Default 0.30.
#' @param kj_per_km_fallback Active-energy fallback factor (kJ/km
#'   walking). Default 250.
#' @return Tibble with columns \code{date} and \code{background_trimp}.
#' @export
compute_background_trimp <- function(health_daily,
                                      hr_max = NULL, hr_rest = NULL,
                                      summaries = NULL,
                                      min_per_km = 12,
                                      hr_ratio = 0.30,
                                      kj_per_km_fallback = 250) {
  empty <- tibble::tibble(
    date             = as.Date(character(0)),
    background_trimp = numeric(0)
  )

  if (is.null(health_daily) || nrow(health_daily) == 0) return(empty)
  required_cols <- c("date", "metric", "value")
  if (!all(required_cols %in% names(health_daily))) return(empty)

  bg_metrics <- c("walking_running_distance", "active_energy")
  bg <- health_daily %>%
    dplyr::filter(.data$metric %in% bg_metrics, !is.na(.data$value)) %>%
    dplyr::mutate(date = as.Date(.data$date)) %>%
    dplyr::group_by(date, .data$metric) %>%
    dplyr::summarise(value = sum(.data$value, na.rm = TRUE),
                     .groups = "drop") %>%
    tidyr::pivot_wider(names_from = "metric", values_from = "value")

  if (nrow(bg) == 0) return(empty)

  if (!"walking_running_distance" %in% names(bg)) {
    bg$walking_running_distance <- NA_real_
  }
  if (!"active_energy" %in% names(bg)) {
    bg$active_energy <- NA_real_
  }

  # Workout distance to subtract: running and walking sessions on the
  # same date (watch logs background steps in parallel with workouts).
  workout_km <- tibble::tibble(date = as.Date(character(0)),
                                workout_km = numeric(0))
  has_summaries <- !is.null(summaries) && is.data.frame(summaries) &&
                   nrow(summaries) > 0 &&
                   all(c("sessionStart", "sport", "distance") %in%
                       names(summaries))
  if (has_summaries) {
    workout_km <- .filter_sport(summaries, c("running", "walking")) %>%
      dplyr::mutate(
        date       = as.Date(.data$sessionStart),
        workout_km = as.numeric(.data$distance) / 1000
      ) %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(workout_km = sum(.data$workout_km, na.rm = TRUE),
                       .groups = "drop")
  }

  bg <- bg %>%
    dplyr::left_join(workout_km, by = "date") %>%
    dplyr::mutate(
      workout_km = dplyr::coalesce(.data$workout_km, 0),
      # Prefer walking_running_distance; fall back to active_energy / 250
      # when missing (older HAE exports, days with broken WRD samples).
      wrd_km     = dplyr::if_else(
        !is.na(.data$walking_running_distance),
        .data$walking_running_distance,
        .data$active_energy / kj_per_km_fallback
      ),
      bg_km      = pmax(0, .data$wrd_km - .data$workout_km),
      bg_minutes = .data$bg_km * min_per_km,
      background_trimp = .data$bg_minutes * hr_ratio * 0.64 *
                         exp(1.92 * hr_ratio)
    ) %>%
    dplyr::filter(is.finite(.data$background_trimp),
                  .data$background_trimp > 0) %>%
    dplyr::select(date, background_trimp) %>%
    dplyr::arrange(date)

  bg
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
#' @param sport Sport bucket (default \code{"all"} — load aggregates
#'   across every session with HR data, matching the way readiness uses
#'   PMC as a whole-system load signal). Pass \code{"running"} (or
#'   another bucket) for sport-specific load.
#' @param health_daily Optional long-format tibble from
#'   \code{load_health_data()}. Threaded into \code{compute_trimp()} so
#'   background-activity TRIMP from daily steps/distance is folded into
#'   CTL/ATL/TSB for whole-system buckets. See \code{compute_trimp()}
#'   and \code{compute_background_trimp()}.
#' @return Tibble with daily values: date, daily_trimp, atl, ctl, tsb.
#' @export
compute_pmc <- function(summaries, hr_max = NULL, hr_rest = NULL,
                        sport = "all", health_daily = NULL) {
  daily_trimp <- compute_trimp(summaries, hr_max = hr_max,
                               hr_rest = hr_rest, sport = sport,
                               health_daily = health_daily)

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

# Internal helper: Swedish subtitle describing the scope of a PMC/TRIMP
# rendering, given the sport bucket and whether background activity was
# folded in. Used by plot/report to make it obvious whether the chart
# reflects all-sport load (incl. vardagsrörelse) or a single sport.
.pmc_scope_label_sv <- c(
  all      = "alla sporter",
  running  = "löpning",
  cycling  = "cykling",
  walking  = "gång",
  swimming = "simning",
  strength = "styrka"
)
.pmc_scope_subtitle <- function(sport = "all", health_daily = NULL) {
  bg_on <- !is.null(health_daily) &&
           is.character(sport) && length(sport) == 1L &&
           sport %in% c("all", "walking")
  scope <- if (is.null(sport)) {
    "alla sporter"
  } else if (is.character(sport) && length(sport) == 1L) {
    if (sport %in% names(.pmc_scope_label_sv)) {
      unname(.pmc_scope_label_sv[[sport]])
    } else {
      sport
    }
  } else {
    paste(sport, collapse = " + ")
  }
  bg_suffix <- if (bg_on) " + vardagsrörelse" else ""
  paste0("Träningsbelastning (", scope, bg_suffix, ")")
}

#' Compute Aerobic Decoupling per session
#'
#' Aerobic decoupling measures the drift in pace:HR efficiency between the
#' first and second half of a session, excluding a warmup period. A positive
#' value means the second half was less efficient (cardiac drift).
#' Well-developed aerobic fitness produces decoupling < 3\%; values > 5\%
#' suggest aerobic limitation.
#'
#' Defaults are tuned for running (steady-state easy pace), but the algorithm
#' generalises to any sport with steady speed and HR samples (cycling,
#' walking) — pass \code{sport} accordingly and adjust \code{max_pace_min_km}
#' if the sport's typical pace differs.
#'
#' @section Session selection:
#' Only steady-state easy sessions are included:
#' \itemize{
#'   \item Duration > 45 min (short sessions produce noisy values)
#'   \item Average pace > sport-aware threshold (defaults: 5:00/km for
#'     running, 1:30/km for cycling, 6:00/km for walking, 15:00/km for
#'     swimming) so intervals and tempo sessions are excluded — see
#'     \code{max_pace_min_km} for full details. The pace ceiling is
#'     disabled for multi-sport selections (\code{NULL}, \code{"all"},
#'     curated buckets) since one min/km cutoff doesn't fit all sports.
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
#' @param max_pace_min_km Numeric.  Pace gate in min/km — the filter
#'   keeps rows whose \code{avgPaceMoving} is *greater than* this value,
#'   so a higher number is more restrictive (it requires slower / easier
#'   sessions). Default \code{NULL} picks a sport-aware threshold: 5.0
#'   (running easy-pace), 1.5 (cycling, excludes intervals under
#'   1:30/km), 6.0 (walking, excludes runs misclassified as walks), 15.0
#'   (swimming). For multi-sport selections (\code{NULL}, \code{"all"},
#'   curated buckets like \code{"endurance"}) the pace ceiling is
#'   disabled (\code{0}) — a single min/km cutoff cannot meaningfully
#'   compare running, cycling, walking, etc., so only the duration and
#'   steady-state filters apply. Pass an explicit number to override.
#' @param warmup_sec Integer.  Seconds to exclude from the start (default 600).
#' @param smooth_window Integer.  Rolling mean window in seconds for speed
#'   smoothing (default 30).  Converted to number of observations based on
#'   actual sampling interval.
#' @param max_half_speed_diff_pct Numeric.  Maximum allowed difference in mean
#'   speed between first and second half, as a percentage of the faster half
#'   (default 10).  Sessions exceeding this are not steady-state and are
#'   excluded.
#' @param sport Sport bucket (default \code{"running"}). Decoupling is a
#'   speed:HR drift; the same algorithm works for any sport with steady
#'   speed and HR samples (e.g. cycling, walking).
#' @return Tibble with one row per qualifying session, ordered by date:
#'   \code{sessionStart}, \code{distance_km}, \code{duration_min},
#'   \code{avg_pace}, \code{avg_hr}, \code{ratio_first}, \code{ratio_second},
#'   \code{decoupling_pct}, \code{decoupling_rolling28}, \code{temperature}.
#' @export
compute_decoupling <- function(summaries, myruns,
                               min_duration_min        = 45,
                               max_pace_min_km         = NULL,
                               warmup_sec              = 600L,
                               smooth_window           = 30L,
                               max_half_speed_diff_pct = 10,
                               cap_pct                 = 25,
                               sport                   = "running") {
  if (is.null(max_pace_min_km)) {
    max_pace_min_km <- .resolve_max_pace_min_km(sport)
  }
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
    temperature        = numeric(0),
    capped             = logical(0)
  )

  # Filter qualifying sessions at summary level. We work with row indices
  # (not dplyr::filter) because myruns is positionally aligned to
  # summaries — losing positions would break the [[i]] lookup.
  run_idx <- which(
    .sport_match_mask(summaries, sport) &
    as.numeric(summaries$durationMoving, units = "mins") > min_duration_min &
    as.numeric(summaries$avgPaceMoving) > max_pace_min_km
  )

  if (length(run_idx) == 0) return(empty)

  has_temp <- "garmin_averageTemperature" %in% names(summaries)

  n_runs  <- length(run_idx)
  n_skip  <- 0L
  n_capped <- 0L
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

    # Physiological sanity cap. Real aerobic decoupling sits in roughly
    # ±15 %; values beyond ±cap_pct usually trace back to per-second HR
    # sensor dropouts or stuck values that corrupt the half-period
    # averages (the canonical example is the 2011 sessions with NA
    # avg_hr in summaries — the trackeR object holds bogus per-second
    # readings that survive the validity gate at line 747). Genuine
    # extremes (heat, severe under-fueling, very long efforts) can also
    # cross the threshold, so the row is kept with `capped = TRUE` and
    # the rolling mean / plot can decide how to surface it (the default
    # plot renders capped sessions as red triangles at the cap line so
    # the user sees that something happened, but the y-axis isn't
    # blown up by a single -75 % artefact).
    is_capped <- !is.finite(decoupling_pct) || abs(decoupling_pct) > cap_pct
    if (is_capped) n_capped <- n_capped + 1L

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
      },
      capped         = is_capped
    )
  }

  if (n_skip > 0) {
    warning(n_skip, " sessioner hoppades \u00f6ver (NULL, saknar speed/HR, ",
            "eller f\u00f6r kort efter uppv\u00e4rmning).", call. = FALSE)
  }
  if (n_capped > 0) {
    warning(n_capped, " sessioner flaggade som outliers (|decoupling| > ",
            cap_pct, " %) \u2014 m\u00e4rks visuellt men exkluderas fr\u00e5n ",
            "rullande medel. H\u00f6j cap_pct f\u00f6r att inkludera \u00e4kta extremer ",
            "som hetta eller under-fueling.", call. = FALSE)
  }

  per_run <- dplyr::bind_rows(results)

  if (nrow(per_run) == 0) return(empty)

  per_run <- dplyr::arrange(per_run, sessionStart)

  # 28-day rolling mean on date spine \u2014 exclude capped sessions so a
  # single -75 % artefact doesn't pull the trend line down for a month.
  daily <- per_run %>%
    dplyr::filter(!.data$capped) %>%
    dplyr::group_by(sessionStart) %>%
    dplyr::summarise(daily_dc = mean(decoupling_pct, na.rm = TRUE),
                     .groups = "drop") %>%
    dplyr::arrange(sessionStart)

  if (nrow(daily) == 0) {
    # Every session was capped (only happens in synthetic test fixtures
    # with extreme decoupling) \u2014 no rolling reference possible.
    return(per_run %>%
      dplyr::mutate(decoupling_rolling28 = NA_real_) %>%
      dplyr::select(
        sessionStart, distance_km, duration_min, avg_pace, avg_hr,
        ratio_first, ratio_second, decoupling_pct, decoupling_rolling28,
        temperature, capped
      ))
  }

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
      temperature, capped
    )
}

# Default cache path for decoupling
.decoupling_cache_path <- function() {
  traning_data <- Sys.getenv("TRANING_DATA")
  if (traning_data == "") return(NULL)
  normalizePath(file.path(traning_data, "cache", "decoupling.RData"),
                mustWork = FALSE)
}

#' Resolve the sport-aware easy-pace gate for decoupling
#'
#' Internal helper shared by \code{compute_decoupling()} and
#' \code{load_decoupling()} so both functions agree on which
#' \code{max_pace_min_km} to use when the caller passes \code{NULL}.
#'
#' The decoupling pace filter keeps rows where \code{avgPaceMoving >
#' max_pace_min_km}, so this is an *easy-pace* gate: a higher number
#' is more restrictive. 5.0 min/km is running easy-pace; cycling and
#' walking move much faster in min/km, so a single threshold cannot
#' fit all sports. The resolver:
#' \itemize{
#'   \item Resolves \code{sport} via \code{.resolve_sport_bucket()} so
#'     Swedish aliases ("cykling") and curated buckets ("endurance")
#'     are handled.
#'   \item Returns the sport-specific threshold for a single known
#'     sport: 5.0 (running), 1.5 (cycling), 6.0 (walking), 15.0
#'     (swimming).
#'   \item Returns 0 (gate disabled — \code{pace > 0} keeps every
#'     recorded session) for \code{NULL} / \code{"all"} / multi-sport
#'     buckets, and for unknown single sports. We use 0 rather than
#'     \code{Inf} because \code{pace > Inf} is \code{FALSE} for any
#'     finite pace.
#' }
#'
#' @param sport Character scalar/vector or NULL.
#' @return Numeric — pace threshold in min/km.
#' @keywords internal
.resolve_max_pace_min_km <- function(sport) {
  pace_for <- function(s) {
    switch(s,
      running  = 5.0,
      cycling  = 1.5,
      walking  = 6.0,
      swimming = 15.0,
      NA_real_)
  }
  resolved <- .resolve_sport_bucket(sport)
  if (is.null(resolved) || length(resolved) == 0 || length(resolved) > 1) {
    return(0)
  }
  d <- pace_for(resolved)
  if (is.na(d)) 0 else d
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
                            max_pace_min_km         = NULL,
                            warmup_sec              = 600L,
                            smooth_window           = 30L,
                            max_half_speed_diff_pct = 10,
                            cap_pct                 = 25,
                            force                   = FALSE,
                            cache_path              = NULL,
                            sport                   = "running",
                            read_only               = FALSE) {
  # Mirror compute_decoupling's sport-aware default so non-running
  # callers (CLI/Vayu/Shiny with sport="cycling"/"endurance"/"all")
  # don't silently filter to an empty cache by inheriting the old
  # running-tuned 5.0 default. The pre-cache filter below uses the
  # same value for the qualifying-session lookup, so they have to
  # agree.
  if (is.null(max_pace_min_km)) {
    max_pace_min_km <- .resolve_max_pace_min_km(sport)
  }
  if (is.null(cache_path)) cache_path <- .decoupling_cache_path()

  cached <- NULL
  cached_skipped_dates <- as.Date(character(0))
  cache_valid <- FALSE

  if (!force && !is.null(cache_path) && file.exists(cache_path)) {
    load(cache_path)  # loads: decoupling_cache
    # Cache must also match `sport` — without that, a cache produced for
    # one sport could be reused (or merged with) a request for another
    # and return cross-sport results. Older caches (pre-sport-key) are
    # treated as invalid and recomputed.
    if (exists("decoupling_cache") &&
        identical(decoupling_cache$min_duration_min, min_duration_min) &&
        identical(decoupling_cache$max_pace_min_km, max_pace_min_km) &&
        identical(decoupling_cache$warmup_sec, warmup_sec) &&
        identical(decoupling_cache$smooth_window, smooth_window) &&
        identical(decoupling_cache$max_half_speed_diff_pct,
                  max_half_speed_diff_pct) &&
        identical(decoupling_cache$cap_pct, cap_pct) &&
        identical(decoupling_cache$sport %||% NULL, sport)) {
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
    .sport_match_mask(summaries, sport) &
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
      max_half_speed_diff_pct = max_half_speed_diff_pct,
      cap_pct                 = cap_pct,
      sport                   = sport
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

  # Recompute rolling mean on the merged data — exclude capped sessions
  # so a single -75 % artefact doesn't pull the trend line down. Older
  # caches lacking the column behave as if no rows were capped.
  if (nrow(per_run) > 0) {
    if (!"capped" %in% names(per_run)) per_run$capped <- FALSE
    daily <- per_run %>%
      dplyr::filter(!.data$capped) %>%
      dplyr::group_by(sessionStart) %>%
      dplyr::summarise(daily_dc = mean(decoupling_pct, na.rm = TRUE),
                       .groups = "drop") %>%
      dplyr::arrange(sessionStart)

    if (nrow(daily) > 0) {
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
    } else {
      per_run$decoupling_rolling28 <- NA_real_
    }
  }

  # Save cache. Hoppas över när `read_only = TRUE` (typiskt Shiny
  # per-session-load) så att läsare inte skriver disken vid varje
  # session och inte racar mot parallella konsumenter. Validering,
  # incremental compute och merge sker fortfarande in-memory.
  if (!is.null(cache_path) && !read_only) {
    decoupling_cache <- list(
      per_run                 = per_run,
      skipped_dates           = all_skipped,
      min_duration_min        = min_duration_min,
      max_pace_min_km         = max_pace_min_km,
      warmup_sec              = warmup_sec,
      smooth_window           = smooth_window,
      max_half_speed_diff_pct = max_half_speed_diff_pct,
      cap_pct                 = cap_pct,
      sport                   = sport
    )
    save_atomic(decoupling_cache, file = cache_path)
    message("Decoupling-cache sparad: ", nrow(per_run), " sessioner.")
  }

  per_run
}


# --- Phase 5d: Taper plan & race readiness -----------------------------------
#
# See docs/dev/race-taper-design.md for the algorithm rationale.

#' Median weekly running km over the last `lookback_weeks` complete ISO weeks
#'
#' Used by \code{compute_taper_plan()} as the baseline for the volume
#' curve. Median (not mean) makes a single spike week's km not pull the
#' whole schedule above what the athlete is actually maintaining.
#'
#' A complete ISO window is built first and any week without a run
#' contributes 0 to the median — otherwise a 3-on / 1-off pattern
#' would silently look like steady training and inflate the taper
#' targets.
#'
#' @keywords internal
.recent_baseline_km <- function(summaries, lookback_weeks = 4L) {
  if (is.null(summaries) || nrow(summaries) == 0L) return(0)
  runs <- .filter_sport(summaries, "running")

  lookback_weeks <- as.integer(lookback_weeks)
  iso_dow <- function(d) as.integer(format(d, "%u"))
  iso_week_key <- function(d) paste0(format(d, "%G"), "-W", format(d, "%V"))

  today <- Sys.Date()
  this_monday <- today - (iso_dow(today) - 1L)
  start <- this_monday - lookback_weeks * 7L

  # Spine: one entry per ISO week in the window. A "no-run" week
  # contributes 0 to the median through the spine, not by being
  # dropped from the grouping.
  week_starts <- start + 7L * (seq_len(lookback_weeks) - 1L)
  spine_keys  <- iso_week_key(week_starts)

  km_per_week <- setNames(rep(0, lookback_weeks), spine_keys)
  if (nrow(runs) > 0L) {
    d <- as.Date(runs$sessionStart)
    recent <- runs[!is.na(d) & d >= start & d < this_monday, , drop = FALSE]
    if (nrow(recent) > 0L) {
      keys <- iso_week_key(as.Date(recent$sessionStart))
      km   <- as.numeric(recent$distance) / 1000
      observed <- tapply(km, keys, function(x) sum(x, na.rm = TRUE))
      hit <- intersect(names(observed), names(km_per_week))
      km_per_week[hit] <- observed[hit]
    }
  }
  median(km_per_week)
}


#' Compute a taper plan from today through race day
#'
#' Produces one row per ISO week from this Monday through the week
#' containing \code{race_date}. The volume curve linearly interpolates
#' between a 0.45 race-week floor and 1.0 (full baseline) over the
#' \code{taper_weeks + 1} weeks closest to the race; weeks earlier
#' than that remain at baseline. See
#' \code{docs/dev/race-taper-design.md} for trade-offs.
#'
#' @param summaries Augmented summaries from \code{my_dbs_load()}.
#' @param race_date Date of the race. Must be on or after today.
#' @param distance_km Optional race distance, echoed back in the
#'   plan's attributes; does not change the curve.
#' @param taper_weeks Number of reduced-volume weeks before the race
#'   (race week itself excluded). Integer 1–4, default 2.
#' @return Tibble with columns \code{week_start, week_end,
#'   weeks_until_race, phase, baseline_km, target_km,
#'   relative_to_baseline}. The \code{distance_km} input is preserved
#'   as an attribute on the tibble.
#' @export
compute_taper_plan <- function(summaries, race_date,
                                distance_km = NA_real_,
                                taper_weeks = 2L) {
  race_date <- as.Date(race_date)
  if (is.na(race_date) || race_date < Sys.Date()) {
    stop("race_date must be today or in the future")
  }
  taper_weeks <- as.integer(taper_weeks)
  if (is.na(taper_weeks) || taper_weeks < 1L || taper_weeks > 4L) {
    stop("taper_weeks must be an integer between 1 and 4")
  }

  baseline_km <- .recent_baseline_km(summaries, lookback_weeks = 4L)
  if (!is.finite(baseline_km) || baseline_km <= 0) {
    # No running in the lookback window. Returning an empty tibble
    # plus an "insufficient_baseline" attribute lets the UI render
    # a clear message instead of a chart of zero-km targets that
    # nominally say "100% av baseline".
    out <- tibble::tibble(
      week_start = as.Date(character(0)),
      week_end = as.Date(character(0)),
      weeks_until_race = integer(0),
      phase = character(0),
      baseline_km = numeric(0),
      target_km = numeric(0),
      relative_to_baseline = numeric(0)
    )
    attr(out, "race_date") <- race_date
    attr(out, "distance_km") <- distance_km
    attr(out, "insufficient_baseline") <- TRUE
    return(out)
  }

  iso_dow <- function(d) as.integer(format(d, "%u"))
  today <- Sys.Date()
  this_monday <- today - (iso_dow(today) - 1L)
  race_monday <- race_date - (iso_dow(race_date) - 1L)

  weeks <- seq.Date(this_monday, race_monday, by = "week")
  weeks_until <- as.integer(as.numeric(race_monday - weeks) / 7)

  taper_floor <- 0.45
  rel <- ifelse(
    weeks_until > taper_weeks,
    1.0,
    taper_floor + (1 - taper_floor) * weeks_until / (taper_weeks + 1L)
  )
  phase <- ifelse(weeks_until == 0L, "race",
                   ifelse(weeks_until <= taper_weeks, "taper", "build"))

  plan <- tibble::tibble(
    week_start           = weeks,
    week_end             = weeks + 6L,
    weeks_until_race     = weeks_until,
    phase                = phase,
    baseline_km          = baseline_km,
    target_km            = round(baseline_km * rel, 1),
    relative_to_baseline = round(rel, 3)
  )
  attr(plan, "race_date")   <- race_date
  attr(plan, "distance_km") <- distance_km
  plan
}


#' Render a taper plan as Swedish prose
#'
#' Dates are formatted in a locale-invariant way (\code{format(date)},
#' which on Date objects produces ISO YYYY-MM-DD regardless of
#' LC_TIME). Without that, the systemd-launched Shiny renderer on
#' a server with the C locale would emit English weekday/month
#' abbreviations next to Swedish prose.
#'
#' @param plan Output of \code{compute_taper_plan()}.
#' @return Character scalar (multi-line).
#' @export
render_taper_plan_prose <- function(plan) {
  if (is.null(plan) || nrow(plan) == 0L) {
    if (isTRUE(attr(plan, "insufficient_baseline"))) {
      return(paste("Otillräcklig baseline — ingen löpning de senaste",
                   "4 veckorna. Logga några pass innan taper-planen",
                   "kan beräknas."))
    }
    return("Ingen taper-plan att visa.")
  }
  race_date   <- attr(plan, "race_date")
  distance_km <- attr(plan, "distance_km")
  baseline    <- plan$baseline_km[[1]]

  header_bits <- character(0)
  if (!is.null(race_date)) {
    header_bits <- c(header_bits,
                     sprintf("Tävling: %s", format(race_date)))
  }
  if (length(distance_km) && !is.na(distance_km)) {
    header_bits <- c(header_bits, sprintf("%.1f km", distance_km))
  }
  header_bits <- c(header_bits,
                   sprintf("baseline %.1f km/v (4v median)", baseline))
  lines <- paste(header_bits, collapse = " — ")

  for (i in seq_len(nrow(plan))) {
    row <- plan[i, ]
    week_iso <- format(row$week_start)
    label <- switch(row$phase,
      race  = sprintf("Tävlingsvecka (%s)", week_iso),
      taper = sprintf("Taper -%d (%s)", row$weeks_until_race, week_iso),
      build = sprintf("Bygg (%s)",      week_iso)
    )
    lines <- c(lines,
               sprintf("  %s: %.1f km (%.0f %% av baseline)",
                       label, row$target_km,
                       100 * row$relative_to_baseline))
  }
  paste(lines, collapse = "\n")
}


# --- Race readiness ---------------------------------------------------------

# Internal: score a "stability" component where smaller-delta = better.
# Returns 100 inside the "good" band, 0 outside the "bad" band, linear
# between. Sign convention: `direction = "lower-is-better"` flips the
# delta (used for resting HR, where higher than baseline is bad).
.score_stability <- function(delta, good_threshold, bad_threshold,
                              direction = "higher-is-better") {
  if (is.na(delta)) return(NA_real_)
  if (identical(direction, "lower-is-better")) delta <- -delta
  if (delta >= -abs(good_threshold)) return(100)
  if (delta <= -abs(bad_threshold))  return(0)
  100 * (delta + abs(bad_threshold)) /
        (abs(bad_threshold) - abs(good_threshold))
}


#' Compute race-day readiness composite score
#'
#' Combines four components — CTL trend, projected TSB, HRV
#' stability, resting-HR stability — into a 0–100 score and a
#' Swedish status label. Components without enough data are dropped
#' from the average rather than scored as 0, so the result degrades
#' gracefully when health data is missing.
#'
#' @param summaries Augmented summaries from \code{my_dbs_load()}.
#' @param health_daily Daily health data from \code{load_health_data()};
#'   may be \code{NULL}.
#' @param target_date Race date. May be in the past or future.
#' @param taper_weeks Used by the TSB projection to estimate how much
#'   ATL will decay between today and \code{target_date}. Default 2.
#' @return Named list with \code{target_date}, \code{days_until},
#'   \code{components} (list of per-component scores + raw values),
#'   \code{score} (0–100, or \code{NA} when nothing could be measured),
#'   \code{status} ("Klar" / "Tveksam" / "Inte klar" /
#'   "Otillräcklig data"), and \code{prose} (multi-line Swedish text).
#' @export
compute_race_readiness <- function(summaries, health_daily, target_date,
                                    taper_weeks = 2L) {
  target_date <- as.Date(target_date)
  if (length(target_date) != 1L || is.na(target_date)) {
    stop("target_date must be a non-NA, length-1 Date")
  }
  taper_weeks <- as.integer(taper_weeks)
  if (length(taper_weeks) != 1L || is.na(taper_weeks) ||
      taper_weeks < 1L || taper_weeks > 4L) {
    stop("taper_weeks must be an integer between 1 and 4")
  }
  days_until  <- as.integer(as.numeric(target_date - Sys.Date()))

  components <- list()

  pmc <- if (!is.null(summaries) && nrow(summaries) > 0L) {
    tryCatch(compute_pmc(summaries, health_daily = health_daily),
             error = function(e) NULL)
  } else NULL

  if (!is.null(pmc) && nrow(pmc) > 0L) {
    ctl_today <- tail(pmc$ctl, 1L)
    baseline_date <- Sys.Date() - 28L
    # Pick the row closest to 28d ago (handles missing days in the spine)
    idx <- which.min(abs(pmc$date - baseline_date))
    if (length(idx) == 1L) {
      ctl_baseline <- pmc$ctl[[idx]]
      delta_ctl <- ctl_today - ctl_baseline
      score <- if (delta_ctl >= -2) 100
               else if (delta_ctl <= -10) 0
               else (delta_ctl + 10) * 100 / 8
      components$ctl_trend <- list(
        score = score, raw_today = ctl_today,
        raw_baseline = ctl_baseline, delta = delta_ctl
      )
    }

    # TSB projection: as the taper unloads ATL, TSB drifts toward a
    # modestly-tapered ceiling of 0.3 × CTL (puts us mid-band 5–15
    # for typical fitness levels). We linearly blend from today's
    # TSB toward that ceiling, capped by taper_weeks; race-day-or-
    # past returns today's TSB unchanged.
    tsb_today <- tail(pmc$tsb, 1L)
    if (days_until <= 0L) {
      tsb_proj <- tsb_today
    } else {
      weeks_to <- min(days_until / 7, taper_weeks)
      ceiling_tsb <- ctl_today * 0.3
      tsb_proj <- tsb_today + (ceiling_tsb - tsb_today) * weeks_to /
                                                          (taper_weeks + 1L)
    }
    score <- if (tsb_proj >= 5 && tsb_proj <= 15) 100
             else if (tsb_proj >= 0 && tsb_proj <= 25) 50
             else 0
    components$tsb_projection <- list(
      score = score, raw_today = tsb_today,
      raw_projected = tsb_proj
    )
  }

  # Health components
  if (!is.null(health_daily) && nrow(health_daily) > 0L) {
    .stability_component <- function(metric_name, good, bad,
                                      direction = "higher-is-better") {
      hd <- health_daily[health_daily$metric == metric_name, , drop = FALSE]
      if (nrow(hd) < 7L) return(NULL)
      hd$date <- as.Date(hd$date)
      hd <- hd[order(hd$date), ]
      last7  <- tail(hd$value, 7L)
      last28 <- tail(hd$value, 28L)
      if (sum(!is.na(last7)) < 3L || sum(!is.na(last28)) < 7L) return(NULL)
      m7  <- mean(last7,  na.rm = TRUE)
      m28 <- mean(last28, na.rm = TRUE)
      delta <- m7 - m28
      score <- .score_stability(delta, good, bad, direction = direction)
      # baseline_days is the actual length of last28, not always 28
      # — accounts for users with < 28 days of cached data. Carried
      # through so the prose label stays honest.
      list(score = score, raw_today = m7, raw_baseline = m28, delta = delta,
           baseline_days = length(last28))
    }
    hrv <- .stability_component("heart_rate_variability",
                                 good = 0.5, bad = 3,
                                 direction = "higher-is-better")
    if (!is.null(hrv)) components$hrv_stability <- hrv
    rhr <- .stability_component("resting_heart_rate",
                                 good = 1, bad = 3,
                                 direction = "lower-is-better")
    if (!is.null(rhr)) components$resting_hr_stability <- rhr
  }

  if (length(components) == 0L) {
    return(list(
      target_date = target_date, days_until = days_until,
      components = list(), score = NA_real_, status = "Otillräcklig data",
      prose = paste0("Inte tillräckligt med data för att bedöma ",
                     "tävlingsberedskap.")
    ))
  }

  scores <- vapply(components, function(c) c$score, numeric(1))
  total_score <- mean(scores, na.rm = TRUE)
  status <- if (is.na(total_score)) "Otillräcklig data"
            else if (total_score >= 70) "Klar"
            else if (total_score >= 40) "Tveksam"
            else "Inte klar"

  prose <- .render_race_readiness_prose(components, total_score, status,
                                         days_until)

  list(
    target_date = target_date, days_until = days_until,
    components  = components,  score = total_score,
    status      = status,      prose = prose
  )
}


.render_race_readiness_prose <- function(components, total_score, status,
                                          days_until) {
  hdr <- if (days_until > 0L) {
    sprintf("Tävlingsberedskap (%d dagar kvar): %s — %d/100",
            days_until, status, round(total_score))
  } else if (days_until == 0L) {
    sprintf("Tävlingsberedskap (idag): %s — %d/100",
            status, round(total_score))
  } else {
    sprintf("Tävlingsberedskap (%d dagar sedan): %s — %d/100",
            abs(days_until), status, round(total_score))
  }

  # Surface which components weren't measured (per the design doc:
  # we never zero-score absent data, we drop it — and the prose
  # should say so explicitly so the user knows the score is being
  # averaged over a partial set).
  all_components <- c(
    ctl_trend            = "CTL",
    tsb_projection       = "TSB",
    hrv_stability        = "HRV",
    resting_hr_stability = "Vilopuls"
  )
  missing <- setdiff(names(all_components), names(components))
  missing_line <- if (length(missing) > 0L) {
    sprintf("Saknade komponenter (ingår inte i snittet): %s",
            paste(all_components[missing], collapse = ", "))
  } else NULL

  lines <- character(0)
  if (!is.null(components$ctl_trend)) {
    c0 <- components$ctl_trend
    arrow <- if (c0$delta >= 1) "↑" else if (c0$delta <= -1) "↓" else "→"
    lines <- c(lines, sprintf(
      "  CTL (fitness): %.0f → %.0f %s (delta %+.1f, 28d)",
      c0$raw_baseline, c0$raw_today, arrow, c0$delta
    ))
  }
  if (!is.null(components$tsb_projection)) {
    c0 <- components$tsb_projection
    lines <- c(lines, sprintf(
      "  TSB (form): nu %+.1f, projektion på tävlingsdagen %+.1f",
      c0$raw_today, c0$raw_projected
    ))
  }
  .bdays <- function(c0) {
    if (is.null(c0$baseline_days)) 28L else c0$baseline_days
  }
  if (!is.null(components$hrv_stability)) {
    c0 <- components$hrv_stability
    lines <- c(lines, sprintf(
      "  HRV: 7d %.1f vs %dd %.1f (%+.1f ms)",
      c0$raw_today, .bdays(c0), c0$raw_baseline, c0$delta
    ))
  }
  if (!is.null(components$resting_hr_stability)) {
    c0 <- components$resting_hr_stability
    lines <- c(lines, sprintf(
      "  Vilopuls: 7d %.0f vs %dd %.0f (%+.1f bpm)",
      c0$raw_today, .bdays(c0), c0$raw_baseline, c0$delta
    ))
  }

  paste(c(hdr, lines, missing_line), collapse = "\n")
}


#' Render a race readiness assessment as Swedish prose
#'
#' Convenience wrapper around the \code{prose} field of
#' \code{compute_race_readiness()}.
#'
#' @param assessment Output of \code{compute_race_readiness()}.
#' @return Character scalar (multi-line).
#' @export
render_race_readiness_prose <- function(assessment) {
  if (is.null(assessment) || is.null(assessment$prose)) {
    return("Ingen bedömning att visa.")
  }
  assessment$prose
}
