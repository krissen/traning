# HR zone distribution and Polarization Index
#
# Implements the Seiler 3-zone model and the Treff (2019) Polarization Index.
# Two data sources are supported:
#   1. Garmin JSON hrTimeInZone columns (fast; Dec 2024+ only)
#   2. Per-second HR from myruns trackeRdata objects (slow; full history)
#
# Seiler 3-zone mapping:
#   Z1 (Low / Lågintensiv):   < 80% HRmax  — Garmin Z1 + Z2
#   Z2 (Moderate / Tröskel):  80–90% HRmax — Garmin Z3
#   Z3 (High / Högintensiv):  >= 90% HRmax — Garmin Z4 + Z5

# Internal helper: validate that the required Garmin zone columns are present.
# Returns TRUE if all five columns exist, FALSE otherwise.
.has_garmin_zones <- function(summaries) {
  zone_cols <- paste0("garmin_hrTimeInZone_", 1:5)
  all(zone_cols %in% names(summaries))
}

# Internal helper: compute Seiler 3-zone proportions from a row of zone seconds.
# Returns a named list: z1_pct, z2_pct, z3_pct (0–100 scale).
# total_sec must be > 0.
.seiler_pct <- function(z1_sec, z2_sec, z3_sec, total_sec) {
  list(
    z1_pct = 100 * z1_sec / total_sec,
    z2_pct = 100 * z2_sec / total_sec,
    z3_pct = 100 * z3_sec / total_sec
  )
}

