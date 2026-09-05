# Alcohol: import-time derivation, energy accounting, alcohol-free
# baseline and the Swedish prose lines that surface them.
#
# Why a module of its own, and why the derived values are computed at
# import rather than at query time:
#
#   * .parse_metric() truncates every sample timestamp to a date
#     (R/health_export.R). The clock time survives only in the canonical
#     JSON, so night attribution — a drink at 23:30 belongs to the night
#     that ends the following morning — is simply not computable from
#     health_daily.RData.
#   * Per-sample `source` survives only in canonical too. For a sum
#     metric, read_canonical_file() returns the precomputed daily total
#     tagged with the FIRST sample's source. dietary_energy is written by
#     DrinkControl today, but the day a food-logging app is added, the
#     cached daily value becomes food plus alcohol with no way to
#     separate them. Filtering on source has to happen while the samples
#     are still individually visible.
#
# Everything that is a parameter choice (baseline window, share window,
# grams per standard unit) stays at query time so tuning it does not
# require a reimport.

# --- Constants ---------------------------------------------------------------

# Grams of ethanol per DrinkControl "count", used ONLY as a fallback when
# the app wrote no energy sample for the night. The count is denominated
# by a setting inside someone else's app: DrinkControl offers 8, 10,
# 13.45 and 14 gram units by jurisdiction, and Sweden's 12 g standardglas
# is not among them. If that setting changes, every historical count
# silently changes meaning, which is why grams and not drinks is the
# quantity this module stores.
.alcohol_g_per_unit <- 10

# Grams of ethanol in one Swedish standardglas. Fixed by definition.
.alcohol_g_per_standardglas <- 12

# Energy density of ethanol, kcal per gram. EU regulation 1169/2011 and
# DrinkControl's own documentation both use 7, so the same constant runs
# in both directions: kcal to grams at import, grams to kcal in the
# fallback.
.alcohol_kcal_per_g <- 7

# How far grams-per-unit may drift from the expected setting before the
# night is flagged. grams / count recovers the app's unit setting for
# free, so a drift means either the setting changed or someone edited a
# per-drink calorie value. Either way the number is not what it claims.
.alcohol_unit_tolerance <- 0.15

# The only source whose dietary_energy samples are alcohol energy.
.alcohol_energy_source <- "DrinkControl"

# Absence of a sample is only informative inside a stretch where logging
# is demonstrably happening. Outside it, "no drinks" and "forgot to log"
# are indistinguishable and the night is excluded rather than counted
# as a zero.
.alcohol_active_window_days <- 10L

#' Grams of ethanol per logged unit (configurable)
#'
#' @return Numeric scalar; \code{getOption("traning.alcohol_g_per_unit")}
#'   when set, otherwise 10.
#' @keywords internal
.alcohol_grams_per_unit <- function() {
  g <- getOption("traning.alcohol_g_per_unit", .alcohol_g_per_unit)
  if (!is.numeric(g) || length(g) != 1L || !is.finite(g) || g <= 0) {
    return(.alcohol_g_per_unit)
  }
  g
}

# --- Paths -------------------------------------------------------------------

#' Resolve the alcohol night-table cache path
#'
#' Lives beside health_daily.RData so a caller that redirects the health
#' cache (tests, an alternate data root) redirects this one too.
#'
#' @param health_cache_path Optional path to health_daily.RData.
#' @return Character path to alcohol_nights.RData.
#' @keywords internal
.alcohol_cache_path <- function(health_cache_path = NULL) {
  if (is.null(health_cache_path)) health_cache_path <- .hae_cache_path()
  file.path(dirname(health_cache_path), "alcohol_nights.RData")
}

#' Empty alcohol night table with the canonical column set
#' @keywords internal
.empty_alcohol_nights <- function() {
  tibble::tibble(
    date                     = as.Date(character()),
    alcohol_units            = numeric(),
    alcohol_night_units      = numeric(),
    alcohol_kcal             = numeric(),
    alcohol_grams            = numeric(),
    alcohol_grams_estimated  = logical(),
    alcohol_g_per_unit       = numeric(),
    alcohol_unit_mismatch    = logical(),
    alcohol_logging_active   = logical()
  )
}

# --- Night attribution -------------------------------------------------------

#' Morning date a day's drinking is attributed to
#'
#' Nights run noon to noon and are keyed by the morning that ends them,
#' so a Saturday evening lands on Sunday morning. Getting this backwards
#' would silently invert every comparison the module produces.
#'
#' Attribution is by calendar date, not by clock time, and deliberately
#' so. The timestamp on a canonical alcohol sample is when the export
#' ran, not when the drink was had: the day arrives as a single
#' aggregated row. Reading an hour off that timestamp would be building
#' on a number that does not mean what it looks like.
#'
#' @param date Date vector of the days drinks were logged for.
#' @return Date vector of the mornings they are attributed to.
#' @keywords internal
.alcohol_night_date <- function(date) {
  as.Date(date) + 1L
}

# --- Canonical readers -------------------------------------------------------

#' Read per-sample rows from a canonical metric directory
#'
#' Bypasses \code{read_canonical_file()} on purpose: that function
#' collapses a sum metric to one daily total and drops the clock time and
#' the per-sample source, both of which the alcohol derivation needs.
#'
#' The date comes from the canonical document, not from the samples: the
#' sample timestamp is when the export ran.
#'
#' @param dir Path to \code{canonical/<metric>/}.
#' @return Tibble with \code{date} (Date), \code{qty}, \code{source},
#'   \code{units}. Empty tibble when the directory is absent or empty.
#' @keywords internal
.read_canonical_samples <- function(dir) {
  empty <- tibble::tibble(date = as.Date(character()), qty = numeric(),
                          source = character(), units = character())
  if (is.null(dir) || !dir.exists(dir)) return(empty)
  files <- list.files(dir, pattern = "\\.json$", full.names = TRUE)
  if (length(files) == 0) return(empty)

  rows <- lapply(files, function(f) {
    raw <- tryCatch(jsonlite::fromJSON(f, simplifyVector = FALSE),
                    error = function(e) NULL)
    if (is.null(raw) || length(raw$samples) == 0) return(NULL)
    units <- .coalesce_scalar(raw$units, NA_character_)
    doc_date <- suppressWarnings(as.Date(
      as.character(.coalesce_scalar(raw$date, NA_character_))))
    parts <- lapply(raw$samples, function(s) {
      qty <- suppressWarnings(as.numeric(.coalesce_scalar(s$qty, NA_real_)))
      d <- doc_date
      if (is.na(d)) {
        d <- suppressWarnings(as.Date(substr(
          as.character(.coalesce_scalar(s$date, NA_character_)), 1, 10)))
      }
      tibble::tibble(
        date   = d,
        qty    = qty,
        source = as.character(.coalesce_scalar(s$source, NA_character_)),
        units  = as.character(units)
      )
    })
    dplyr::bind_rows(parts)
  })
  out <- dplyr::bind_rows(rows)
  if (nrow(out) == 0) return(empty)
  out[!is.na(out$date) & !is.na(out$qty), , drop = FALSE]
}

