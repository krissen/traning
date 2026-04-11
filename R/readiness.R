# Daily readiness model — fuses Apple Watch health data with Garmin training load

# --- Internal scoring helpers -------------------------------------------------

#' Map a numeric value to 0-100 via piecewise-linear interpolation
#'
#' @param x Numeric vector.
#' @param breakpoints Named numeric vector where names are input values (as
#'   strings) and values are the corresponding scores. Must be sorted by input
#'   value ascending. Values outside the range clamp to the nearest endpoint.
#' @return Numeric vector of scores, same length as x.
#' @keywords internal
.piecewise_score <- function(x, breakpoints) {
  bp_x <- as.numeric(names(breakpoints))
  bp_y <- unname(breakpoints)
  vapply(x, function(val) {
    if (is.na(val)) return(NA_real_)
    if (val <= bp_x[1]) return(bp_y[1])
    if (val >= bp_x[length(bp_x)]) return(bp_y[length(bp_y)])
    # Find the segment
    idx <- max(which(bp_x <= val))
    x0 <- bp_x[idx]; x1 <- bp_x[idx + 1]
    y0 <- bp_y[idx]; y1 <- bp_y[idx + 1]
    y0 + (val - x0) / (x1 - x0) * (y1 - y0)
  }, numeric(1))
}

#' Score HRV z-score to 0-100
#' @param hrv_z Numeric vector of z-scores.
#' @return Numeric vector of scores.
#' @keywords internal
.score_hrv <- function(hrv_z) {
  .piecewise_score(hrv_z, c("-2" = 0, "-1" = 50, "0" = 75, "1" = 100))
}

#' Score sleep duration to 0-100
#' @param total Numeric vector of total sleep hours.
#' @param deep Numeric vector of deep sleep hours (NA if unavailable).
#' @param rem Numeric vector of REM sleep hours (NA if unavailable).
#' @return Numeric vector of scores.
#' @keywords internal
.score_sleep <- function(total, deep = NA_real_, rem = NA_real_) {
  base <- .piecewise_score(total, c("4" = 0, "6" = 50, "7" = 75, "8" = 100))

  # Staging bonus/penalty where data exists
  has_staging <- !is.na(deep) & !is.na(rem) & !is.na(total) & total > 0
  ratio <- ifelse(has_staging, (deep + rem) / total, NA_real_)

  bonus <- ifelse(has_staging & ratio >= 0.35, 10,
           ifelse(has_staging & ratio < 0.20, -10, 0))

  pmin(100, pmax(0, base + bonus))
}

#' Score resting HR deviation to 0-100
#' @param rhr_deviation Numeric vector (today - 30d baseline).
#' @return Numeric vector of scores.
#' @keywords internal
.score_rhr <- function(rhr_deviation) {
  .piecewise_score(rhr_deviation,
                   c("-3" = 100, "0" = 80, "3" = 50, "5" = 25, "8" = 0))
}

#' Score TRIMP ratio (yesterday's load / ATL) to 0-100
#' @param trimp_ratio Numeric vector.
#' @return Numeric vector of scores.
#' @keywords internal
.score_trimp <- function(trimp_ratio) {
  .piecewise_score(trimp_ratio, c("0" = 90, "1" = 70, "2" = 40, "3" = 10))
}

#' Score wrist temperature deviation to 0-100
#'
#' Elevated sleeping wrist temperature (vs 14-day baseline) is an early
#' illness signal. Negative deviations are benign.
#'
#' @param wt_deviation Numeric vector (today - 14d median).
#' @return Numeric vector of scores.
#' @keywords internal
.score_wrist_temp <- function(wt_deviation) {
  .piecewise_score(wt_deviation,
                   c("-0.5" = 100, "0" = 90, "0.3" = 70, "0.5" = 40, "1" = 0))
}

# --- Composite scoring --------------------------------------------------------

#' Weighted composite with NA-aware weight redistribution
#'
#' @param score_df Data frame where each column is a component score (0-100).
#' @param weights Named numeric vector of weights (must sum to 1).
#' @return List with \code{score} (numeric vector) and \code{n_components}
#'   (integer vector).
#' @keywords internal
.weighted_composite <- function(score_df, weights) {
  stopifnot(all(names(weights) %in% names(score_df)))

  n <- nrow(score_df)
  score <- numeric(n)
  n_comp <- integer(n)

  for (i in seq_len(n)) {
    vals <- vapply(names(weights), function(w) score_df[[w]][i], numeric(1))
    available <- !is.na(vals)
    n_comp[i] <- sum(available)
    if (n_comp[i] == 0) {
      score[i] <- NA_real_
    } else {
      w <- weights[available] / sum(weights[available])  # redistribute
      score[i] <- sum(vals[available] * w)
    }
  }

  list(score = score, n_components = n_comp)
}