#' Compute HR zone distribution from Garmin JSON hrTimeInZone data
#'
#' Maps Garmin's built-in 5-zone scheme to the research-standard Seiler 3-zone
#' model and returns per-activity and monthly aggregations.  Requires that
#' \code{summaries} has been enriched by \code{augment_summaries()} so that the
#' \code{garmin_hrTimeInZone_1} through \code{garmin_hrTimeInZone_5} columns are
#' present (available for activities imported from Garmin Connect JSON, typically
#' from December 2024 onward).
#'
#' Seiler zone mapping:
#' \itemize{
#'   \item Z1 (Lågintensiv): Garmin Z1 + Z2 (\eqn{<} VT1, approx. \eqn{<} 80\% HRmax)
#'   \item Z2 (Tröskel): Garmin Z3 (VT1–VT2, approx. 80–90\% HRmax)
#'   \item Z3 (Högintensiv): Garmin Z4 + Z5 (\eqn{\ge} VT2, approx. \eqn{\ge} 90\% HRmax)
#' }
#'
#' The \code{vt1_pct} and \code{vt2_pct} parameters are informational only for
#' this function — the actual zone boundaries are determined by Garmin's firmware
#' (usually set to the user's configured HR zones).  They are accepted so that
#' both compute functions share the same signature and can be compared via
#' \code{cross_validate_zones()}.
#'
#' @param summaries Enriched summaries tibble (must contain
#'   \code{garmin_hrTimeInZone_1} through \code{garmin_hrTimeInZone_5}).
#' @param hr_max Numeric. HRmax in bpm. Informational; \code{NULL} = ignored.
#' @param vt1_pct Numeric (0–1). VT1 as fraction of HRmax (default 0.80).
#'   Informational only for this function.
#' @param vt2_pct Numeric (0–1). VT2 as fraction of HRmax (default 0.90).
#'   Informational only for this function.
#' @return Named list with two elements:
#'   \describe{
#'     \item{\code{$per_activity}}{Tibble with one row per qualifying run:
#'       \code{sessionStart} (Date), \code{distance_km}, \code{z1_pct},
#'       \code{z2_pct}, \code{z3_pct}, \code{z1_sec}, \code{z2_sec},
#'       \code{z3_sec}, \code{total_sec}.}
#'     \item{\code{$monthly}}{Tibble with monthly aggregates:
#'       \code{year_month}, \code{z1_pct}, \code{z2_pct}, \code{z3_pct},
#'       \code{n_activities}, \code{total_min}.}
#'   }
#' @export
compute_zone_distribution <- function(summaries,
                                      hr_max    = NULL,
                                      vt1_pct   = 0.80,
                                      vt2_pct   = 0.90) {
  if (!.has_garmin_zones(summaries)) {
    stop(
      "summaries saknar garmin_hrTimeInZone-kolumner. ",
      "Kör augment_summaries() med Garmin Connect JSON-data först."
    )
  }

  zone_cols <- paste0("garmin_hrTimeInZone_", 1:5)

  runs <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, "running")) %>%
    # Behåll bara rader där samtliga fem zon-kolumner är icke-NA
    dplyr::filter(dplyr::if_all(dplyr::all_of(zone_cols), ~ !is.na(.x))) %>%
    dplyr::mutate(
      sessionStart = as.Date(sessionStart),
      distance_km  = distance / 1000,
      # Seiler Z1 = Garmin Z1 + Z2
      z1_sec   = as.numeric(garmin_hrTimeInZone_1) +
                 as.numeric(garmin_hrTimeInZone_2),
      # Seiler Z2 = Garmin Z3
      z2_sec   = as.numeric(garmin_hrTimeInZone_3),
      # Seiler Z3 = Garmin Z4 + Z5
      z3_sec   = as.numeric(garmin_hrTimeInZone_4) +
                 as.numeric(garmin_hrTimeInZone_5),
      total_sec = z1_sec + z2_sec + z3_sec
    ) %>%
    dplyr::filter(total_sec > 0) %>%
    dplyr::mutate(
      z1_pct = 100 * z1_sec / total_sec,
      z2_pct = 100 * z2_sec / total_sec,
      z3_pct = 100 * z3_sec / total_sec
    ) %>%
    dplyr::arrange(sessionStart)

  if (nrow(runs) == 0) {
    empty_activity <- tibble::tibble(
      sessionStart = as.Date(character(0)),
      distance_km  = numeric(0),
      z1_pct       = numeric(0),
      z2_pct       = numeric(0),
      z3_pct       = numeric(0),
      z1_sec       = numeric(0),
      z2_sec       = numeric(0),
      z3_sec       = numeric(0),
      total_sec    = numeric(0)
    )
    empty_monthly <- tibble::tibble(
      year_month   = character(0),
      z1_pct       = numeric(0),
      z2_pct       = numeric(0),
      z3_pct       = numeric(0),
      n_activities = integer(0),
      total_min    = numeric(0)
    )
    return(list(per_activity = empty_activity, monthly = empty_monthly))
  }

  per_activity <- runs %>%
    dplyr::select(
      sessionStart, distance_km,
      z1_pct, z2_pct, z3_pct,
      z1_sec, z2_sec, z3_sec, total_sec
    )

  monthly <- runs %>%
    dplyr::mutate(
      year_month = format(sessionStart, "%Y-%m")
    ) %>%
    dplyr::group_by(year_month) %>%
    dplyr::summarise(
      z1_sec_sum   = sum(z1_sec, na.rm = TRUE),
      z2_sec_sum   = sum(z2_sec, na.rm = TRUE),
      z3_sec_sum   = sum(z3_sec, na.rm = TRUE),
      total_sec    = sum(total_sec, na.rm = TRUE),
      n_activities = dplyr::n(),
      .groups      = "drop"
    ) %>%
    dplyr::filter(total_sec > 0) %>%
    dplyr::mutate(
      z1_pct    = 100 * z1_sec_sum / total_sec,
      z2_pct    = 100 * z2_sec_sum / total_sec,
      z3_pct    = 100 * z3_sec_sum / total_sec,
      total_min = total_sec / 60
    ) %>%
    dplyr::select(
      year_month, z1_pct, z2_pct, z3_pct,
      n_activities, total_min
    ) %>%
    dplyr::arrange(year_month)

  list(per_activity = per_activity, monthly = monthly)
}

