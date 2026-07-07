#' Bygg en traning_data-bundle från cacherna på disk
#'
#' Konstruktören för S7-bundlen: laddar de RData-cacher som finns under
#' `data_dir/cache/` och returnerar dem som ett `traning_data`-objekt
#' (se `R/traning_data.R`). Detta är den enda platsen som känner till
#' cache-filnamnen och laddningsordningen — `load_session_data()`
#' (Shiny-appens loader) delegerar hit och packar upp bundlen till sin
#' nuvarande list-form för bakåtkompatibilitet.
#'
#' `summaries` och `myruns` är obligatoriska; saknade filer fångas av
#' `my_dbs_load()` och returneras som tom `data.frame`/tom `list`, en
#' korrupt fil bubblar upp som fel. Garmin-augmenteringen (se
#' `augment_summaries()`) körs som fallback om cachen saknar
#' `garmin_matched`-markören, och `@augmented` sätts i enlighet med
#' huruvida augmenteringen faktiskt kördes.
#'
#' `slots` styr vilken *optionell* data som laddas utöver
#' summaries/myruns (som alltid laddas):
#' \itemize{
#'   \item `NULL` (default): ladda samma uppsättning som
#'     `load_session_data()` historiskt gjort — `"health_daily"` och
#'     `"decoupling_data"` — för bakåtkompatibel paritet.
#'   \item ett tecken-vektor, t.ex. `character(0)` eller
#'     `"health_daily"`: ladda bara de namngivna slotsen. Tänkt för
#'     konsumenter (t.ex. MCP-bryggan) där myruns/decoupling är dyra att
#'     ladda och en ren summaries-rapport inte ska betala för dem.
#' }
#' Giltiga namn i `slots` är `"health_daily"` och `"decoupling_data"`.
#' `zone_data` laddas aldrig här (beräknas lazy nedströms) och `myruns`
#' laddas alltid tillsammans med `summaries` eftersom de delar samma
#' cache-par (`my_dbs_load()`).
#'
#' Saknade optionella cachefiler tolereras — motsvarande slot blir
#' `NULL`/tom, inget fel kastas (matchar `load_session_data()`s
#' tidigare beteende).
#'
#' @param data_dir Datakatalogen (default: `TRANING_DATA`-miljö-
#'   variabeln). Används som rot för samtliga cache-paths.
#' @param slots Character-vektor med optionella slots att ladda
#'   (`"health_daily"`, `"decoupling_data"`), eller `NULL` för att
#'   ladda båda (bakåtkompatibel default).
#' @return Ett `traning_data`-objekt (`sport = "running"`,
#'   `zone_data = NULL`).
#' @export
load_traning_data <- function(data_dir = Sys.getenv("TRANING_DATA"), slots = NULL) {
  if (!nzchar(data_dir)) {
    stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
  }

  valid_slots <- c("health_daily", "decoupling_data")
  if (is.null(slots)) {
    slots <- valid_slots
  }
  unknown_slots <- setdiff(slots, valid_slots)
  if (length(unknown_slots) > 0) {
    stop(
      "load_traning_data: unknown slot(s): ", paste(unknown_slots, collapse = ", "),
      ". Expected one or more of: ", paste(valid_slots, collapse = ", "),
      call. = FALSE
    )
  }

  cache_dir    <- file.path(data_dir, "cache")
  db_summaries <- file.path(cache_dir, "summaries.RData")
  db_myruns    <- file.path(cache_dir, "myruns.RData")
  gc_json_dir  <- file.path(data_dir, "kristian", "filer", "gconnect")

  my_templist <- my_dbs_load(db_summaries, db_myruns)
  summaries   <- my_templist[["summaries"]]
  myruns      <- my_templist[["myruns"]]
  rm(my_templist)

  # Legacy Garmin-augment-fallback. `cli.R --import` augmenterar nu
  # cachen vid import, så vid normal drift har `summaries` redan både
  # garmin_*-kolumner och markören `garmin_matched`. Detta block är
  # en fallback för legacy-caches och kan tas bort när alla caches
  # (kedar, kailash, ev. andra hostar) re-importats minst en gång.
  augmented <- "garmin_matched" %in% names(summaries)
  if (dir.exists(gc_json_dir) && !augmented) {
    message("load_traning_data: cache saknar garmin_matched-markören - ",
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
      augmented <- "garmin_matched" %in% names(summaries)
    }
  }

  # Härled cache-paths från `data_dir`-argumentet snarare än
  # `Sys.getenv()`-defaulten i hjälparna, så hela laddningen håller
  # samma datarot även när anropare overrider env-varen (tester,
  # parallella datakällor).
  decoupling_data <- NULL
  if ("decoupling_data" %in% slots) {
    decoupling_cache_path <- file.path(cache_dir, "decoupling.RData")
    # Decoupling-load i read-only-läge: bevarar load_decoupling()s
    # validering av cache-parametrar (sport, min_duration, warmup,
    # smooth_window, ...) och incremental compute för nya sessioner,
    # men hoppar över cache-skrivningen så Shiny-sessioner inte
    # genererar disk-writes per session eller racer mot parallella
    # konsumenter. Cache-bygget sker fortfarande via `cli.R --decoupling`.
    decoupling_data <- tryCatch(
      load_decoupling(summaries, myruns,
                      cache_path = decoupling_cache_path,
                      read_only  = TRUE),
      error = function(e) {
        warning("Kunde inte ladda decoupling-data: ", conditionMessage(e))
        NULL
      }
    )
  }

  health_daily <- NULL
  if ("health_daily" %in% slots) {
    health_cache_path <- file.path(cache_dir, "health_daily.RData")
    health_daily <- tryCatch(
      load_health_data(cache_path = health_cache_path),
      error = function(e) {
        warning("Kunde inte ladda hälsodata: ", conditionMessage(e))
        NULL
      }
    )
  }

  traning_data(
    summaries       = summaries,
    myruns          = myruns,
    health_daily    = health_daily,
    decoupling_data = decoupling_data,
    sport           = "running",
    augmented       = augmented
  )
}