#' Convert a dietary_energy quantity to kcal
#'
#' HAE reports the metric in kJ on this device, but the units field is
#' honoured rather than assumed: a device switched to kcal must not have
#' its numbers divided by 4.184 a second time.
#'
#' @param qty Numeric vector.
#' @param units Character vector of unit strings.
#' @return Numeric vector of kcal.
#' @keywords internal
.energy_to_kcal <- function(qty, units) {
  u <- tolower(trimws(as.character(units)))
  dplyr::if_else(u %in% c("kcal", "cal", "kalorier"), qty, qty / 4.184)
}

# --- Night table -------------------------------------------------------------

#' Build the per-night alcohol table
#'
#' One row per calendar date over the span the logging covers. The date
#' is the morning a night is attributed to, so
#' \code{alcohol_night_units} on 2026-09-06 counts the drinks logged on
#' the 5th.
#'
#' \code{alcohol_units} is the plain calendar-day total, kept because it
#' is what any per-day metric view (report_metric, Shiny, MCP) will show
#' and the two must not silently disagree.
#'
#' Grams of ethanol, not drinks, is the quantity this table is built
#' around. A "drink" is denominated by a setting inside DrinkControl, and
#' if that setting changes every historical count silently changes
#' meaning. Grams come from the app's own energy figure divided by
#' 7 kcal/g, which is exact and independent of the setting, and dividing
#' grams by the count recovers the setting itself as a free integrity
#' check.
#'
#' @param samples Tibble of alcohol_consumption samples
#'   (\code{date}, \code{qty}, \code{source}, \code{units}).
#' @param energy Tibble of dietary_energy samples, same shape. Filtered
#'   to \code{.alcohol_energy_source} inside this function.
#' @param active_window_days Half-width, in days, of the window that
#'   makes an absent sample count as a genuine zero.
#' @return Tibble; see \code{.empty_alcohol_nights()} for the columns.
#' @export
build_alcohol_nights <- function(samples, energy = NULL,
                                  active_window_days = .alcohol_active_window_days) {
  if (is.null(samples) || nrow(samples) == 0) return(.empty_alcohol_nights())
  samples <- samples[!is.na(samples$date) & !is.na(samples$qty), , drop = FALSE]
  if (nrow(samples) == 0) return(.empty_alcohol_nights())
  samples$date <- as.Date(samples$date)

  sample_dates <- sort(unique(samples$date))
  spine <- tibble::tibble(
    date = seq(min(sample_dates) - active_window_days,
               max(sample_dates) + active_window_days + 1L,
               by = "day")
  )

  by_day <- samples |>
    dplyr::group_by(.data$date) |>
    dplyr::summarise(alcohol_units = sum(.data$qty, na.rm = TRUE),
                     .groups = "drop")

  by_night <- by_day
  by_night$date <- .alcohol_night_date(by_night$date)
  names(by_night)[names(by_night) == "alcohol_units"] <- "alcohol_night_units"

  # Energy: DrinkControl's own arithmetic on its own unit definition, so
  # it cannot drift out of step with the count the way a constant on this
  # side would the moment the app's standard-drink setting changes.
  kcal_by_night <- NULL
  if (!is.null(energy) && nrow(energy) > 0) {
    e <- energy[!is.na(energy$date) & !is.na(energy$qty), , drop = FALSE]
    e <- e[!is.na(e$source) & e$source == .alcohol_energy_source, , drop = FALSE]
    if (nrow(e) > 0) {
      e$date <- .alcohol_night_date(as.Date(e$date))
      e$kcal <- .energy_to_kcal(e$qty, e$units)
      kcal_by_night <- e |>
        dplyr::group_by(.data$date) |>
        dplyr::summarise(alcohol_kcal = sum(.data$kcal, na.rm = TRUE),
                         .groups = "drop")
    }
  }

  out <- spine |>
    dplyr::left_join(by_day, by = "date") |>
    dplyr::left_join(by_night, by = "date")
  if (!is.null(kcal_by_night)) {
    out <- dplyr::left_join(out, kcal_by_night, by = "date")
  } else {
    out$alcohol_kcal <- NA_real_
  }

  # Inside the logging-active window an absent sample means zero drinks.
  # Outside it, the value stays NA — see the note on the constant.
  sample_days <- as.numeric(sample_dates)
  active <- vapply(as.numeric(out$date), function(d) {
    any(abs(sample_days - d) <= active_window_days)
  }, logical(1))
  out$alcohol_logging_active <- active

  out$alcohol_units <- dplyr::if_else(
    active & is.na(out$alcohol_units), 0, out$alcohol_units)
  out$alcohol_night_units <- dplyr::if_else(
    active & is.na(out$alcohol_night_units), 0, out$alcohol_night_units)
  # A dry night has no energy to report, and 0 kcal is the honest value
  # there; a night with drinks but no app energy stays NA so the gram
  # figure can be flagged as computed rather than measured.
  dry <- !is.na(out$alcohol_night_units) & out$alcohol_night_units == 0
  out$alcohol_kcal <- dplyr::if_else(dry & is.na(out$alcohol_kcal), 0,
                                      out$alcohol_kcal)

  units <- out$alcohol_night_units
  kcal <- out$alcohol_kcal
  from_energy <- !is.na(kcal) & kcal > 0
  out$alcohol_grams <- dplyr::if_else(from_energy, kcal / .alcohol_kcal_per_g,
                                       NA_real_)
  # Fallback: no energy sample for a night that had drinks. The constant
  # is the app's documented default unit, and the result is flagged so no
  # caller can present it as the app's own figure.
  fallback <- !from_energy & !is.na(units) & units > 0
  out$alcohol_grams[fallback] <- units[fallback] * .alcohol_grams_per_unit()
  out$alcohol_grams[dry] <- 0
  out$alcohol_grams_estimated <- fallback

  # grams / count recovers the app's unit setting. Deviation is recorded
  # rather than swallowed: it means the setting changed, or a per-drink
  # calorie value was edited, and in both cases the numbers downstream
  # are not what they claim to be.
  out$alcohol_g_per_unit <- dplyr::if_else(
    !is.na(units) & units > 0 & !is.na(out$alcohol_grams),
    out$alcohol_grams / units, NA_real_)
  expected <- .alcohol_grams_per_unit()
  out$alcohol_unit_mismatch <- !is.na(out$alcohol_g_per_unit) &
    !out$alcohol_grams_estimated &
    abs(out$alcohol_g_per_unit - expected) / expected > .alcohol_unit_tolerance

  out |>
    dplyr::select("date", "alcohol_units", "alcohol_night_units",
                  "alcohol_kcal", "alcohol_grams", "alcohol_grams_estimated",
                  "alcohol_g_per_unit", "alcohol_unit_mismatch",
                  "alcohol_logging_active") |>
    dplyr::arrange(.data$date)
}

