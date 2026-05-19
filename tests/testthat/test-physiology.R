# Tests for R/physiology.R.

test_that("get_hr_rest returns one value per requested date", {
  rhr <- tibble::tibble(
    date = seq(as.Date("2026-01-01"), as.Date("2026-03-31"), by = "day"),
    rhr  = 50 + sin(seq_len(90) / 10) * 3
  )
  dates <- as.Date(c("2026-02-15", "2026-02-15", "2026-02-16", "2026-02-15"))
  out <- get_hr_rest(dates, rhr_data = rhr)
  expect_length(out, length(dates))
  # Duplicate dates resolve to the same value
  expect_equal(out[1], out[2])
  expect_equal(out[1], out[4])
  # Different date resolves to a different (very-close) window mean
  expect_false(identical(out[1], out[3]))
})

test_that("get_hr_rest matches a per-date reference implementation", {
  # Reference: the old vapply-per-element shape. The new code dedupes
  # over unique dates and maps back — must produce bit-identical
  # results for both unique and repeated date vectors.
  rhr <- tibble::tibble(
    date = seq(as.Date("2026-01-01"), as.Date("2026-04-30"), by = "day"),
    rhr  = 48 + cumsum(stats::runif(120, -0.1, 0.1))
  )
  reference <- function(date, rhr_data) {
    date <- as.Date(date)
    rhr_min <- min(rhr_data$date); rhr_max <- max(rhr_data$date)
    vapply(date, function(d) {
      if (d < rhr_min || d > rhr_max + 1) return(50)
      w <- rhr_data$rhr[rhr_data$date >= d - 30 & rhr_data$date <= d - 1]
      if (length(w) == 0) 50 else mean(w, na.rm = TRUE)
    }, numeric(1))
  }

  set.seed(7)
  dates <- sample(seq(as.Date("2026-01-15"), as.Date("2026-04-30"),
                       by = "day"), 200, replace = TRUE)
  withr::with_envvar(c("HR_REST" = ""), {
    expect_identical(get_hr_rest(dates, rhr_data = rhr),
                     reference(dates, rhr))
  })
})

test_that("get_hr_rest returns scalar fallback when no AW data", {
  withr::with_envvar(c("HR_REST" = ""), {
    out <- get_hr_rest(as.Date(c("2026-01-01", "2026-01-02")),
                       rhr_data = tibble::tibble(date = as.Date(character(0)),
                                                  rhr = numeric(0)))
    expect_equal(out, c(50, 50))
  })
})

test_that("get_hr_rest honours HR_REST env override for missing data", {
  withr::with_envvar(c("HR_REST" = "55"), {
    out <- get_hr_rest(as.Date("2020-01-01"),
                       rhr_data = tibble::tibble(date = as.Date(character(0)),
                                                  rhr = numeric(0)))
    expect_equal(out, 55)
  })
})