#' Ladda alla cacher som tRanat-dashboarden behöver
#'
#' Returnerar en namngiven lista med `summaries`, `myruns`,
#' `decoupling_data` och `health_daily`. Tänkt att anropas både vid
#' app-start (en gång per R-process, från `global.R`) och per Shiny-
#' session (från `server()` i `app.R`). Per-session-anropet säkerställer
#' att varje omladdad dashboard ser den cache som finns på disk just nu
#' — utan service-restart.
#'
#' Detta är en tunn wrapper runt \code{\link{load_traning_data}()} som
#' packar upp `traning_data`-bundlen till appens historiska list-form
#' (`$`-access), så tRanat-appen (som ännu inte migrerats till S7:s
#' `@`-access) förblir opåverkad.
#'
#' @param data_dir Datakatalogen (default: `TRANING_DATA`-miljö-
#'   variabeln). Används som rot för samtliga cache-paths så att
#'   en explicit `data_dir` håller hela laddningen konsistent
#'   även om `Sys.getenv("TRANING_DATA")` pekar någon annanstans.
#' @return Lista med fyra element: `summaries`, `myruns`,
#'   `decoupling_data`, `health_daily`.
#' @export
load_session_data <- function(data_dir = Sys.getenv("TRANING_DATA")) {
  bundle <- load_traning_data(data_dir)

  list(
    summaries       = bundle@summaries,
    myruns          = bundle@myruns,
    decoupling_data = bundle@decoupling_data,
    health_daily    = bundle@health_daily
  )
}

# Normalisera en NA/NULL-gräns till NULL. `mod_date_preset` returnerar
# NA om en custom `dateRangeInput` har rensats — base-subset med
# logiska NA ger 1 rad av NA, så NA måste tolkas som "ingen gräns".
.normalize_range_bound <- function(x) {
  if (is.null(x)) return(NULL)
  if (length(x) == 0) return(NULL)
  if (length(x) == 1 && is.na(x)) return(NULL)
  x
}

# Filtrera readiness-rader till ett datumspann. Inklusivt intervall
# [from, to] — till skillnad från session-nivå-filter som är halvöppna.
# Readiness är ett finaliserat dagligt aggregat (en rad per kalenderdag);
# den övre gränsen ska vara inklusiv så att KPI-boxens slice_max(date)
# matchar mini-grafens rightmost-punkt när to = Sys.Date(). Se
# `filter_by_daterange()` (R/daterange.R, closed_upper-param) och
# docs/dev/filter-consistency.md för principen Date → inklusiv,
# datetime → halvöppet. `.filter_running_range` (nedan) använder
# sessionStart (POSIXct) och är fortsatt halvöppet [from, to).
# NULL- eller NA-gräns = öppen åt det hållet. NA-datum droppas
# *alltid*, oavsett bound-state, så att downstream `min(date)`/
# `max(date)` aldrig blir NA (annars tappas `geom_rect`-band i
# mini-graferna). Privat (dot-prefix) — exportPattern("^[^\\.]") i
# NAMESPACE hoppar över dot-funktioner. Konsumeras av mod_overview.R.
.filter_readiness_range <- function(rd, from = NULL, to = NULL) {
  if (is.null(rd) || nrow(rd) == 0) return(rd)
  from <- .normalize_range_bound(from)
  to   <- .normalize_range_bound(to)
  out <- rd[!is.na(rd$date), , drop = FALSE]
  if (!is.null(from)) out <- out[out$date >= from, , drop = FALSE]
  if (!is.null(to))   out <- out[out$date <= to,   , drop = FALSE]
  out
}

# Filtrera summaries (löppass) till ett datumspann via sessionStart.
# Halvöppet intervall [from, to) — se `.filter_readiness_range`. NA i
# `sessionStart` droppas alltid, även när inga bounds är satta.
.filter_running_range <- function(summaries, from = NULL, to = NULL) {
  if (is.null(summaries) || nrow(summaries) == 0) return(summaries)
  from <- .normalize_range_bound(from)
  to   <- .normalize_range_bound(to)
  d <- as.Date(summaries$sessionStart)
  keep <- !is.na(d)
  if (!is.null(from)) keep <- keep & d >= from
  if (!is.null(to))   keep <- keep & d <  to
  summaries[keep, , drop = FALSE]
}