# --- Cache I/O ---------------------------------------------------------------

#' Load the cached alcohol night table
#'
#' @param cache_path Path to alcohol_nights.RData. Defaults to the file
#'   beside the health cache.
#' @return Tibble; empty (with the right columns) when no cache exists or
#'   TRANING_DATA is unset.
#' @export
load_alcohol_data <- function(cache_path = NULL) {
  if (is.null(cache_path)) {
    cache_path <- tryCatch(.alcohol_cache_path(), error = function(e) NULL)
  }
  if (is.null(cache_path) || !file.exists(cache_path)) {
    return(.empty_alcohol_nights())
  }
  alcohol_nights <- NULL
  loaded <- tryCatch({
    load(cache_path)
    alcohol_nights
  }, error = function(e) NULL)
  if (is.null(loaded) || !is.data.frame(loaded)) return(.empty_alcohol_nights())
  tibble::as_tibble(loaded)
}

#' Save the alcohol night table to cache
#'
#' @param alcohol_nights Tibble from \code{build_alcohol_nights()}.
#' @param cache_path Path to alcohol_nights.RData.
#' @return The path, invisibly.
#' @export
save_alcohol_data <- function(alcohol_nights, cache_path = NULL) {
  if (is.null(cache_path)) cache_path <- .alcohol_cache_path()
  cache_dir <- dirname(cache_path)
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  save_atomic(alcohol_nights, file = cache_path)
}

#' Rebuild the alcohol night table from canonical files
#'
#' Reads \code{canonical/alcohol_consumption/} and
#' \code{canonical/dietary_energy/} directly, so it sees the clock times
#' and per-sample sources that the health cache has thrown away.
#' Rebuilding is a full sweep rather than an incremental merge: the
#' derived values depend on neighbouring days (night attribution across
#' midnight, the logging-active window), so a partial update would leave
#' the table internally inconsistent.
#'
#' @param save Logical, write the cache. Default TRUE.
#' @param cache_path Path to alcohol_nights.RData. Default: beside the
#'   health cache.
#' @param canonical_dir Path to the canonical directory. Default:
#'   \code{$TRANING_DATA/kristian/health_export/canonical}.
#' @param verbose Logical, print progress. Default TRUE.
#' @return The night table, invisibly.
#' @export
import_alcohol <- function(save = TRUE, cache_path = NULL,
                            canonical_dir = NULL, verbose = TRUE) {
  if (is.null(canonical_dir)) {
    canonical_dir <- tryCatch(file.path(.hae_dir(), "canonical"),
                              error = function(e) NULL)
  }
  if (is.null(canonical_dir) || !dir.exists(canonical_dir)) {
    if (verbose) cat("Ingen canonical-katalog — hoppar over alkoholimport\n")
    return(invisible(.empty_alcohol_nights()))
  }

  samples <- .read_canonical_samples(
    file.path(canonical_dir, "alcohol_consumption"))
  if (nrow(samples) == 0) {
    if (verbose) cat("Inga alkoholsamples i canonical/\n")
    return(invisible(.empty_alcohol_nights()))
  }
  energy <- .read_canonical_samples(file.path(canonical_dir, "dietary_energy"))

  nights <- build_alcohol_nights(samples, energy)

  if (verbose) {
    logged <- sum(nights$alcohol_night_units > 0, na.rm = TRUE)
    cat("Alkohol:", nrow(samples), "samples,", nrow(nights), "dygn,",
        logged, "natter med registrerad alkohol\n")
  }
  # A unit-setting drift is never swallowed, whatever the verbosity: it
  # means every gram figure on those nights rests on a different
  # definition than the one this module assumes.
  mismatch <- nights[which(nights$alcohol_unit_mismatch), , drop = FALSE]
  if (nrow(mismatch) > 0) {
    message(sprintf(
      "Alkohol: %d natt(er) med avvikande gram per glas (vantat %s g, sett %s g). Kontrollera DrinkControls glasinstallning.",
      nrow(mismatch), format(.alcohol_grams_per_unit()),
      paste(unique(round(mismatch$alcohol_g_per_unit, 1)), collapse = ", ")))
  }
  if (save) {
    path <- if (is.null(cache_path)) .alcohol_cache_path() else cache_path
    save_alcohol_data(nights, path)
    if (verbose) cat("Sparad:", path, "\n")
  }
  invisible(nights)
}

#' Refresh the alcohol cache after a health import
#'
#' Failure here must never take the health import down with it: the
#' alcohol table is a derived convenience, health_daily.RData is not.
#'
#' @param health_cache_path Path to health_daily.RData, used to place the
#'   alcohol cache beside it.
#' @param verbose Logical.
#' @return TRUE when the table was rebuilt, FALSE otherwise.
#' @keywords internal
.refresh_alcohol_cache <- function(health_cache_path = NULL, verbose = FALSE) {
  res <- tryCatch({
    import_alcohol(save = TRUE,
                   cache_path = .alcohol_cache_path(health_cache_path),
                   verbose = verbose)
    TRUE
  }, error = function(e) {
    if (verbose) cat("Alkoholtabellen kunde inte byggas:", conditionMessage(e), "\n")
    FALSE
  })
  isTRUE(res)
}

# --- Energy ------------------------------------------------------------------

# HAE writes every energy metric on this device in kilojoules — verified
# in the canonical files for active_energy, basal_energy_burned and
# dietary_energy. The units field does not survive into health_daily, so
# the conversion here is by assumption; the plausibility guard below is
# what catches a device that ever starts writing kcal.
.kj_per_kcal <- 4.184

# A day's total expenditure has to land in this range to be usable as a
# denominator. Outside it the reading is wrong rather than unusual, and
# an implausible denominator produces a confidently wrong percentage.
.alcohol_tdee_plausible_kcal <- c(1000, 8000)

#' Total daily energy expenditure, in kcal
#'
#' Sum of active and basal energy from the Apple Watch. Basal energy is
#' modelled by Apple from age, sex, height and weight rather than
#' measured, which is why no user-facing text calls this a measurement.
#'
#' A day is only included when both halves are present: a day with
#' active energy but no basal figure is not a small expenditure day, it
#' is a partially worn watch, and averaging it in would drag the
#' denominator down.
#'
#' @param health_daily Long health tibble.
#' @return Tibble with \code{date} and \code{tdee_kcal}, ascending.
#' @keywords internal
.alcohol_daily_energy <- function(health_daily) {
  empty <- tibble::tibble(date = as.Date(character()), tdee_kcal = numeric())
  if (is.null(health_daily) || !is.data.frame(health_daily) ||
      nrow(health_daily) == 0 ||
      !all(c("date", "metric", "value") %in% names(health_daily))) {
    return(empty)
  }
  e <- health_daily[health_daily$metric %in%
                      c("active_energy", "basal_energy_burned"),
                    c("date", "metric", "value"), drop = FALSE]
  e <- e[!is.na(e$value), , drop = FALSE]
  if (nrow(e) == 0) return(empty)
  e$date <- as.Date(e$date)

  wide <- e |>
    dplyr::group_by(.data$date, .data$metric) |>
    dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop") |>
    tidyr::pivot_wider(names_from = "metric", values_from = "value")
  if (!all(c("active_energy", "basal_energy_burned") %in% names(wide))) {
    return(empty)
  }
  out <- wide |>
    dplyr::filter(!is.na(.data$active_energy),
                  !is.na(.data$basal_energy_burned)) |>
    dplyr::transmute(
      date = .data$date,
      tdee_kcal = (.data$active_energy + .data$basal_energy_burned) / .kj_per_kcal
    ) |>
    dplyr::filter(.data$tdee_kcal >= .alcohol_tdee_plausible_kcal[1],
                  .data$tdee_kcal <= .alcohol_tdee_plausible_kcal[2]) |>
    dplyr::arrange(.data$date)
  out
}