# --- Flag helpers -------------------------------------------------------------

#' Detect n+ consecutive days where x exceeds threshold
#'
#' @param x Numeric vector.
#' @param threshold Numeric threshold.
#' @param min_run Integer minimum consecutive days.
#' @return Logical vector (TRUE on any day that is part of a qualifying run).
#' @keywords internal
.consecutive_flag <- function(x, threshold = 5, min_run = 3) {
  above <- !is.na(x) & x > threshold
  runs <- rle(above)
  result <- logical(length(x))
  pos <- 0L
  for (i in seq_along(runs$lengths)) {
    idx <- (pos + 1L):(pos + runs$lengths[i])
    if (runs$values[i] && runs$lengths[i] >= min_run) {
      result[idx] <- TRUE
    }
    pos <- pos + runs$lengths[i]
  }
  result
}

# --- Main function ------------------------------------------------------------

#' Compute daily readiness score
#'
#' Fuses Apple Watch health data (HRV, resting HR, sleep, wrist temperature)
#' with Garmin training load (TRIMP from PMC) into a composite readiness score.
#' When wrist temperature data is available, uses 5-component weighting;
#' otherwise falls back to the original 4-component model.
#'
#' @param health_daily Long-format tibble from \code{load_health_data()}.
#' @param summaries Garmin summaries tibble.
#' @param hr_max Optional HRmax override.
#' @param hr_rest Optional HRrest override.
#' @param after Start date for output filtering (inclusive). NULL = no filter.
#' @param before End date for output filtering (inclusive). NULL = no filter.
#' @return Tibble with one row per day containing readiness score, component
#'   scores, flags, and data quality.
#' @export
compute_readiness <- function(health_daily, summaries,
                               hr_max = NULL, hr_rest = NULL,
                               after = NULL, before = NULL) {
  # 1. Health side: wide tibble with AW metrics
  health <- get_readiness(health_daily)

  # 2. Training side: PMC with full date spine
  pmc <- compute_pmc(summaries, hr_max = hr_max, hr_rest = hr_rest)

  # 3. Unified date spine
  all_dates <- sort(unique(c(health$date, pmc$date)))
  spine <- tibble::tibble(date = all_dates)

  # Join health
  health_cols <- health |>
    dplyr::select(date,
                  dplyr::any_of(c("resting_heart_rate", "heart_rate_variability",
                                   "ln_rmssd", "sleep_totalSleep",
                                   "sleep_deep", "sleep_rem",
                                   "apple_sleeping_wrist_temperature")))
  spine <- spine |> dplyr::left_join(health_cols, by = "date")

  # Join PMC
  pmc_cols <- pmc |>
    dplyr::select(date, daily_trimp, atl, ctl, tsb)
  spine <- spine |> dplyr::left_join(pmc_cols, by = "date")

  # 4. HRV baselines (7-day rolling)
  spine <- spine |>
    dplyr::mutate(
      ln_rmssd_7d_mean = .rolling_mean(ln_rmssd, 7),
      ln_rmssd_7d_sd   = .rolling_sd(ln_rmssd, 7),
      hrv_z = dplyr::if_else(
        !is.na(ln_rmssd_7d_sd) & ln_rmssd_7d_sd > 0,
        (ln_rmssd - ln_rmssd_7d_mean) / ln_rmssd_7d_sd,
        NA_real_
      )
    )

  # 5. RHR baseline (30-day rolling from physiology module)
  rhr_baseline <- tryCatch(
    get_hr_rest(spine$date),
    error = function(e) rep(NA_real_, nrow(spine))
  )
  spine <- spine |>
    dplyr::mutate(
      rhr_30d_mean  = rhr_baseline,
      rhr_deviation = resting_heart_rate - rhr_30d_mean
    )

  # 6. Wrist temperature baseline (14-day rolling median)
  has_wrist_temp <- "apple_sleeping_wrist_temperature" %in% names(spine)
  if (has_wrist_temp) {
    wt <- spine$apple_sleeping_wrist_temperature
    wt_14d_median <- vapply(seq_along(wt), function(i) {
      start <- max(1L, i - 13L)
      vals <- wt[start:i]
      vals <- vals[!is.na(vals)]
      if (length(vals) >= 3) stats::median(vals) else NA_real_
    }, numeric(1))
    spine <- spine |>
      dplyr::mutate(
        wrist_temp = apple_sleeping_wrist_temperature,
        wrist_temp_14d = wt_14d_median,
        wrist_temp_deviation = wrist_temp - wrist_temp_14d
      )
  }

  # 7. TRIMP ratio (yesterday's load / ATL)
  spine <- spine |>
    dplyr::mutate(
      trimp_yesterday = dplyr::lag(daily_trimp, 1, default = 0),
      trimp_ratio = dplyr::if_else(
        !is.na(atl) & atl > 0,
        trimp_yesterday / atl,
        NA_real_
      )
    )

  # 8. Component scores
  spine <- spine |>
    dplyr::mutate(
      hrv_score   = .score_hrv(hrv_z),
      sleep_score = .score_sleep(sleep_totalSleep, sleep_deep, sleep_rem),
      rhr_score   = .score_rhr(rhr_deviation),
      trimp_score = .score_trimp(trimp_ratio)
    )
  if (has_wrist_temp) {
    spine <- spine |>
      dplyr::mutate(wrist_temp_score = .score_wrist_temp(wrist_temp_deviation))
  }

  # 9. Composite score (5 components when wrist temp available)
  if (has_wrist_temp) {
    weights <- c(hrv = 0.30, sleep = 0.25, rhr = 0.20,
                 trimp = 0.15, wrist_temp = 0.10)
    score_df <- spine |>
      dplyr::select(hrv = hrv_score, sleep = sleep_score,
                    rhr = rhr_score, trimp = trimp_score,
                    wrist_temp = wrist_temp_score)
  } else {
    weights <- c(hrv = 0.35, sleep = 0.30, rhr = 0.20, trimp = 0.15)
    score_df <- spine |>
      dplyr::select(hrv = hrv_score, sleep = sleep_score,
                    rhr = rhr_score, trimp = trimp_score)
  }
  composite <- .weighted_composite(score_df, weights)

  spine$readiness_score <- composite$score
  spine$n_components    <- composite$n_components

  # 10. Flags
  spine <- spine |>
    dplyr::mutate(
      hrv_flag   = !is.na(hrv_z) & hrv_z < -1,
      rhr_flag   = .consecutive_flag(rhr_deviation, threshold = 5, min_run = 3),
      sleep_flag = !is.na(sleep_totalSleep) & sleep_totalSleep < 7 &
                   !is.na(hrv_z) & hrv_z < 0,
      load_flag  = !is.na(trimp_yesterday) & !is.na(atl) & atl > 0 &
                   trimp_yesterday > 2 * atl
    )
  if (has_wrist_temp) {
    spine <- spine |>
      dplyr::mutate(
        wrist_temp_flag = .consecutive_flag(wrist_temp_deviation,
                                            threshold = 0.5, min_run = 2)
      )
  }

  # 11. Status and data quality
  max_components <- if (has_wrist_temp) 5L else 4L
  spine <- spine |>
    dplyr::mutate(
      readiness_status = dplyr::case_when(
        is.na(readiness_score) ~ NA_character_,
        readiness_score >= 70  ~ "Gr\u00f6n",
        readiness_score >= 40  ~ "Gul",
        TRUE                   ~ "R\u00f6d"
      ),
      data_quality = dplyr::case_when(
        n_components == max_components ~ "full",
        n_components >= 2              ~ "partial",
        n_components == 1              ~ "minimal",
        TRUE                           ~ NA_character_
      )
    )

  # 12. Select and rename output columns
  base_cols <- c(
    "date", "readiness_score", "readiness_status",
    "ln_rmssd", "ln_rmssd_7d_mean", "ln_rmssd_7d_sd", "hrv_z",
    "hrv_score", "hrv_flag",
    "resting_heart_rate", "rhr_30d_mean", "rhr_deviation",
    "rhr_score", "rhr_flag",
    "sleep_totalSleep", "sleep_deep", "sleep_rem",
    "sleep_score", "sleep_flag",
    "daily_trimp", "atl", "ctl", "tsb", "trimp_score", "load_flag"
  )
  if (has_wrist_temp) {
    base_cols <- c(base_cols, "wrist_temp", "wrist_temp_14d",
                   "wrist_temp_deviation", "wrist_temp_score",
                   "wrist_temp_flag")
  }
  base_cols <- c(base_cols, "data_quality")

  result <- spine |>
    dplyr::select(dplyr::all_of(base_cols)) |>
    dplyr::rename(
      resting_hr = resting_heart_rate,
      sleep_total = sleep_totalSleep
    )

  # 13. Filter output
  if (!is.null(after))  result <- result |> dplyr::filter(date >= as.Date(after))
  if (!is.null(before)) result <- result |> dplyr::filter(date < as.Date(before))

  result
}
