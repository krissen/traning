# Fun-facts widget for the Översikt tab.
#
# Surface a handful of "did you know"-style stats from the user's full
# training history — things that won't show up in PMC/ACWR/calendar
# views but are nice to bump into.

#' Compute fun-fact statistics from a summaries data frame
#'
#' Returns a named list of pre-formatted Swedish prose strings ready to
#' drop into a Shiny UI. Each element is a single sentence.
#'
#' @param summaries Data frame from \code{my_dbs_load()}.
#' @return Named list with `string` (Swedish prose) and `value` (raw
#'   value, useful for sorting/testing) per fact.
#' @export
compute_fun_facts <- function(summaries) {
  if (is.null(summaries) || nrow(summaries) == 0L) {
    return(list())
  }

  out <- list()

  # Total sessions per sport (top 5 by count)
  per_sport <- summaries %>%
    dplyr::filter(!is.na(.data$sport), nzchar(.data$sport)) %>%
    dplyr::count(.data$sport, sort = TRUE) %>%
    utils::head(5)

  if (nrow(per_sport) > 0) {
    parts <- vapply(seq_len(nrow(per_sport)), function(i) {
      sprintf("%s %d", sport_label(per_sport$sport[i]), per_sport$n[i])
    }, character(1))
    out$total_per_sport <- list(
      string = paste0("Topp 5 sporter (antal pass): ",
                      paste(parts, collapse = ", "), "."),
      value  = per_sport
    )
  }

  # First registered session. Guard against NA sport — sport_label()
  # falls back to title-casing the raw value, which produces "NANA" for
  # NA_character_ via paste0(NA, NA). Substitute the generic label.
  first <- summaries %>%
    dplyr::filter(!is.na(.data$sessionStart)) %>%
    dplyr::slice_min(.data$sessionStart, n = 1, with_ties = FALSE)
  if (nrow(first) > 0) {
    first_sport <- if (is.na(first$sport) || !nzchar(first$sport)) {
      "Aktivitet"
    } else {
      sport_label(first$sport)
    }
    out$first_session <- list(
      string = sprintf("Första registrerade passet: %s (%s).",
                       format(first$sessionStart, "%Y-%m-%d"),
                       first_sport),
      value  = first$sessionStart
    )
  }

  # Longest gap between runs
  running <- summaries %>%
    dplyr::filter(stringr::str_detect(.data$sport, "running"),
                  !is.na(.data$sessionStart)) %>%
    dplyr::arrange(.data$sessionStart)
  if (nrow(running) >= 2) {
    starts <- as.Date(running$sessionStart)
    gaps   <- as.numeric(diff(starts), units = "days")
    if (length(gaps) > 0 && any(is.finite(gaps))) {
      g_max <- max(gaps, na.rm = TRUE)
      g_idx <- which.max(gaps)
      out$longest_gap <- list(
        string = sprintf(
          "Längsta uppehåll mellan löpturer: %d dagar (%s → %s).",
          as.integer(g_max),
          format(starts[g_idx],   "%Y-%m-%d"),
          format(starts[g_idx + 1], "%Y-%m-%d")),
        value  = g_max
      )
    }
  }

  # Calendar months with no sessions at all
  if (nrow(summaries) > 0) {
    months <- format(as.Date(summaries$sessionStart), "%Y-%m")
    months <- months[!is.na(months)]
    if (length(months) > 0) {
      first_d <- as.Date(paste0(min(months), "-01"))
      last_d  <- as.Date(paste0(max(months), "-01"))
      spine   <- format(seq(first_d, last_d, by = "month"), "%Y-%m")
      empty   <- setdiff(spine, unique(months))
      out$empty_months <- list(
        string = sprintf(
          "Hela kalendermånader utan ett enda pass: %d (av %d totalt).",
          length(empty), length(spine)),
        value  = empty
      )
    }
  }

  # Longest single run (km)
  if (nrow(running) > 0 && any(!is.na(running$distance))) {
    longest <- running %>%
      dplyr::slice_max(.data$distance, n = 1, with_ties = FALSE)
    out$longest_run <- list(
      string = sprintf(
        "Längsta löpningen: %.1f km (%s).",
        longest$distance / 1000,
        format(longest$sessionStart, "%Y-%m-%d")),
      value  = as.numeric(longest$distance) / 1000
    )
  }

  # Fastest run > 5 km (avgPaceMoving column)
  fast_pool <- running %>%
    dplyr::filter(.data$distance > 5000,
                  !is.na(.data$avgPaceMoving),
                  .data$avgPaceMoving > 2.5)
  if (nrow(fast_pool) > 0) {
    fastest <- fast_pool %>%
      dplyr::slice_min(.data$avgPaceMoving, n = 1, with_ties = FALSE)
    out$fastest_run <- list(
      string = sprintf(
        "Snabbaste löpturen (>5 km): %s/km på %.1f km (%s).",
        dec_to_mmss(fastest$avgPaceMoving),
        fastest$distance / 1000,
        format(fastest$sessionStart, "%Y-%m-%d")),
      value  = as.numeric(fastest$avgPaceMoving)
    )
  }

  out
}

#' Render fun-facts as a Shiny tag list
#'
#' Companion to \code{compute_fun_facts()}. Returns an unordered list
#' suitable for wrapping in a card or accordion panel.
#'
#' @param facts Output of \code{compute_fun_facts()}.
#' @return Shiny tag (`<ul>`).
#' @keywords internal
.format_fun_facts_html <- function(facts) {
  if (length(facts) == 0L) {
    return(shiny::tags$p("Ingen data."))
  }
  items <- lapply(facts, function(f) shiny::tags$li(f$string))
  shiny::tags$ul(items)
}