#' Trailing mean of daily expenditure
#'
#' The daily share is reported against a 28-day mean rather than that
#' day's own expenditure. A single day is dominated by whether a long run
#' happened, so a share against today's total would swing wildly for a
#' constant number of drinks, and the swing would be about the running.
#'
#' @param energy Tibble from \code{.alcohol_daily_energy()}.
#' @param dates Date vector to evaluate at.
#' @param window_days Length of the trailing window. Default 28.
#' @param min_days Days that must be present in it. Default 20.
#' @return Numeric vector, NA where the window is too thin.
#' @keywords internal
.alcohol_tdee_baseline <- function(energy, dates, window_days = 28,
                                    min_days = 20) {
  if (is.null(energy) || nrow(energy) == 0) return(rep(NA_real_, length(dates)))
  ed <- as.numeric(energy$date)
  ev <- energy$tdee_kcal
  vapply(as.numeric(dates), function(d) {
    vals <- ev[ed <= d & ed > d - window_days]
    if (length(vals) < min_days) return(NA_real_)
    mean(vals, na.rm = TRUE)
  }, numeric(1))
}

#' Dates where a Garmin session exists but the watch recorded rest-level energy
#'
#' On those days active energy undercounts, the denominator shrinks, and
#' the alcohol share is inflated on exactly the days most likely to be
#' read. The share is suppressed rather than printed inflated.
#'
#' @param summaries Session summaries, or NULL.
#' @param health_daily Long health tibble.
#' @param dates Date vector to evaluate.
#' @return Logical vector, TRUE where the day is untrustworthy.
#' @keywords internal
.alcohol_energy_contaminated <- function(summaries, health_daily, dates) {
  out <- rep(FALSE, length(dates))
  if (is.null(summaries) || !is.data.frame(summaries) ||
      nrow(summaries) == 0 || !"sessionStart" %in% names(summaries)) {
    return(out)
  }
  session_dates <- unique(as.Date(summaries$sessionStart))
  session_dates <- session_dates[!is.na(session_dates)]
  if (length(session_dates) == 0) return(out)
  for (i in seq_along(dates)) {
    d <- as.Date(dates[i])
    if (!(d %in% session_dates)) next
    verdict <- tryCatch(.day_energy_verdict(health_daily, d),
                        error = function(e) "insufficient")
    out[i] <- identical(verdict, "rest")
  }
  out
}

#' Per-night alcohol energy accounting
#'
#' Adds the derived energy columns to the night table: Swedish
#' standardglas, grams of ethanol, kcal (the app's own figure where it
#' exists, a flagged fallback where it does not) and the share of total
#' daily expenditure.
#'
#' The kcal figure is DrinkControl's own arithmetic on DrinkControl's own
#' unit definition, so it cannot drift out of step with the count the way
#' a constant on this side would the moment the app's standard-drink
#' setting changes. The fallback multiplies the count by the configured
#' grams per unit and the energy density of ethanol, and is flagged in
#' \code{alcohol_kcal_estimated} so no caller can present a computed
#' figure as a logged one.
#'
#' @param alcohol Night table from \code{build_alcohol_nights()} or
#'   \code{load_alcohol_data()}.
#' @param health_daily Long health tibble (needs active_energy and
#'   basal_energy_burned for the share).
#' @param summaries Optional session summaries, used to suppress the
#'   share on days where a Garmin session exists but the watch recorded
#'   rest-level energy.
#' @param window_days Trailing window for the expenditure mean. Default 28.
#' @param min_days Days required in that window. Default 20.
#' @return The night table with \code{alcohol_standardglas},
#'   \code{alcohol_grams}, \code{alcohol_kcal_estimated},
#'   \code{tdee_kcal_28d} and \code{alcohol_share} added.
#' @export
compute_alcohol_energy <- function(alcohol, health_daily = NULL,
                                    summaries = NULL,
                                    window_days = 28, min_days = 20) {
  if (is.null(alcohol) || nrow(alcohol) == 0) {
    out <- .empty_alcohol_nights()
    out$alcohol_standardglas <- numeric()
    out$alcohol_kcal_estimated <- logical()
    out$tdee_kcal_28d <- numeric()
    out$alcohol_share <- numeric()
    return(out)
  }
  alcohol <- tibble::as_tibble(alcohol)
  units <- alcohol$alcohol_night_units

  # Swedish standardglas are twelve grams. Display only: the stored
  # quantity is grams, so a changed app setting never rewrites history.
  alcohol$alcohol_standardglas <- alcohol$alcohol_grams /
    .alcohol_g_per_standardglas

  # Fallback only where drinks were logged but the app wrote no energy.
  # The grams behind it were already flagged as estimated at import.
  needs_fallback <- !is.na(units) & units > 0 & is.na(alcohol$alcohol_kcal)
  alcohol$alcohol_kcal_estimated <- needs_fallback
  alcohol$alcohol_kcal[needs_fallback] <-
    alcohol$alcohol_grams[needs_fallback] * .alcohol_kcal_per_g

  energy <- .alcohol_daily_energy(health_daily)
  alcohol$tdee_kcal_28d <- .alcohol_tdee_baseline(
    energy, alcohol$date, window_days = window_days, min_days = min_days)

  contaminated <- .alcohol_energy_contaminated(summaries, health_daily,
                                                alcohol$date)
  share <- alcohol$alcohol_kcal / alcohol$tdee_kcal_28d
  share[contaminated] <- NA_real_
  share[!is.finite(share)] <- NA_real_
  alcohol$alcohol_share <- share

  alcohol
}

