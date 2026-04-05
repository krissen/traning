# global.R — laddas en gång vid appstart
# Laddar paketet och all träningsdata i global miljö

# Paketrot är två nivåer upp från app/tRanat/
# Shiny sätter working directory till app-katalogen när global.R körs,
# så "../.." ger korrekt paketrot oavsett hur appen startas.
pkg_root <- normalizePath(file.path(getwd(), "..", ".."))
suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))

# --- Datasökvägar (från TRANING_DATA-miljövariabeln) ---
traning_data <- Sys.getenv("TRANING_DATA")
if (traning_data == "") {
  stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
}

db_summaries <- file.path(traning_data, "cache", "summaries.RData")
db_myruns    <- file.path(traning_data, "cache", "myruns.RData")
gc_json_dir  <- file.path(traning_data, "kristian", "filer", "gconnect")

# --- Ladda summaries och myruns ---
my_templist <- my_dbs_load(db_summaries, db_myruns)
summaries   <- my_templist[["summaries"]]
myruns      <- my_templist[["myruns"]]
rm(my_templist)

# --- Berika med Garmin JSON-data om katalogen finns ---
if (dir.exists(gc_json_dir)) {
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

# --- Ladda Apple Watch hälsodata ---
health_daily <- tryCatch(
  load_health_data(),
  error = function(e) {
    warning("Kunde inte ladda hälsodata: ", conditionMessage(e))
    NULL
  }
)
