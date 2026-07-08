# Tests for load_session_data() — the per-session cache loader used by
# both global.R (initial load) and app.R server() (per-session refresh)
# in the tRanat dashboard.
#
# make_fake_cache() / with_traning_data() live in helper-shiny-data.R
# (shared with test-load-traning-data.R).

test_that("load_session_data returns a valid traning_data bundle", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    out <- load_session_data()
  })

  expect_true(S7::S7_inherits(out, traning_data))
  expect_s3_class(out@summaries, "data.frame")
  expect_type(out@myruns, "list")
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

  expect_equal(out@summaries, ref$summaries)
  expect_equal(out@myruns, ref$myruns)
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
  expect_true(inherits(out@health_daily, "data.frame"))
  expect_named(out@health_daily, c("date", "metric", "value", "source"),
               ignore.order = TRUE)

  # decoupling_data är NULL (kallt cold-path-misslyckande) eller en
  # data.frame (lyckad cold compute) — båda är acceptabla då vi bara
  # vill bekräfta att laddaren inte kraschar utan färdig cache.
  expect_true(is.null(out@decoupling_data) ||
              inherits(out@decoupling_data, "data.frame"))
})

test_that("load_session_data honours explicit traning_data over env var", {
  # Två tempdir:s — env-varen pekar mot "wrong", argumentet mot "right".
  # Argumentet ska vinna så att alla cache-paths (inkl. decoupling och
  # health) härleds från "right".
  td_wrong <- tempfile("traning_data_wrong_")
  td_right <- tempfile("traning_data_right_")
  on.exit({ unlink(td_wrong, recursive = TRUE)
            unlink(td_right, recursive = TRUE) }, add = TRUE)
  dir.create(file.path(td_wrong, "cache"), recursive = TRUE)
  cache_dir_right <- make_fake_cache(td_right)

  with_traning_data(td_wrong, {
    out <- load_session_data(data_dir = td_right)
  })

  ref <- my_dbs_load(
    file.path(cache_dir_right, "summaries.RData"),
    file.path(cache_dir_right, "myruns.RData")
  )
  expect_equal(out@summaries, ref$summaries)
})

test_that("load_session_data is reentrant — two calls return equivalent data", {
  td <- tempfile("traning_data_")
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  make_fake_cache(td)

  with_traning_data(td, {
    a <- load_session_data()
    b <- load_session_data()
  })

  expect_equal(a@summaries, b@summaries)
  expect_equal(a@myruns, b@myruns)
})

test_that("load_session_data errors when TRANING_DATA is unset", {
  prev <- Sys.getenv("TRANING_DATA", unset = NA)
  Sys.unsetenv("TRANING_DATA")
  on.exit({
    if (!is.na(prev)) Sys.setenv(TRANING_DATA = prev)
  }, add = TRUE)

  expect_error(load_session_data(data_dir = ""), "TRANING_DATA")
})