#' Weekly alcohol energy summary
#'
#' The weekly line uses that week's actual summed expenditure rather than
#' a rolling mean: a week averages out the session lumpiness on its own,
#' and the reader is asking about that specific week.
#'
#' @param alcohol Night table, already through
#'   \code{compute_alcohol_energy()} or raw (it is run through it here
#'   when the derived columns are absent).
#' @param health_daily Long health tibble.
#' @param summaries Optional session summaries.
#' @param min_days_in_week Days of expenditure data required before a
#'   weekly share is reported. Default 5 of 7.
#' @return Tibble, one row per ISO week: \code{iso_week},
#'   \code{week_start}, \code{units}, \code{standardglas},
#'   \code{grams}, \code{kcal}, \code{drinking_days}, \code{dry_days},
#'   \code{week_tdee_kcal}, \code{share}.
#' @export
compute_alcohol_week <- function(alcohol, health_daily = NULL,
                                  summaries = NULL, min_days_in_week = 5) {
  empty <- tibble::tibble(
    iso_week = character(), week_start = as.Date(character()),
    units = numeric(), standardglas = numeric(), grams = numeric(),
    kcal = numeric(), drinking_days = integer(), dry_days = integer(),
    week_tdee_kcal = numeric(), share = numeric()
  )
  if (is.null(alcohol) || nrow(alcohol) == 0) return(empty)
  if (!"alcohol_share" %in% names(alcohol)) {
    alcohol <- compute_alcohol_energy(alcohol, health_daily, summaries)
  }

  # Nights outside a logging-active stretch carry no information and are
  # dropped rather than counted as dry.
  keep <- !is.na(alcohol$alcohol_logging_active) &
    alcohol$alcohol_logging_active
  a <- alcohol[keep, , drop = FALSE]
  if (nrow(a) == 0) return(empty)

  # The week is a week of EVENINGS, so it is keyed by the drinking date,
  # which is the morning date minus one. Grouping on the morning splits a
  # Sunday-evening session out of the week it happened in and into the
  # next one, which the Monday recap has already reported. The prose says
  # "kvällar", and this is the quantity that word names.
  a$drink_date <- a$date - 1L
  a$iso_week <- format(a$drink_date, "%G-W%V")

  energy <- .alcohol_daily_energy(health_daily)
  energy$iso_week <- format(energy$date, "%G-W%V")
  week_energy <- energy |>
    dplyr::group_by(.data$iso_week) |>
    dplyr::summarise(
      week_tdee_kcal = sum(.data$tdee_kcal, na.rm = TRUE),
      n_days = dplyr::n(),
      .groups = "drop"
    )
  week_energy$week_tdee_kcal[week_energy$n_days < min_days_in_week] <- NA_real_

  out <- a |>
    dplyr::group_by(.data$iso_week) |>
    dplyr::summarise(
      week_start    = min(.data$drink_date),
      units         = sum(.data$alcohol_night_units, na.rm = TRUE),
      standardglas  = sum(.data$alcohol_standardglas, na.rm = TRUE),
      grams         = sum(.data$alcohol_grams, na.rm = TRUE),
      kcal          = sum(.data$alcohol_kcal, na.rm = TRUE),
      drinking_days = sum(!is.na(.data$alcohol_night_units) &
                            .data$alcohol_night_units > 0),
      dry_days      = sum(!is.na(.data$alcohol_night_units) &
                            .data$alcohol_night_units == 0),
      .groups = "drop"
    ) |>
    dplyr::left_join(week_energy[, c("iso_week", "week_tdee_kcal")],
                     by = "iso_week")

  out$share <- out$kcal / out$week_tdee_kcal
  out$share[!is.finite(out$share)] <- NA_real_
  out |> dplyr::arrange(dplyr::desc(.data$week_start))
}

# --- Alcohol-free baseline ---------------------------------------------------

# Rolling window for the alcohol-free baseline. A compromise: long
# enough to stabilise a median, short enough that fitness drift does not
# accumulate inside it.
.alcohol_baseline_window_days <- 42L

# Below this many qualifying nights the comparison is not printed at all
# rather than printed from a thin reference.
.alcohol_baseline_min_nights <- 14L

# Robust z beyond which a measure is worth a sentence.
#
# One robust standard deviation is far too low. Under the null a
# one-sided z >= 1 fires on 15.9 % of mornings per measure, and with
# three measures tested independently at least one fires on about 40 %
# of them (somewhat less in practice, since the three are correlated).
# The sentence only ever appears after a drinking evening, so every
# false flag reads as evidence for a causal story the reader is already
# primed to believe — which is exactly what gating on the signal was
# supposed to prevent.
#
# At 1.5 the per-measure rate is 6.7 % and the family rate about 19 %,
# roughly one morning in five. One threshold for all three rather than a
# lower bar for resting heart rate: the effect-size difference is
# already expressed in the order the measures are named, and a
# per-measure knob would be a tuning parameter with nothing to tune it
# against. The spread behind the z is a median absolute deviation from
# as few as 14 nights, so the denominator is noisy in both directions
# and a tighter threshold is the cheaper error.
.alcohol_deviation_z <- 1.5

# Illness thresholds, reused from the tier-1 update thresholds so the
# two surfaces cannot drift into two readings of "elevated".
.alcohol_illness_wrist_temp <- 0.4   # degC above the trailing 14d median
.alcohol_illness_resp_rate  <- 2     # breaths/min above the trailing 7d mean

#' Robust centre and spread of a numeric vector
#'
#' Median and MAD rather than mean and SD: one very bad night must not
#' be able to move the reference the rest of the nights are compared to.
#'
#' @param x Numeric vector.
#' @return List with \code{center}, \code{spread}, \code{n}.
#' @keywords internal
.robust_stats <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(list(center = NA_real_, spread = NA_real_, n = 0L))
  s <- stats::mad(x, constant = 1.4826)
  list(center = stats::median(x), spread = if (is.finite(s) && s > 0) s else NA_real_,
       n = length(x))
}

#' Dates that look like illness and are excluded from the baseline
#'
#' Two signals, both already used elsewhere for the same purpose: a
#' sleeping wrist temperature well above its own trailing median, and a
#' respiratory rate well above its trailing mean. A night spent fighting
#' something off is not a representative alcohol-free night.
#'
#' @param health_daily Long health tibble.
#' @return Date vector of flagged days (possibly empty).
#' @keywords internal
.alcohol_illness_dates <- function(health_daily) {
  none <- as.Date(character())
  if (is.null(health_daily) || !is.data.frame(health_daily) ||
      nrow(health_daily) == 0) {
    return(none)
  }
  flagged <- none

  series <- function(metric) {
    s <- health_daily[health_daily$metric == metric, c("date", "value"),
                      drop = FALSE]
    s <- s[!is.na(s$value), , drop = FALSE]
    if (nrow(s) == 0) return(NULL)
    s$date <- as.Date(s$date)
    s[order(s$date), , drop = FALSE]
  }

  wt <- series("apple_sleeping_wrist_temperature")
  if (!is.null(wt) && nrow(wt) >= 4) {
    for (i in seq_len(nrow(wt))) {
      win <- wt$value[wt$date < wt$date[i] & wt$date >= wt$date[i] - 14]
      if (length(win) < 3) next
      if (wt$value[i] - stats::median(win) > .alcohol_illness_wrist_temp) {
        flagged <- c(flagged, wt$date[i])
      }
    }
  }

  rr <- series("respiratory_rate")
  if (!is.null(rr) && nrow(rr) >= 4) {
    for (i in seq_len(nrow(rr))) {
      win <- rr$value[rr$date < rr$date[i] & rr$date >= rr$date[i] - 7]
      if (length(win) < 3) next
      if (rr$value[i] - mean(win) > .alcohol_illness_resp_rate) {
        flagged <- c(flagged, rr$date[i])
      }
    }
  }

  sort(unique(flagged))
}