#' Compute HR zone distribution from per-second trackeR data
#'
#' Classifies each per-second heart rate observation into Seiler zones using
#' HRmax-derived thresholds and aggregates by session and calendar month.
#' Covers the full workout history in \code{myruns} (typically 3000+ sessions),
#' but is computationally expensive — expect several minutes of processing time.
#'
#' Seiler zone thresholds (absolute bpm):
#' \itemize{
#'   \item Z1: HR \eqn{<} \code{hr_max * vt1_pct}
#'   \item Z2: \code{hr_max * vt1_pct} \eqn{\le} HR \eqn{<} \code{hr_max * vt2_pct}
#'   \item Z3: HR \eqn{\ge} \code{hr_max * vt2_pct}
#' }
#'
#' Sessions where the corresponding \code{myruns} entry is \code{NULL} or contains
#' no usable heart rate data are skipped with a warning (counted in the
#' \code{skipped} element of the return value).  Progress messages are printed
#' every 500 sessions.
#'
#' The relationship between \code{summaries} and \code{myruns} is positional:
#' row \emph{i} of \code{summaries} corresponds to \code{myruns[[i]]}.
#'
#' @param summaries Summaries tibble (from \code{my_dbs_load()}).
#' @param myruns List of trackeRdata objects (from \code{my_dbs_load()}).
#' @param hr_max Numeric. HRmax in bpm. \code{NULL} = auto-detect via
#'   \code{get_hr_max(summaries)}.
#' @param vt1_pct Numeric (0–1). VT1 threshold as fraction of HRmax (default 0.80).
#' @param vt2_pct Numeric (0–1). VT2 threshold as fraction of HRmax (default 0.90).
#' @return Named list with three elements:
#'   \describe{
#'     \item{\code{$per_activity}}{Tibble with same structure as
#'       \code{compute_zone_distribution()$per_activity}.}
#'     \item{\code{$monthly}}{Tibble with same structure as
#'       \code{compute_zone_distribution()$monthly}.}
#'     \item{\code{$skipped}}{Integer. Number of sessions skipped due to missing
#'       HR data.}
#'   }
#' @export
compute_zone_distribution_persecond <- function(summaries,
                                                myruns,
                                                hr_max  = NULL,
                                                vt1_pct = 0.80,
                                                vt2_pct = 0.90) {
  if (is.null(hr_max)) hr_max <- get_hr_max(summaries)

  vt1 <- hr_max * vt1_pct
  vt2 <- hr_max * vt2_pct

  message("HRmax: ", hr_max, " bpm | VT1: ", round(vt1), " bpm | VT2: ",
          round(vt2), " bpm")

  # Identifiera löpsessioner — håll index mot myruns-listan
  run_idx <- which(stringr::str_detect(summaries$sport, "running"))

  n_runs   <- length(run_idx)
  n_skip   <- 0L
  results  <- vector("list", n_runs)

  for (k in seq_along(run_idx)) {
    i <- run_idx[k]

    if (k %% 500 == 0) {
      message("  Bearbetar session ", k, " / ", n_runs, " ...")
    }

    # Hämta trackeRdata-objekt
    session <- tryCatch(myruns[[i]], error = function(e) NULL)

    if (is.null(session)) {
      n_skip <- n_skip + 1L
      next
    }

    # Extrahera per-sekundsdata som data.frame
    session_df <- tryCatch(
      as.data.frame(session),
      error = function(e) NULL
    )

    if (is.null(session_df) || !"heart_rate" %in% names(session_df)) {
      n_skip <- n_skip + 1L
      next
    }

    hr_vals <- as.numeric(session_df[["heart_rate"]])
    hr_vals <- hr_vals[!is.na(hr_vals) & hr_vals > 0]

    if (length(hr_vals) == 0) {
      n_skip <- n_skip + 1L
      next
    }

    # Klassificera varje sekund i Seiler-zon
    z1_sec <- sum(hr_vals < vt1)
    z2_sec <- sum(hr_vals >= vt1 & hr_vals < vt2)
    z3_sec <- sum(hr_vals >= vt2)
    total_sec <- z1_sec + z2_sec + z3_sec

    if (total_sec == 0) {
      n_skip <- n_skip + 1L
      next
    }

    results[[k]] <- tibble::tibble(
      sessionStart = as.Date(summaries$sessionStart[[i]]),
      distance_km  = as.numeric(summaries$distance[[i]]) / 1000,
      z1_sec       = as.numeric(z1_sec),
      z2_sec       = as.numeric(z2_sec),
      z3_sec       = as.numeric(z3_sec),
      total_sec    = as.numeric(total_sec),
      z1_pct       = 100 * z1_sec / total_sec,
      z2_pct       = 100 * z2_sec / total_sec,
      z3_pct       = 100 * z3_sec / total_sec
    )
  }

  if (n_skip > 0) {
    warning(n_skip, " sessioner hoppades över (NULL eller saknar HR-data).",
            call. = FALSE)
  }

  # Slå ihop per-session-resultat
  per_activity <- dplyr::bind_rows(results) %>%
    dplyr::arrange(sessionStart) %>%
    dplyr::select(
      sessionStart, distance_km,
      z1_pct, z2_pct, z3_pct,
      z1_sec, z2_sec, z3_sec, total_sec
    )

  if (nrow(per_activity) == 0) {
    empty_monthly <- tibble::tibble(
      year_month   = character(0),
      z1_pct       = numeric(0),
      z2_pct       = numeric(0),
      z3_pct       = numeric(0),
      n_activities = integer(0),
      total_min    = numeric(0)
    )
    return(list(per_activity = per_activity,
                monthly      = empty_monthly,
                skipped      = n_skip))
  }

  monthly <- per_activity %>%
    dplyr::mutate(year_month = format(sessionStart, "%Y-%m")) %>%
    dplyr::group_by(year_month) %>%
    dplyr::summarise(
      z1_sec_sum   = sum(z1_sec, na.rm = TRUE),
      z2_sec_sum   = sum(z2_sec, na.rm = TRUE),
      z3_sec_sum   = sum(z3_sec, na.rm = TRUE),
      total_sec    = sum(total_sec, na.rm = TRUE),
      n_activities = dplyr::n(),
      .groups      = "drop"
    ) %>%
    dplyr::filter(total_sec > 0) %>%
    dplyr::mutate(
      z1_pct    = 100 * z1_sec_sum / total_sec,
      z2_pct    = 100 * z2_sec_sum / total_sec,
      z3_pct    = 100 * z3_sec_sum / total_sec,
      total_min = total_sec / 60
    ) %>%
    dplyr::select(
      year_month, z1_pct, z2_pct, z3_pct,
      n_activities, total_min
    ) %>%
    dplyr::arrange(year_month)

  list(per_activity = per_activity, monthly = monthly, skipped = n_skip)
}

