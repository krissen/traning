# Tests for load_session_data() — the per-session cache loader used by
# both global.R (initial load) and app.R server() (per-session refresh)
# in the tRanat dashboard.

make_fake_cache <- function(traning_data) {
  cache_dir <- file.path(traning_data, "cache")
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

  summaries <- data.frame(
    sessionStart   = as.POSIXct(c("2026-05-01 06:30:00",
                                  "2026-05-02 18:00:00"),
                                tz = "UTC"),
    sport          = c("running", "running"),
    duration       = c(45, 60),
    garmin_matched = c(TRUE, TRUE),
    source         = c("tcx", "tcx"),
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

test_that("load_session_data returns list with expected names", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    out <- load_session_data()
  })

  expect_type(out, "list")
  expect_named(out, c("summaries", "myruns", "decoupling_data", "health_daily"))
})

test_that("load_session_data summaries matches my_dbs_load", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  cache_dir <- make_fake_cache(td)

  ref <- my_dbs_load(
    file.path(cache_dir, "summaries.RData"),
    file.path(cache_dir, "myruns.RData")
  )

  with_traning_data(td, {
    out <- load_session_data()
  })

  expect_equal(out$summaries, ref$summaries)
  expect_equal(out$myruns, ref$myruns)
})

test_that("load_session_data handles missing health/decoupling caches", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)
  # Inga health_daily.RData eller decoupling.RData — load_health_data()
  # returnerar tom tibble, load_decoupling() bygger en tom struktur.

  with_traning_data(td, {
    out <- load_session_data()
  })

  # health_daily ska vara tibble med rätt schema även när cache saknas
  expect_true(inherits(out$health_daily, "data.frame"))
  expect_named(out$health_daily, c("date", "metric", "value", "source"),
               ignore.order = TRUE)

  # decoupling_data är NULL eller en tibble — vi accepterar båda så
  # länge det inte kraschar.
  expect_true(is.null(out$decoupling_data) ||
              inherits(out$decoupling_data, "data.frame") ||
              is.list(out$decoupling_data))
})

test_that("load_session_data is reentrant — two calls return equivalent data", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    a <- load_session_data()
    b <- load_session_data()
  })

  expect_equal(a$summaries, b$summaries)
  expect_equal(a$myruns, b$myruns)
})

test_that("load_session_data errors when TRANING_DATA is unset", {
  prev <- Sys.getenv("TRANING_DATA", unset = NA)
  Sys.unsetenv("TRANING_DATA")
  on.exit({
    if (!is.na(prev)) Sys.setenv(TRANING_DATA = prev)
  }, add = TRUE)

  expect_error(load_session_data(traning_data = ""), "TRANING_DATA")
})