# The three measures compared against the alcohol-free baseline. `sign`
# is the direction that counts as adverse: -1 when lower is worse.
#
# Order matters: it is the order the measures are named in the prose,
# and it runs by descending standardized effect size rather than by
# habit. Grosicki et al. (2026) report 0.61 in females and 0.52 in males
# for resting heart rate per drink above personal average, against 0.30
# and 0.26 for HRV. Resting heart rate is the larger and better-resolved
# signal, so it leads. Sleep duration is last but is a real outcome, not
# a control: the same cohort found duration declining progressively with
# intake.
.alcohol_measures <- list(
  rhr = list(metric = "resting_heart_rate", label = "vilopuls",
             unit = "slag", digits = 0, scale = 1, log = FALSE, sign = 1),
  hrv = list(metric = "heart_rate_variability", label = "HRV",
             unit = "ms", digits = 0, scale = 1, log = TRUE, sign = -1),
  sleep = list(metric = "sleep_totalSleep", label = "sömn",
               unit = "minuter", digits = 0, scale = 60, log = FALSE, sign = -1)
)

#' Alcohol-free baseline for HRV, resting heart rate and sleep
#'
#' Median over the alcohol-free nights in a rolling window, excluding
#' illness-flagged days. This is a descriptive reference for a daily
#' line, not a causal estimate: alcohol-free nights skew towards
#' weekdays, so nothing that generalises may rest on it.
#'
#' The readiness baselines are deliberately left alone. Those are
#' unconditional descriptions of recent state, and that is correct for
#' their purpose: after four nights of drinking, readiness should reflect
#' that the body is in fact in a degraded state.
#'
#' @param health_daily Long health tibble.
#' @param alcohol Night table (needs \code{alcohol_night_units} and
#'   \code{alcohol_logging_active}).
#' @param on_date Date to build the baseline for. Default: latest night.
#' @param window_days Rolling window length. Default 42.
#' @param min_nights Qualifying nights required. Default 14.
#' @return List with one entry per measure
#'   (\code{center}, \code{spread}, \code{n}, on the reported scale) plus
#'   \code{n_nights} and \code{on_date}. Entries are NA when the window
#'   is too thin.
#' @export
compute_alcohol_baseline <- function(health_daily, alcohol, on_date = NULL,
                                      window_days = .alcohol_baseline_window_days,
                                      min_nights = .alcohol_baseline_min_nights) {
  empty <- list(on_date = as.Date(NA), n_nights = 0L)
  for (nm in names(.alcohol_measures)) {
    empty[[nm]] <- list(center = NA_real_, spread = NA_real_, n = 0L)
  }
  if (is.null(alcohol) || nrow(alcohol) == 0 ||
      is.null(health_daily) || nrow(health_daily) == 0) {
    return(empty)
  }
  alcohol <- tibble::as_tibble(alcohol)
  if (is.null(on_date)) on_date <- max(alcohol$date, na.rm = TRUE)
  on_date <- as.Date(on_date)
  empty$on_date <- on_date

  dry <- alcohol$date[
    !is.na(alcohol$alcohol_night_units) & alcohol$alcohol_night_units == 0 &
      !is.na(alcohol$alcohol_logging_active) & alcohol$alcohol_logging_active &
      alcohol$date < on_date & alcohol$date >= on_date - window_days
  ]
  dry <- setdiff(as.character(dry), as.character(.alcohol_illness_dates(health_daily)))
  dry <- as.Date(dry)
  if (length(dry) < min_nights) {
    empty$n_nights <- length(dry)
    return(empty)
  }

  out <- list(on_date = on_date, n_nights = length(dry))
  hd <- health_daily
  hd$date <- as.Date(hd$date)
  for (nm in names(.alcohol_measures)) {
    spec <- .alcohol_measures[[nm]]
    vals <- hd$value[hd$metric == spec$metric & hd$date %in% dry]
    vals <- vals[is.finite(vals)] * spec$scale
    # The gate runs on the log scale for HRV: RMSSD is close to
    # log-normal, so a symmetric threshold on the raw scale would treat
    # a fall and a rise of the same size as equally unusual when they
    # are not.
    stats_raw <- .robust_stats(vals)
    stats_gate <- if (isTRUE(spec$log)) .robust_stats(log(vals[vals > 0])) else stats_raw
    out[[nm]] <- list(center = stats_raw$center, spread = stats_raw$spread,
                       n = stats_raw$n,
                       gate_center = stats_gate$center,
                       gate_spread = stats_gate$spread)
  }
  out
}

#' Deviation of one morning from the alcohol-free baseline
#'
#' @param health_daily Long health tibble.
#' @param alcohol Night table.
#' @param on_date Morning to evaluate.
#' @param baseline Optional precomputed baseline from
#'   \code{compute_alcohol_baseline()}.
#' @param z_threshold Robust z beyond which a measure is flagged.
#'   Default 1.5.
#' @param ... Passed to \code{compute_alcohol_baseline()}.
#' @return Tibble with one row per measure: \code{measure},
#'   \code{label}, \code{unit}, \code{value}, \code{baseline},
#'   \code{delta}, \code{z}, \code{flagged}. Measures with no reading
#'   are dropped rather than carried as placeholders.
#' @export
compute_alcohol_deviation <- function(health_daily, alcohol, on_date = NULL,
                                       baseline = NULL,
                                       z_threshold = .alcohol_deviation_z,
                                       ...) {
  empty <- tibble::tibble(
    measure = character(), label = character(), unit = character(),
    value = numeric(), baseline = numeric(), delta = numeric(),
    z = numeric(), flagged = logical()
  )
  if (is.null(health_daily) || nrow(health_daily) == 0) return(empty)
  if (is.null(baseline)) {
    baseline <- compute_alcohol_baseline(health_daily, alcohol,
                                          on_date = on_date, ...)
  }
  on_date <- if (is.null(on_date)) baseline$on_date else as.Date(on_date)
  if (is.na(on_date) || baseline$n_nights == 0L) return(empty)

  hd <- health_daily
  hd$date <- as.Date(hd$date)
  rows <- lapply(names(.alcohol_measures), function(nm) {
    spec <- .alcohol_measures[[nm]]
    b <- baseline[[nm]]
    if (is.null(b) || !is.finite(b$center)) return(NULL)
    v <- hd$value[hd$metric == spec$metric & hd$date == on_date]
    v <- v[is.finite(v)]
    if (length(v) == 0) return(NULL)
    v <- mean(v) * spec$scale

    gate_v <- if (isTRUE(spec$log)) {
      if (v > 0) log(v) else NA_real_
    } else v
    z <- if (is.finite(gate_v) && is.finite(b$gate_center) &&
             is.finite(b$gate_spread)) {
      (gate_v - b$gate_center) / b$gate_spread
    } else NA_real_

    tibble::tibble(
      measure = nm, label = spec$label, unit = spec$unit,
      value = v, baseline = b$center, delta = v - b$center,
      z = z,
      flagged = is.finite(z) && (z * spec$sign) >= z_threshold
    )
  })
  out <- dplyr::bind_rows(rows)
  if (nrow(out) == 0) return(empty)
  out
}