#' Compute Polarization Index (Treff 2019)
#'
#' Calculates the Polarization Index (PI) proposed by Treff et al. (2019) for
#' each month in the zone distribution data:
#' \deqn{PI = \log_{10}\!\left(\frac{p_1}{p_2} \times p_3 \times 100\right)}
#' where \eqn{p_1, p_2, p_3} are the proportions (0–1) of total training time
#' spent in Seiler zones Z1, Z2, Z3.
#'
#' Edge cases per Treff (2019):
#' \itemize{
#'   \item If \eqn{p_2 = 0}: use Equation 2:
#'     \eqn{PI = \log_{10}((p_1 / 0.01) \times (p_3 - 0.01) \times 100)}
#'   \item If \eqn{p_3 = 0}: PI = 0 by definition
#'   \item If \eqn{p_3 > p_1}: PI is not valid (flagged)
#' }
#'
#' Interpretation (Treff 2019):
#' \itemize{
#'   \item PI > 2.0: polarized
#'   \item PI \eqn{\le} 2.0: non-polarized (pyramidal, threshold, etc.)
#' }
#'
#' @param zone_data Named list as returned by \code{compute_zone_distribution()}
#'   or \code{compute_zone_distribution_persecond()}.  The \code{$monthly}
#'   element is used.
#' @param window Character (unused — reserved for future rolling PI).
#'   Currently the function always operates on individual calendar months.
#' @return Tibble with columns: \code{year_month}, \code{pi}, \code{z1_pct},
#'   \code{z2_pct}, \code{z3_pct}, \code{n_activities}, \code{has_zero_zone}
#'   (logical, TRUE when edge-case formula was applied).
#' @export
compute_polarization_index <- function(zone_data, window = "monthly") {
  if (!"monthly" %in% names(zone_data)) {
    stop("zone_data saknar '$monthly'-element. ",
         "Skicka in utdata fr\u00e5n compute_zone_distribution() eller ",
         "compute_zone_distribution_persecond().")
  }

  monthly <- zone_data$monthly

  if (nrow(monthly) == 0) {
    return(tibble::tibble(
      year_month    = character(0),
      pi            = numeric(0),
      z1_pct        = numeric(0),
      z2_pct        = numeric(0),
      z3_pct        = numeric(0),
      n_activities  = integer(0),
      has_zero_zone = logical(0)
    ))
  }

  monthly %>%
    dplyr::mutate(
      # Konvertera procent till proportioner (0-1)
      p1 = z1_pct / 100,
      p2 = z2_pct / 100,
      p3 = z3_pct / 100,
      # Markera edge cases
      has_zero_zone = (p2 == 0 | p3 == 0),
      # Treff (2019) PI: tre fall
      pi = dplyr::case_when(
        # Z3 = 0 -> PI = 0 per definition
        p3 == 0 ~ 0,
        # Z2 = 0 -> Equation 2
        p2 == 0 ~ log10((p1 / 0.01) * (p3 - 0.01) * 100),
        # Standard formula (Equation 1)
        TRUE    ~ log10((p1 / p2) * p3 * 100)
      )
    ) %>%
    dplyr::select(
      year_month, pi,
      z1_pct, z2_pct, z3_pct,
      n_activities, has_zero_zone
    ) %>%
    dplyr::arrange(year_month)
}

