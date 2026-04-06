# Physiological parameters: HRmax, HRrest, and Apple Watch resting HR import

# Internal helper: resolve the resting HR cache path.
# Uses $TRANING_DATA/cache/resting_hr.RData by default.
.rhr_cache_path <- function(cache_path = NULL) {
  if (!is.null(cache_path)) return(cache_path)
  data_root <- Sys.getenv("TRANING_DATA", unset = NA_character_)
  if (is.na(data_root) || nchar(data_root) == 0) {
    warning("TRANING_DATA env var not set — cannot resolve cache path")
    return(NULL)
  }
  file.path(data_root, "cache", "resting_hr.RData")
}

#' Import resting heart rate from Apple Watch CSV export
#'
#' Reads the Vilo_hjartfrekvens.csv, filters out non-Apple Watch sources
#' (removes "Connect" entries), removes physiological outliers, and returns
#' a clean daily time series with one row per day.
#'
#' Sources retained: rows whose Source contains "kankad" or "Apple Watch".
#' Sources removed: rows whose Source contains "Connect".
#'
#' When multiple readings exist for the same calendar day, the minimum value
#' is kept (resting heart rate is the lowest reliable reading of the day).
#'
#' @param csv_path Path to Vilo_hjartfrekvens.csv
#' @return Tibble with columns: date (Date), rhr (numeric, bpm),
#'   source (character). Returns an empty tibble with a warning if the file
#'   does not exist.
#' @export
import_resting_hr <- function(csv_path) {
  if (!file.exists(csv_path)) {
    warning("Resting HR CSV not found: ", csv_path)
    return(tibble::tibble(
      date   = as.Date(character(0)),
      rhr    = numeric(0),
      source = character(0)
    ))
  }

  message("Reading resting HR data from: ", csv_path)

  raw <- utils::read.csv(
    csv_path,
    stringsAsFactors = FALSE,
    check.names      = FALSE,
    encoding         = "UTF-8"
  )

  # Normalise column names: the CSV has "Date/Time", "Vilo hjärtfrekvens (count/min)", "Source"
  colnames(raw) <- c("datetime_str", "bpm", "source_raw")

  result <- raw %>%
    # Trim whitespace from source field (entries like "kankad " have trailing space)
    dplyr::mutate(source_raw = stringr::str_trim(source_raw)) %>%
    # Keep only Apple Watch sources; drop Garmin Connect entries
    dplyr::filter(
      stringr::str_detect(source_raw, "kankad|Apple Watch"),
      !stringr::str_detect(source_raw, "Connect")
    ) %>%
    # Remove physiological outliers
    dplyr::filter(bpm >= 30, bpm <= 100) %>%
    # Parse datetime to date
    dplyr::mutate(
      date = as.Date(datetime_str)
    ) %>%
    # One row per day: keep the minimum (lowest = most resting)
    dplyr::group_by(date) %>%
    dplyr::slice_min(order_by = bpm, n = 1, with_ties = FALSE) %>%
    dplyr::ungroup() %>%
    dplyr::select(date, rhr = bpm, source = source_raw) %>%
    dplyr::arrange(date)

  message("Imported ", nrow(result), " daily resting HR observations ",
          "(", format(min(result$date)), " to ", format(max(result$date)), ")")

  result
}