# --- Prose -------------------------------------------------------------------

#' Format a kcal figure for Swedish prose
#'
#' Whole kilocalories with a space as thousands separator. False
#' precision is worse than none here: the input is a self-reported drink
#' count run through an app's constant.
#'
#' @param x Numeric.
#' @return Character scalar, NA_character_ when x is not finite.
#' @keywords internal
.fmt_kcal <- function(x) {
  if (!is.finite(x)) return(NA_character_)
  format(round(x), big.mark = " ", trim = TRUE, scientific = FALSE)
}

#' Render the deviation table as a Swedish clause list
#'
#' Only flagged measures are named. Measures without a reading are left
#' out entirely rather than carried as a placeholder.
#'
#' @param dev Tibble from \code{compute_alcohol_deviation()}.
#' @return Character vector of clauses (possibly empty).
#' @keywords internal
.alcohol_deviation_clauses <- function(dev) {
  if (is.null(dev) || nrow(dev) == 0) return(character())
  flagged <- dev[!is.na(dev$flagged) & dev$flagged, , drop = FALSE]
  if (nrow(flagged) == 0) return(character())
  vapply(seq_len(nrow(flagged)), function(i) {
    r <- flagged[i, ]
    if (identical(r$measure, "hrv")) {
      sprintf("HRV %s ms mot %s på alkoholfria nätter",
              fmt_dec_sv(r$value, digits = 0, trim_zero = TRUE),
              fmt_dec_sv(r$baseline, digits = 0, trim_zero = TRUE))
    } else {
      direction <- if (identical(r$measure, "sleep")) {
        if (r$delta < 0) "kortare" else "längre"
      } else {
        if (r$delta > 0) "högre" else "lägre"
      }
      sprintf("%s %s %s %s", r$label,
              fmt_dec_sv(abs(r$delta), digits = 0, trim_zero = TRUE),
              r$unit, direction)
    }
  }, character(1))
}

#' Daily alcohol line for the morning notification
#'
#' Attached additively to the morning push, not routed through the
#' single-slot context chain: the energy figure is due after every logged
#' evening, and as a candidate there it would fall silent whenever a
#' training-state line had something to say.
#'
#' Energy the morning after a logged evening, plus a recovery comparison
#' only when at least one measure clears the gate. When nothing moved,
#' the line says so plainly: an honest null is the most trust-building
#' output this feature can produce, and a sentence that only ever appears
#' when something looks bad reads as an accusation hunting for evidence.
#'
#' Silent at zero drinks (praise for abstinence is moralising through the
#' back door, and it would put an alcohol line in the notification every
#' day of the year) and silent outside a logging-active stretch, where an
#' absent sample means nothing was logged rather than nothing was drunk.
#' No imperatives: the moment the text prescribes, it is a scold, and a
#' scold is a strong reason to stop logging.
#'
#' @param alcohol Night table, raw or already through
#'   \code{compute_alcohol_energy()}.
#' @param health_daily Long health tibble.
#' @param on_date Morning to render.
#' @param summaries Optional session summaries, for the share guard.
#' @return Character scalar, or NULL when there is nothing to say.
#' @keywords internal
.insight_alcohol_line <- function(alcohol, health_daily, on_date,
                                   summaries = NULL) {
  if (is.null(alcohol) || nrow(alcohol) == 0) return(NULL)
  on_date <- as.Date(on_date)
  if (!"alcohol_share" %in% names(alcohol)) {
    alcohol <- compute_alcohol_energy(alcohol, health_daily, summaries)
  }
  row <- alcohol[!is.na(alcohol$date) & alcohol$date == on_date, , drop = FALSE]
  if (nrow(row) != 1L) return(NULL)
  if (!isTRUE(row$alcohol_logging_active)) return(NULL)

  units <- row$alcohol_night_units
  if (!is.finite(units) || units <= 0) return(NULL)

  glas <- fmt_dec_sv(units, digits = 1, trim_zero = TRUE)
  standard <- fmt_dec_sv(row$alcohol_standardglas, digits = 1, trim_zero = TRUE)
  parts <- sprintf("I går: %s glas (%s standardglas)", glas, standard)

  kcal <- row$alcohol_kcal
  if (is.finite(kcal)) {
    suffix <- if (isTRUE(row$alcohol_kcal_estimated)) " (beräknat)" else ""
    parts <- paste0(parts, sprintf(", %s kcal från alkoholen%s.",
                                   .fmt_kcal(kcal), suffix))
  } else {
    parts <- paste0(parts, ".")
  }

  share <- row$alcohol_share
  if (is.finite(share)) {
    parts <- paste0(parts, sprintf(
      " Det motsvarar %d procent av din genomsnittliga dygnsförbrukning.",
      as.integer(round(share * 100))))
  }

  dev <- tryCatch(
    compute_alcohol_deviation(health_daily, alcohol, on_date = on_date),
    error = function(e) NULL
  )
  if (!is.null(dev) && nrow(dev) > 0) {
    clauses <- .alcohol_deviation_clauses(dev)
    if (length(clauses) > 0) {
      parts <- paste0(parts, " I dag: ", paste(clauses, collapse = ", "), ".")
    } else {
      present <- dev$label[dev$measure %in% c("rhr", "hrv")]
      if (length(present) > 0) {
        subject <- paste(present, collapse = " och ")
        parts <- paste0(parts, sprintf(
          " I dag: %s ligger på dina normala nivåer.", subject))
      }
    }
  }
  parts
}

