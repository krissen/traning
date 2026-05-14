# Regression tests for the "Allt"-filter bug (NULL from/to → full
# history, not silent 365-day truncation).
#
# History: fetch.plot.acwr/monotony/pmc/readiness_score and
# plot_sport_calendar each had an `if (is.null(from)) ... else days`
# fallback that coerced Shiny's `NULL` (the value emitted when the user
# picks the "Allt" preset) to a 90/365/366-day window. Refactored to
# .filter_date_range() which treats NULL as "no bound".

# Multi-year fixture spanning 3 years so a 365-day truncation would be
# obvious in the rendered data.
.fixture_long_history <- function() {
  base <- as.POSIXct("2022-01-01 06:00:00", tz = "UTC")
  n_days <- 365 * 3
  # One run every 3 days
  idx <- seq(1L, n_days, by = 3L)
  data.frame(
    sessionStart = base + (idx - 1L) * 86400,
    sport = "running",
    distance = 8000,
    durationMoving = as.difftime(rep(45, length(idx)), units = "mins"),
    avgSpeedMoving = 3.0,
    avgPaceMoving = 5.5,
    avgHeartRateMoving = 145,
    stringsAsFactors = FALSE
  )
}

test_that("fetch.plot.acwr with NULL from/to spans the full history", {
  sm <- .fixture_long_history()
  p <- fetch.plot.acwr(sm, from = NULL, to = NULL, sport = "running")
  # Suppress pre-existing geom_rect(xmin = -Inf, xmax = Inf) warning on
  # Date scale — those infinity bounds are accepted but ggplot warns.
  b <- suppressWarnings(ggplot2::ggplot_build(p))
  # Find a layer with non-empty x — it should span > 365 days
  spans <- vapply(b$data, function(d) {
    if (is.null(d$x) || length(d$x) == 0) return(NA_real_)
    as.numeric(diff(range(suppressWarnings(as.Date(d$x, origin = "1970-01-01")),
                          na.rm = TRUE)))
  }, numeric(1))
  expect_gt(max(spans, na.rm = TRUE), 365)
})

test_that("fetch.plot.monotony with NULL from/to spans the full history", {
  sm <- .fixture_long_history()
  p <- fetch.plot.monotony(sm, from = NULL, to = NULL, sport = "running")
  # Suppress pre-existing geom_rect(xmin = -Inf, xmax = Inf) warning on
  # Date scale — those infinity bounds are accepted but ggplot warns.
  b <- suppressWarnings(ggplot2::ggplot_build(p))
  spans <- vapply(b$data, function(d) {
    if (is.null(d$x) || length(d$x) == 0) return(NA_real_)
    as.numeric(diff(range(suppressWarnings(as.Date(d$x, origin = "1970-01-01")),
                          na.rm = TRUE)))
  }, numeric(1))
  expect_gt(max(spans, na.rm = TRUE), 365)
})

test_that("fetch.plot.pmc with NULL from/to spans the full history", {
  sm <- .fixture_long_history()
  p <- fetch.plot.pmc(sm, from = NULL, to = NULL, sport = "running")
  # Suppress pre-existing geom_rect(xmin = -Inf, xmax = Inf) warning on
  # Date scale — those infinity bounds are accepted but ggplot warns.
  b <- suppressWarnings(ggplot2::ggplot_build(p))
  spans <- vapply(b$data, function(d) {
    if (is.null(d$x) || length(d$x) == 0) return(NA_real_)
    as.numeric(diff(range(suppressWarnings(as.Date(d$x, origin = "1970-01-01")),
                          na.rm = TRUE)))
  }, numeric(1))
  expect_gt(max(spans, na.rm = TRUE), 365)
})

test_that("fetch.plot.acwr with explicit 1y window stays within ~1y", {
  sm <- .fixture_long_history()
  to_d <- max(as.Date(sm$sessionStart))
  from_d <- to_d - 365
  p <- fetch.plot.acwr(sm, from = from_d, to = to_d, sport = "running")
  # Suppress pre-existing geom_rect(xmin = -Inf, xmax = Inf) warning on
  # Date scale — those infinity bounds are accepted but ggplot warns.
  b <- suppressWarnings(ggplot2::ggplot_build(p))
  # All non-empty layers should be within the 1-year window
  spans <- vapply(b$data, function(d) {
    if (is.null(d$x) || length(d$x) == 0) return(NA_real_)
    as.numeric(diff(range(suppressWarnings(as.Date(d$x, origin = "1970-01-01")),
                          na.rm = TRUE)))
  }, numeric(1))
  expect_lte(max(spans, na.rm = TRUE), 366)
})

test_that("plot_sport_calendar with NULL from/to spans the full history", {
  sm <- .fixture_long_history()
  p <- plot_sport_calendar(sm, from = NULL, to = NULL, sport = NULL)
  # The calendar uses a discrete year-week x-axis, so probe the title
  # (which embeds the resolved date window) instead of the geom data.
  # With NULL from, the lower bound should be the earliest session
  # (2022-01-01 in the fixture) — not Sys.Date()-366.
  expect_match(p$labels$title %||% "", "2022-01-01")
})