#' Cross-validate zone distributions from Garmin JSON vs per-second HR
#'
#' For activities that have both Garmin Connect zone data
#' (\code{garmin_hrTimeInZone_*}) and a corresponding \code{myruns} trackeRdata
#' entry with heart rate, computes zones from both sources and returns the
#' differences.  Useful for assessing how well the HRmax-threshold model
#' approximates the Garmin-firmware zones.
#'
#' A large \code{z1_diff} / \code{z3_diff} signals that the configured HRmax or
#' VT thresholds differ from Garmin's zone settings.
#'
#' @param summaries Enriched summaries tibble (must contain
#'   \code{garmin_hrTimeInZone_*} columns).
#' @param myruns List of trackeRdata objects.
#' @param hr_max Numeric. HRmax in bpm. \code{NULL} = auto-detect.
#' @param vt1_pct Numeric (0–1). VT1 threshold (default 0.80).
#' @param vt2_pct Numeric (0–1). VT2 threshold (default 0.90).
#' @return Tibble with one row per overlapping activity:
#'   \code{sessionStart}, \code{distance_km},
#'   \code{garmin_z1_pct}, \code{garmin_z2_pct}, \code{garmin_z3_pct},
#'   \code{persec_z1_pct}, \code{persec_z2_pct}, \code{persec_z3_pct},
#'   \code{z1_diff}, \code{z2_diff}, \code{z3_diff}
#'   (positive diff = Garmin higher than per-second estimate).
#' @export
cross_validate_zones <- function(summaries,
                                 myruns,
                                 hr_max  = NULL,
                                 vt1_pct = 0.80,
                                 vt2_pct = 0.90) {
  if (!.has_garmin_zones(summaries)) {
    stop(
      "summaries saknar garmin_hrTimeInZone-kolumner. ",
      "Kör augment_summaries() med Garmin Connect JSON-data först."
    )
  }

  if (is.null(hr_max)) hr_max <- get_hr_max(summaries)

  vt1 <- hr_max * vt1_pct
  vt2 <- hr_max * vt2_pct

  zone_cols <- paste0("garmin_hrTimeInZone_", 1:5)

  # Identifiera löpsessioner med kompletta Garmin-zondata
  run_idx <- which(
    stringr::str_detect(summaries$sport, "running") &
      !is.na(summaries$garmin_hrTimeInZone_1) &
      !is.na(summaries$garmin_hrTimeInZone_5)
  )

  n_total <- length(run_idx)
  message("Korsvaliderar ", n_total, " sessioner med Garmin-zondata ...")

  results <- vector("list", n_total)

  for (k in seq_along(run_idx)) {
    i <- run_idx[k]

    # --- Garmin-sida ---
    g1 <- as.numeric(summaries$garmin_hrTimeInZone_1[[i]])
    g2 <- as.numeric(summaries$garmin_hrTimeInZone_2[[i]])
    g3 <- as.numeric(summaries$garmin_hrTimeInZone_3[[i]])
    g4 <- as.numeric(summaries$garmin_hrTimeInZone_4[[i]])
    g5 <- as.numeric(summaries$garmin_hrTimeInZone_5[[i]])

    garmin_z1 <- g1 + g2
    garmin_z2 <- g3
    garmin_z3 <- g4 + g5
    garmin_tot <- garmin_z1 + garmin_z2 + garmin_z3

    if (is.na(garmin_tot) || garmin_tot == 0) next

    garmin_z1_pct <- 100 * garmin_z1 / garmin_tot
    garmin_z2_pct <- 100 * garmin_z2 / garmin_tot
    garmin_z3_pct <- 100 * garmin_z3 / garmin_tot

    # --- Per-sekundssida ---
    session <- tryCatch(myruns[[i]], error = function(e) NULL)

    if (is.null(session)) next

    session_df <- tryCatch(
      as.data.frame(session),
      error = function(e) NULL
    )

    if (is.null(session_df) || !"heart_rate" %in% names(session_df)) next

    hr_vals <- as.numeric(session_df[["heart_rate"]])
    hr_vals  <- hr_vals[!is.na(hr_vals) & hr_vals > 0]

    if (length(hr_vals) == 0) next

    ps_z1  <- sum(hr_vals < vt1)
    ps_z2  <- sum(hr_vals >= vt1 & hr_vals < vt2)
    ps_z3  <- sum(hr_vals >= vt2)
    ps_tot <- ps_z1 + ps_z2 + ps_z3

    if (ps_tot == 0) next

    ps_z1_pct <- 100 * ps_z1 / ps_tot
    ps_z2_pct <- 100 * ps_z2 / ps_tot
    ps_z3_pct <- 100 * ps_z3 / ps_tot

    results[[k]] <- tibble::tibble(
      sessionStart   = as.Date(summaries$sessionStart[[i]]),
      distance_km    = as.numeric(summaries$distance[[i]]) / 1000,
      garmin_z1_pct  = garmin_z1_pct,
      garmin_z2_pct  = garmin_z2_pct,
      garmin_z3_pct  = garmin_z3_pct,
      persec_z1_pct  = ps_z1_pct,
      persec_z2_pct  = ps_z2_pct,
      persec_z3_pct  = ps_z3_pct,
      z1_diff        = garmin_z1_pct - ps_z1_pct,
      z2_diff        = garmin_z2_pct - ps_z2_pct,
      z3_diff        = garmin_z3_pct - ps_z3_pct
    )
  }

  result <- dplyr::bind_rows(results) %>%
    dplyr::arrange(sessionStart)

  message("Korsvalidering klar: ", nrow(result), " matchade sessioner.")
  result
}
