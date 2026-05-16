#' Ladda alla cacher som tRanat-dashboarden behöver
#'
#' Returnerar en namngiven lista med `summaries`, `myruns`,
#' `decoupling_data` och `health_daily`. Tänkt att anropas både vid
#' app-start (en gång per R-process, från `global.R`) och per Shiny-
#' session (från `server()` i `app.R`). Per-session-anropet säkerställer
#' att varje omladdad dashboard ser den cache som finns på disk just nu
#' — utan service-restart.
#'
#' `summaries` och `myruns` är obligatoriska för att dashboarden ska
#' kunna rendera; saknade filer fångas av `my_dbs_load()` och returneras
#' som tom `data.frame`/tom `list`, en korrupt fil bubblar upp som fel.
#' `decoupling_data` och `health_daily` är optionella och fångas med
#' `tryCatch` så dashboarden kan starta med en delmängd av datan om
#' deras cacher är saknade eller trasiga.
#'
#' @param traning_data Datakatalogen (default: `TRANING_DATA`-miljö-
#'   variabeln). Används som rot för samtliga cache-paths så att
#'   en explicit `traning_data` håller hela laddningen konsistent
#'   även om `Sys.getenv("TRANING_DATA")` pekar någon annanstans.
#' @return Lista med fyra element: `summaries`, `myruns`,
#'   `decoupling_data`, `health_daily`.
#' @export
load_session_data <- function(traning_data = Sys.getenv("TRANING_DATA")) {
  if (!nzchar(traning_data)) {
    stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
  }

  cache_dir    <- file.path(traning_data, "cache")
  db_summaries <- file.path(cache_dir, "summaries.RData")
  db_myruns    <- file.path(cache_dir, "myruns.RData")
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
            "augmenterar som fallback. Kör `traning import all` ",
            "för permanent fix.")
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

  # Härled cache-paths från `traning_data`-arget snarare än
  # `Sys.getenv()`-defaulten i hjälparna, så hela laddningen håller
  # samma datarot även när anropare overrider env-varen (tester,
  # parallella datakällor).
  decoupling_cache_path <- file.path(cache_dir, "decoupling.RData")
  health_cache_path     <- file.path(cache_dir, "health_daily.RData")

  decoupling_data <- tryCatch(
    load_decoupling(summaries, myruns, cache_path = decoupling_cache_path),
    error = function(e) {
      warning("Kunde inte ladda decoupling-data: ", conditionMessage(e))
      NULL
    }
  )

  health_daily <- tryCatch(
    load_health_data(cache_path = health_cache_path),
    error = function(e) {
      warning("Kunde inte ladda hälsodata: ", conditionMessage(e))
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
