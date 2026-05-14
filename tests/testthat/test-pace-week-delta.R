# Tests for fetch.plot.pace_week_delta() — Träning-flikens nya kort.

.fixture_pace_delta_runs <- function(n_weeks = 12) {
  base <- as.POSIXct("2025-01-06 06:00:00", tz = "UTC")  # Monday
  # 3 runs per week for n_weeks
  rows <- vector("list", n_weeks * 3)
  k <- 1
  for (w in seq_len(n_weeks)) {
    for (d in c(0, 2, 4)) {  # Mon, Wed, Fri
      rows[[k]] <- list(
        sessionStart = base + (w - 1L) * 86400 * 7 + d * 86400,
        sport = "running",
        distance = 8000,
        durationMoving = as.difftime(45, units = "mins"),
        avgSpeedMoving = 3.0,
        # Pace alternates per week to give a non-zero delta
        avgPaceMoving = 5.0 + (w %% 2) * 0.4 + d * 0.05,
        avgHeartRateMoving = 145
      )
      k <- k + 1
    }
  }
  do.call(rbind, lapply(rows, as.data.frame))
}

test_that("fetch.plot.pace_week_delta returns a ggplot for normal input", {
  sm <- .fixture_pace_delta_runs(8)
  p <- fetch.plot.pace_week_delta(sm, from = NULL, to = NULL,
                                   sport = "running")
  expect_s3_class(p, "ggplot")
  # Building it should not error
  b <- ggplot2::ggplot_build(p)
  # At least one geom_col layer with rows
  col_rows <- vapply(b$data, nrow, integer(1))
  expect_true(any(col_rows > 0))
})

test_that("pace_week_delta produces a delta per week (n - 1 bars)", {
  sm <- .fixture_pace_delta_runs(8)
  p <- fetch.plot.pace_week_delta(sm, from = NULL, to = NULL,
                                   sport = "running")
  b <- ggplot2::ggplot_build(p)
  # The geom_col layer rows = number of weeks with a defined delta
  # (all weeks except the first). Hline contributes a 1-row layer.
  col_rows <- max(vapply(b$data, nrow, integer(1)))
  # 8 weeks → 7 deltas
  expect_equal(col_rows, 7L)
})

test_that("pace_week_delta returns placeholder when too few runs", {
  sm <- .fixture_pace_delta_runs(8)[1:3, , drop = FALSE]
  p <- fetch.plot.pace_week_delta(sm, sport = "running")
  expect_s3_class(p, "ggplot")
  # Empty placeholder uses the explicit "För få pass" title
  expect_match(p$labels$title %||% "", "För få pass")
})

test_that("pace_week_delta respects from/to window", {
  sm <- .fixture_pace_delta_runs(12)
  to_d   <- as.Date("2025-02-28")
  from_d <- as.Date("2025-02-01")
  p <- fetch.plot.pace_week_delta(sm, from = from_d, to = to_d,
                                   sport = "running")
  expect_s3_class(p, "ggplot")
  b <- ggplot2::ggplot_build(p)
  # All bar x values should sit inside the window
  for (d in b$data) {
    if (is.null(d$x) || nrow(d) == 0) next
    xs <- suppressWarnings(as.Date(d$x, origin = "1970-01-01"))
    if (all(is.na(xs))) next
    expect_true(all(xs >= from_d - 7, na.rm = TRUE))
    expect_true(all(xs <= to_d + 7, na.rm = TRUE))
  }
})