#' Weekly alcohol line for the Monday recap
#'
#' Reports the week that just ended, alongside the training recap.
#' Silent when no drinks were logged in it, and silent when the week's
#' expenditure data is too thin for a share (the kcal and the evening
#' count still stand on their own).
#'
#' @param alcohol Night table.
#' @param health_daily Long health tibble.
#' @param on_date Date being rendered; the recap covers the previous week.
#' @param summaries Optional session summaries.
#' @return Character scalar, or NULL.
#' @keywords internal
.alcohol_weekly_line <- function(alcohol, health_daily, on_date,
                                  summaries = NULL) {
  if (is.null(alcohol) || nrow(alcohol) == 0) return(NULL)
  on_date <- as.Date(on_date)
  if (as.POSIXlt(on_date)$wday != 1L) return(NULL)

  target <- format(on_date - 7, "%G-W%V")
  weeks <- tryCatch(
    compute_alcohol_week(alcohol, health_daily, summaries),
    error = function(e) NULL
  )
  if (is.null(weeks) || nrow(weeks) == 0) return(NULL)
  w <- weeks[weeks$iso_week == target, , drop = FALSE]
  if (nrow(w) != 1L) return(NULL)
  if (!is.finite(w$drinking_days) || w$drinking_days == 0) return(NULL)

  kvall <- if (w$drinking_days == 1) "kväll" else "kvällar"
  line <- sprintf(
    "Förra veckan: alkohol stod för %s kcal, fördelat på %d %s.",
    .fmt_kcal(w$kcal), as.integer(w$drinking_days), kvall)
  if (is.finite(w$share)) {
    line <- paste0(line, sprintf(
      " Det motsvarar %d procent av veckans energiförbrukning.",
      as.integer(round(w$share * 100))))
  }
  if (is.finite(w$dry_days) && w$dry_days > 0) {
    dag <- if (w$dry_days == 1) "alkoholfri dag" else "alkoholfria dagar"
    line <- paste0(line, sprintf(" %d %s.", as.integer(w$dry_days), dag))
  }
  line
}

# --- Reports -----------------------------------------------------------------

#' Resolve an after/before argument to a Date
#'
#' Accepts a Date, or any expression \code{parse_date_expr()} handles
#' ("2026", "2026-08", "-6m"), so the MCP layer can pass through what the
#' rest of the tool surface already accepts.
#'
#' @param x Date, character or NULL.
#' @return Date or NULL.
#' @keywords internal
.alcohol_as_date <- function(x) {
  if (is.null(x)) return(NULL)
  if (inherits(x, "Date")) return(x)
  if (is.character(x) && length(x) == 1L && nzchar(x)) {
    return(tryCatch(parse_date_expr(x), error = function(e) as.Date(x)))
  }
  as.Date(x)
}

#' Daily alcohol report
#'
#' One row per night inside a logging-active stretch: drinks in both
#' units, energy, the share of average daily expenditure, and the
#' morning's deviation from the alcohol-free baseline. Newest first.
#'
#' Nights outside a logging-active stretch are dropped rather than shown
#' as zeros: there, an absent sample means nothing was logged, which is
#' not the same as nothing was drunk.
#'
#' @param data A traning_data bundle (or, via the legacy shim, a bare
#'   summaries data.frame with \code{health_daily = ...} folded in).
#' @param after Start date (inclusive). Date or expression. NULL = no bound.
#' @param before End date (inclusive). Date or expression. NULL = no bound.
#' @param alcohol Optional night table; defaults to the cached one.
#' @return Tibble with Swedish column names, newest first.
#' @export
report_alcohol <- function(data, after = NULL, before = NULL,
                            alcohol = NULL) {
  td <- .as_traning_data(data)
  health_daily <- td@health_daily
  summaries <- td@summaries
  if (is.null(alcohol)) {
    alcohol <- tryCatch(load_alcohol_data(), error = function(e) NULL)
  }
  empty <- tibble::tibble(
    Datum = as.Date(character()), Glas = numeric(),
    Standardglas = numeric(), Gram = numeric(), kcal = numeric(),
    "Andel %" = numeric(), "HRV avvik" = numeric(), "VP avvik" = numeric(),
    "Sömn avvik" = numeric(), "Beräknad kcal" = logical(),
    "Avvikande enhet" = logical()
  )
  if (is.null(alcohol) || nrow(alcohol) == 0) return(empty)

  a <- compute_alcohol_energy(alcohol, health_daily, summaries)
  a <- a[!is.na(a$alcohol_logging_active) & a$alcohol_logging_active, ,
         drop = FALSE]
  a <- filter_by_daterange(a,
                           list(from = .alcohol_as_date(after),
                                to = .alcohol_as_date(before)),
                           date_col = "date", closed_upper = TRUE)
  if (nrow(a) == 0) return(empty)

  # Deviations are computed per row, and only for the rows that survive
  # the window filter — each one needs its own trailing baseline.
  dev_col <- function(measure) {
    vapply(a$date, function(d) {
      dv <- tryCatch(
        compute_alcohol_deviation(health_daily, alcohol, on_date = d),
        error = function(e) NULL
      )
      if (is.null(dv) || nrow(dv) == 0) return(NA_real_)
      hit <- dv$delta[dv$measure == measure]
      if (length(hit) == 0) NA_real_ else hit[[1]]
    }, numeric(1))
  }

  out <- tibble::tibble(
    Datum             = a$date,
    Glas              = round(a$alcohol_night_units, 1),
    Standardglas      = round(a$alcohol_standardglas, 1),
    Gram              = round(a$alcohol_grams, 1),
    kcal              = round(a$alcohol_kcal),
    `Andel %`         = round(a$alcohol_share * 100, 1),
    `HRV avvik`       = round(dev_col("hrv"), 1),
    `VP avvik`        = round(dev_col("rhr"), 1),
    `Sömn avvik`      = round(dev_col("sleep")),
    `Beräknad kcal`   = a$alcohol_kcal_estimated,
    `Avvikande enhet` = a$alcohol_unit_mismatch
  )
  dplyr::arrange(out, dplyr::desc(.data$Datum))
}

#' Weekly alcohol report
#'
#' One row per ISO week, newest first. The share uses that week's own
#' summed expenditure rather than a rolling mean.
#'
#' @inheritParams report_alcohol
#' @return Tibble with Swedish column names, newest first.
#' @export
report_alcohol_weekly <- function(data, after = NULL, before = NULL,
                                   alcohol = NULL) {
  td <- .as_traning_data(data)
  health_daily <- td@health_daily
  summaries <- td@summaries
  if (is.null(alcohol)) {
    alcohol <- tryCatch(load_alcohol_data(), error = function(e) NULL)
  }
  empty <- tibble::tibble(
    Vecka = character(), Start = as.Date(character()), Glas = numeric(),
    Standardglas = numeric(), Gram = numeric(), kcal = numeric(),
    "Andel %" = numeric(), "Kvällar" = integer(),
    "Alkoholfria dagar" = integer()
  )
  if (is.null(alcohol) || nrow(alcohol) == 0) return(empty)

  w <- compute_alcohol_week(alcohol, health_daily, summaries)
  if (nrow(w) == 0) return(empty)
  w <- filter_by_daterange(w,
                           list(from = .alcohol_as_date(after),
                                to = .alcohol_as_date(before)),
                           date_col = "week_start", closed_upper = TRUE)
  if (nrow(w) == 0) return(empty)

  tibble::tibble(
    Vecka                = w$iso_week,
    Start                = w$week_start,
    Glas                 = round(w$units, 1),
    Standardglas         = round(w$standardglas, 1),
    Gram                 = round(w$grams, 1),
    kcal                 = round(w$kcal),
    `Andel %`            = round(w$share * 100, 1),
    `Kvällar`       = as.integer(w$drinking_days),
    `Alkoholfria dagar`  = as.integer(w$dry_days)
  ) |>
    dplyr::arrange(dplyr::desc(.data$Start))
}
