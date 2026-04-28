# Tests for state-based health insight functions in R/health_export.R:
# health_insight_readiness(), health_insight_update(),
# recent_data_dump(), latest_known_metrics().

# --- Fixtures ---------------------------------------------------------------

.fixture_health_daily <- function(today = as.Date("2026-04-20")) {
  metrics <- c("heart_rate_variability", "sleep_totalSleep",
                "sleep_deep", "sleep_rem", "resting_heart_rate",
                "vo2_max", "apple_sleeping_wrist_temperature",
                "respiratory_rate")
  dates <- seq(today - 21, today, by = "day")
  rows <- list()
  set.seed(42)
  for (m in metrics) {
    base <- switch(m,
      heart_rate_variability = 70,
      sleep_totalSleep = 7,
      sleep_deep = 1.0,
      sleep_rem = 1.5,
      resting_heart_rate = 55,
      vo2_max = 53,
      apple_sleeping_wrist_temperature = 36.5,
      respiratory_rate = 15
    )
    for (d in dates) {
      rows[[length(rows) + 1]] <- list(
        date = as.Date(d, origin = "1970-01-01"),
        metric = m,
        value = base + stats::rnorm(1, 0, base * 0.05),
        source = "test"
      )
    }
  }
  do.call(rbind.data.frame, lapply(rows, as.data.frame)) |> tibble::as_tibble()
}

.fixture_summaries <- function(today = as.Date("2026-04-20")) {
  starts <- as.POSIXct(seq(today - 14, today, by = "day"))
  n <- length(starts)
  tibble::tibble(
    sessionStart       = starts,
    sport              = "running",
    distance           = rep(8000, n),
    durationMoving     = rep(2700, n),
    avgPaceMoving      = rep(5.6, n),
    avgSpeedMoving     = rep(2.97, n),
    avgHeartRateMoving = rep(140, n),
    file               = paste0("test_", seq_len(n), ".tcx"),
    year               = format(starts, "%Y")
  )
}

# --- health_insight_readiness ----------------------------------------------

test_that("health_insight_readiness returns prosa with status and score", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  res <- health_insight_readiness(hd, s, hr_max = 185)
  expect_type(res, "list")
  expect_true("prosa" %in% names(res))
  expect_true("components_present" %in% names(res))
  expect_true(grepl("Dagsform", res$prosa))
  # Header includes one of the status strings
  expect_true(grepl("Grön|Gul|Röd", res$prosa))
})

test_that("health_insight_readiness reports missing components on partial", {
  hd <- .fixture_health_daily()
  # Drop today's HRV so quality drops
  today <- max(hd$date)
  hd_partial <- hd[!(hd$metric == "heart_rate_variability" & hd$date == today), ]
  s <- .fixture_summaries(today)
  res <- health_insight_readiness(hd_partial, s, hr_max = 185, on_date = today)
  expect_false(isTRUE(res$components_present$hrv))
  # HRV should be in components but with NA value
  expect_true(is.na(res$components$hrv$value))
})

test_that("health_insight_readiness returns empty list with no data", {
  empty_hd <- tibble::tibble(date = as.Date(character()),
                             metric = character(),
                             value = numeric(),
                             source = character())
  s <- .fixture_summaries()
  res <- health_insight_readiness(empty_hd, s)
  expect_equal(res$prosa, "")
})

# --- health_insight_update --------------------------------------------------

test_that("health_insight_update re-renders when partial component arrives", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  today <- max(hd$date)
  prev <- list(
    date = format(today, "%Y-%m-%d"),
    morning_sent = TRUE,
    morning_kvalitet = "partial",
    morning_components = list(
      hrv = FALSE, sleep = TRUE, rhr = TRUE,
      load = TRUE, wrist_temp = TRUE
    ),
    morning_status = "Gul",
    morning_score = 55,
    afternoon_updates_sent = list()
  )
  res <- health_insight_update(hd, s, prev, hr_max = 185, on_date = today)
  expect_equal(res$trigger, "rerender")
  expect_true(grepl("uppdaterad", res$prosa))
  expect_true(grepl("HRV", res$prosa))
})

test_that("health_insight_update is silent when nothing changed", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  today <- max(hd$date)
  prev <- list(
    date = format(today, "%Y-%m-%d"),
    morning_sent = TRUE,
    morning_kvalitet = "full",
    morning_components = list(
      hrv = TRUE, sleep = TRUE, rhr = TRUE,
      load = TRUE, wrist_temp = TRUE
    ),
    morning_status = "Grön",
    morning_score = 80,
    afternoon_updates_sent = list("vo2_max", "apple_sleeping_wrist_temperature",
                                   "respiratory_rate", "blood_oxygen_saturation")
  )
  res <- health_insight_update(hd, s, prev, hr_max = 185, on_date = today)
  expect_equal(res$prosa, "")
  expect_equal(res$trigger, "")
})

test_that("health_insight_update returns empty when prev_state is NULL", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  res <- health_insight_update(hd, s, NULL, hr_max = 185)
  expect_equal(res$prosa, "")
})

# --- recent_data_dump -------------------------------------------------------

test_that("recent_data_dump filters to the requested window", {
  hd <- .fixture_health_daily()
  s  <- .fixture_summaries()
  res <- recent_data_dump(hd, s, hours = 48)
  expect_true(is.list(res))
  expect_true("metrics" %in% names(res))
  expect_true("sessions" %in% names(res))
  expect_true("last_pushes" %in% names(res))
  # Window should restrict
  for (m in names(res$metrics)) {
    dates <- as.Date(res$metrics[[m]]$date)
    expect_true(all(dates >= Sys.Date() - 3))
  }
})

# --- latest_known_metrics ---------------------------------------------------

test_that("latest_known_metrics returns one row per unique metric", {
  hd <- .fixture_health_daily()
  res <- latest_known_metrics(hd)
  expect_equal(nrow(res), length(unique(hd$metric)))
  expect_true(all(c("metric", "date", "value", "age_hours") %in% names(res)))
  # Should be sorted by date ascending
  expect_true(all(diff(as.numeric(res$date)) >= 0))
})

test_that("latest_known_metrics handles empty input", {
  empty <- tibble::tibble(date = as.Date(character()),
                          metric = character(),
                          value = numeric())
  res <- latest_known_metrics(empty)
  expect_equal(nrow(res), 0)
})