#' Get HRmax estimate
#'
#' Returns HRmax from the \code{HR_MAX} environment variable if set,
#' otherwise estimates from the 98th percentile of max HR values observed
#' in the enriched summaries (filtered to running sessions > 20 min to
#' exclude sensor artifacts), otherwise uses the Tanaka formula
#' (208 - 0.7 * age, requiring \code{AGE} env var), and as a last resort
#' returns 185 bpm with a warning.
#'
#' @param summaries Summaries tibble, optionally with a \code{garmin_maxHR}
#'   column (added by \code{add_my_columns()}). May be \code{NULL}.
#' @return Numeric scalar (beats per minute)
#' @export
get_hr_max <- function(summaries = NULL) {
  # 1. Explicit env var takes priority
  hr_max_env <- suppressWarnings(as.numeric(Sys.getenv("HR_MAX", unset = "")))
  if (!is.na(hr_max_env) && hr_max_env > 0) {
    return(hr_max_env)
  }

  # 2. Data-driven: 98th percentile of garmin_maxHR from running sessions > 20 min
  if (!is.null(summaries) && "garmin_maxHR" %in% colnames(summaries)) {
    max_hr_vals <- summaries %>%
      dplyr::filter(
        stringr::str_detect(sport, "running"),
        # duration is a difftime (typically in minutes from trackeR)
        as.numeric(duration, units = "mins") > 20
      ) %>%
      dplyr::pull(garmin_maxHR) %>%
      as.numeric()

    max_hr_vals <- max_hr_vals[!is.na(max_hr_vals) & max_hr_vals > 0]

    if (length(max_hr_vals) >= 10) {
      estimate <- stats::quantile(max_hr_vals, probs = 0.98, names = FALSE)
      message("HRmax estimated from data (98th percentile): ", round(estimate), " bpm")
      return(round(estimate))
    }
  }

  # 3. Tanaka formula: 208 - 0.7 * age
  age_env <- suppressWarnings(as.numeric(Sys.getenv("AGE", unset = "")))
  if (!is.na(age_env) && age_env > 0) {
    estimate <- 208 - 0.7 * age_env
    message("HRmax estimated via Tanaka formula (age=", age_env, "): ",
            round(estimate), " bpm")
    return(round(estimate))
  }

  # 4. Ultimate fallback
  warning("HRmax could not be determined (set HR_MAX or AGE env var, or ",
          "provide summaries with garmin_maxHR). Returning 185 bpm as default.")
  185
}

#' Get resting heart rate for a given date or date vector
#'
#' Returns time-varying HRrest using Apple Watch data when available,
#' using a backward-looking 30-day rolling mean (mean of the 30 days
#' preceding each target date). Falls back to the \code{HR_REST} env var,
#' then to 50 bpm.
#'
#' When the date vector spans both covered and uncovered periods, AW-derived
#' values are returned for covered dates and fallback values elsewhere.
#'
#' @param date Date vector (Date or character "YYYY-MM-DD"). Can be length > 1.
#' @param rhr_data Optional tibble from \code{import_resting_hr()}. If
#'   \code{NULL}, attempts to load from cached resting_hr.RData; if the cache
#'   does not exist, falls back to a fixed value.
#' @return Numeric vector of the same length as \code{date} (bpm).
#' @export
get_hr_rest <- function(date, rhr_data = NULL) {
  date <- as.Date(date)

  # Attempt to load cached data if rhr_data not supplied
  if (is.null(rhr_data)) {
    rhr_data <- load_resting_hr()
  }

  # Determine fallback value from env var or fixed default
  fallback_env <- suppressWarnings(as.numeric(Sys.getenv("HR_REST", unset = "")))
  fallback <- if (!is.na(fallback_env) && fallback_env > 0) fallback_env else 50

  # Without AW data, return scalar fallback for all dates
  if (is.null(rhr_data) || nrow(rhr_data) == 0) {
    return(rep(fallback, length(date)))
  }

  rhr_min  <- min(rhr_data$date)
  rhr_max  <- max(rhr_data$date)

  # Compute a backward-looking 30-day rolling mean for each target date.
  # For each element of date: average rhr in [date - 30, date - 1].
  # If no observations fall in that window, use fallback.
  result <- vapply(date, function(d) {
    if (d < rhr_min || d > rhr_max + 1) {
      # Date is entirely outside the AW data range
      return(fallback)
    }
    window_start <- d - 30
    window_end   <- d - 1
    window_vals  <- rhr_data$rhr[
      rhr_data$date >= window_start & rhr_data$date <= window_end
    ]
    if (length(window_vals) == 0) {
      return(fallback)
    }
    mean(window_vals, na.rm = TRUE)
  }, numeric(1))

  result
}

