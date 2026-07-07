# Shared fixtures for load_session_data() / load_traning_data() tests.
# testthat sources helper-*.R files before any test-*.R file and keeps
# them available for the whole run, so both test-shiny-helpers.R and
# test-load-traning-data.R can rely on these without a file-ordering
# dependency between them.

make_fake_cache <- function(traning_data) {
  cache_dir <- file.path(traning_data, "cache")
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

  # `load_decoupling()` (cold path) konsulterar `durationMoving` och
  # `avgPaceMoving` på summaries. Inkludera dem i fixturen så vi
  # exercerar success-vägen, inte bara error-fångsten.
  summaries <- data.frame(
    sessionStart    = as.POSIXct(c("2026-05-01 06:30:00",
                                   "2026-05-02 18:00:00"),
                                 tz = "UTC"),
    sport           = c("running", "running"),
    duration        = c(45, 60),
    durationMoving  = as.difftime(c(45, 60), units = "mins"),
    avgPaceMoving   = c(5.5, 5.0),
    garmin_matched  = c(TRUE, TRUE),
    source          = c("tcx", "tcx"),
    stringsAsFactors = FALSE
  )
  myruns <- list()  # trackeRdata-listan — tom är OK för load-testet

  my_dbs_save(
    db_summaries = file.path(cache_dir, "summaries.RData"),
    db_myruns    = file.path(cache_dir, "myruns.RData"),
    summaries    = summaries,
    myruns       = myruns
  )

  cache_dir
}

with_traning_data <- function(traning_data, code) {
  prev <- Sys.getenv("TRANING_DATA", unset = NA)
  Sys.setenv(TRANING_DATA = traning_data)
  on.exit({
    if (is.na(prev)) Sys.unsetenv("TRANING_DATA") else Sys.setenv(TRANING_DATA = prev)
  }, add = TRUE)
  force(code)
}
