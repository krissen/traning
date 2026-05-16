#' Ladda alla cacher som tRanat-dashboarden behöver
#'
#' Returnerar en namngiven lista med `summaries`, `myruns`,
#' `decoupling_data` och `health_daily`. Tänkt att anropas både vid
#' app-start (en gång per R-process, från `global.R`) och per Shiny-
#' session (från `server()` i `app.R`). Per-session-anropet säkerställer
#' att varje omladdad dashboard ser den cache som finns på disk just nu
#' — utan service-restart.
#'
#' Saknade eller trasiga cacher fångas med `tryCatch` och resulterar i
#' `NULL` snarare än ett krasch, så dashboarden kan starta med
#' delmängder av datan.
#'
#' @param traning_data Datakatalogen (default: `TRANING_DATA`-miljö-
#'   variabeln).
#' @return Lista med fyra element: `summaries`, `myruns`,
#'   `decoupling_data`, `health_daily`.
#' @export
load_session_data <- function(traning_data = Sys.getenv("TRANING_DATA")) {
  if (!nzchar(traning_data)) {
    stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
  }

  db_summaries <- file.path(traning_data, "cache", "summaries.RData")
  db_myruns    <- file.path(traning_data, "cache", "myruns.RData")
  gc_json_dir  <- file.path(traning_data, "kristian", "filer", "gconnect")

  my_templist <- my_dbs_load(db_summaries, db_myruns)
  summaries   <- my_templist[["summaries"]]
  myruns      <- my_templist[["myruns"]]
  rm(my_templist)

  # Legacy Garmin-augment-fallback. `cli.R --import` augmenterar nu
  # cachen vid import, så vid normal drift har `summaries` redan både
  # garmin_*-kolumner och markören `garmin_matched`. Detta block är
  # en fallback för legacy-caches och kan tas bort när alla caches
  # (kedar, kailash, ev. andra hostar) re-importats minst en gång.
  if (dir.exists(gc_json_dir) &&
      !("garmin_matched" %in% names(summaries))) {
    message("load_session_data: cache saknar garmin_matched-markören - ",
            "augmenterar som fallback. Kor `traning import all` ",
            "for permanent fix.")
    garmin_data <- tryCatch(
      load_garmin_json(gc_json_dir),
      error = function(e) {
        warning("Kunde inte ladda Garmin JSON-data: ", conditionMessage(e))
        NULL
      }
    )
    if (!is.null(garmin_data)) {
      summaries <- tryCatch(
        augment_summaries(summaries, garmin_data),
        error = function(e) {
          warning("augment_summaries misslyckades: ", conditionMessage(e))
          summaries
        }
      )
    }
  }

  decoupling_data <- tryCatch(
    load_decoupling(summaries, myruns),
    error = function(e) {
      warning("Kunde inte ladda decoupling-data: ", conditionMessage(e))
      NULL
    }
  )

  health_daily <- tryCatch(
    load_health_data(),
    error = function(e) {
      warning("Kunde inte ladda halsodata: ", conditionMessage(e))
      NULL
    }
  )

  list(
    summaries       = summaries,
    myruns          = myruns,
    decoupling_data = decoupling_data,
    health_daily    = health_daily
  )
}