#' Get time-varying HRmax for a date vector
#'
#' Returns HRmax that declines with age, using one of these strategies:
#' \enumerate{
#'   \item \code{HR_MAX} env var → fixed value for all dates (user override)
#'   \item \code{BIRTH_YEAR} env var + Tanaka formula (208 - 0.7 * age)
#'   \item \code{garmin_maxHR} data → linear fit of yearly 98th percentile,
#'     extrapolated for years without data
#'   \item Fallback: fixed 185 bpm with warning
#' }
#'
#' @param date Date vector (Date or character).
#' @param summaries Optional summaries tibble with \code{garmin_maxHR}.
#' @return Numeric vector of same length as \code{date} (bpm, rounded).
#' @export
get_hr_max_at <- function(date, summaries = NULL) {
  date <- as.Date(date)

  # 1. Explicit override → fixed for all dates
  hr_max_env <- suppressWarnings(as.numeric(Sys.getenv("HR_MAX", unset = "")))
  if (!is.na(hr_max_env) && hr_max_env > 0) {
    return(rep(hr_max_env, length(date)))
  }

  target_years <- as.numeric(format(date, "%Y"))

  # 2. BIRTH_YEAR + Tanaka formula (preferred — simple and physiologically sound)
  birth_year <- suppressWarnings(
    as.numeric(Sys.getenv("BIRTH_YEAR", unset = "")))
  if (!is.na(birth_year) && birth_year > 1900) {
    ages <- target_years - birth_year
    result <- round(208 - 0.7 * ages)
    return(result)
  }

  # 3. Data-driven: yearly 98th percentile with linear fit
  if (!is.null(summaries) && "garmin_maxHR" %in% colnames(summaries)) {
    yearly <- summaries %>%
      dplyr::filter(
        stringr::str_detect(sport, "running"),
        as.numeric(duration, units = "mins") > 20
      ) %>%
      dplyr::mutate(
        year     = as.numeric(format(sessionStart, "%Y")),
        max_hr_v = as.numeric(garmin_maxHR)
      ) %>%
      dplyr::filter(!is.na(max_hr_v), max_hr_v > 0) %>%
      dplyr::group_by(year) %>%
      dplyr::filter(dplyr::n() >= 5) %>%
      dplyr::summarise(
        hr_max = stats::quantile(max_hr_v, probs = 0.98, names = FALSE),
        .groups = "drop"
      )

    if (nrow(yearly) >= 2) {
      fit <- stats::lm(hr_max ~ year, data = yearly)
      predicted <- stats::predict(fit,
                                  newdata = data.frame(year = target_years))
      return(round(pmax(predicted, 150)))
    }
  }

  # 4. AGE env → snapshot (not ideal for 20-year span)
  age_env <- suppressWarnings(as.numeric(Sys.getenv("AGE", unset = "")))
  if (!is.na(age_env) && age_env > 0) {
    estimate <- round(208 - 0.7 * age_env)
    return(rep(estimate, length(date)))
  }

  # 5. Fallback
  warning("Kan inte ber\u00e4kna tidsvarierande HRmax. ",
          "S\u00e4tt BIRTH_YEAR i .Renviron (t.ex. BIRTH_YEAR=1980).")
  rep(185, length(date))
}

#' Cache resting HR data to an RData file
#'
#' Saves the tibble returned by \code{import_resting_hr()} so subsequent
#' calls to \code{get_hr_rest()} can load it without re-reading the CSV.
#'
#' @param rhr_data Tibble from \code{import_resting_hr()}
#' @param cache_path Path to save to. Defaults to
#'   \code{$TRANING_DATA/cache/resting_hr.RData}.
#' @return Invisibly returns \code{cache_path}.
#' @export
save_resting_hr <- function(rhr_data, cache_path = NULL) {
  cache_path <- .rhr_cache_path(cache_path)
  if (is.null(cache_path)) {
    warning("Cannot save resting HR cache: no path resolved")
    return(invisible(NULL))
  }
  cache_dir <- dirname(cache_path)
  if (!dir.exists(cache_dir)) {
    dir.create(cache_dir, recursive = TRUE)
    message("Created cache directory: ", cache_dir)
  }
  save(rhr_data, file = cache_path)
  message("Resting HR cache saved to: ", cache_path)
  invisible(cache_path)
}

#' Load cached resting HR data
#'
#' Loads the tibble previously saved by \code{save_resting_hr()}.
#'
#' @param cache_path Path to load from. Defaults to
#'   \code{$TRANING_DATA/cache/resting_hr.RData}.
#' @return Tibble (as from \code{import_resting_hr()}), or \code{NULL} if the
#'   cache file does not exist.
#' @export
load_resting_hr <- function(cache_path = NULL) {
  cache_path <- .rhr_cache_path(cache_path)
  if (is.null(cache_path) || !file.exists(cache_path)) {
    return(NULL)
  }
  env <- new.env(parent = emptyenv())
  load(cache_path, envir = env)
  if (exists("rhr_data", envir = env)) {
    return(env$rhr_data)
  }
  warning("Cache file exists but does not contain rhr_data object: ", cache_path)
  NULL
}
