# Tests for compute_fun_facts() — Översikt-tab Trivia accordion.

.fixture_facts_summaries <- function() {
  base <- as.POSIXct("2020-03-15 06:00:00", tz = "UTC")
  data.frame(
    sessionStart = c(
      base,                          # first run
      base + 86400 * 5,              # 5 days later
      base + 86400 * 120,            # 4 months later (longest gap = 115 d)
      base + 86400 * 121,
      base + 86400 * 200,
      base + 86400 * 365 * 2         # 2 years after start
    ),
    sport = c("running", "running", "running", "cycling",
              "running", "strength"),
    distance = c(8000, 5500, 21000, 30000, 10500, 0),
    durationMoving = as.difftime(c(45, 28, 110, 60, 55, 40), units = "mins"),
    avgSpeedMoving = c(3.0, 3.3, 3.2, 8.3, 3.2, NA),
    avgPaceMoving = c(5.5, 5.0, 5.2, 2.0, 5.2, NA),
    avgHeartRateMoving = c(140, 150, 145, 135, 148, 110),
    stringsAsFactors = FALSE
  )
}

test_that("compute_fun_facts returns a list of named facts", {
  facts <- compute_fun_facts(.fixture_facts_summaries())
  expect_type(facts, "list")
  expect_true(length(facts) >= 4)
  expect_true("first_session" %in% names(facts))
  expect_true("longest_gap" %in% names(facts))
  expect_true("longest_run" %in% names(facts))
  expect_true("total_per_sport" %in% names(facts))
  # Each entry has $string and $value
  for (n in names(facts)) {
    expect_true("string" %in% names(facts[[n]]),
                info = paste("missing $string in", n))
    expect_true("value" %in% names(facts[[n]]),
                info = paste("missing $value in", n))
    expect_type(facts[[n]]$string, "character")
  }
})

test_that("compute_fun_facts identifies the first session correctly", {
  facts <- compute_fun_facts(.fixture_facts_summaries())
  expect_equal(as.Date(facts$first_session$value),
               as.Date("2020-03-15"))
})

test_that("compute_fun_facts identifies longest gap between runs", {
  facts <- compute_fun_facts(.fixture_facts_summaries())
  # Fixture: runs at days 0, 5, 120 → max gap = 115 days
  expect_gte(facts$longest_gap$value, 110)
  expect_lte(facts$longest_gap$value, 120)
})

test_that("compute_fun_facts identifies the longest single run", {
  facts <- compute_fun_facts(.fixture_facts_summaries())
  # Fixture: longest is 21 km
  expect_equal(round(facts$longest_run$value, 1), 21.0)
})

test_that("compute_fun_facts handles empty input", {
  expect_equal(length(compute_fun_facts(NULL)), 0L)
  expect_equal(length(compute_fun_facts(.fixture_facts_summaries()[0, ])), 0L)
})

test_that("compute_fun_facts handles NA sport on the first session", {
  # Regression: sport_label() falls back to paste0(NA, NA) = "NANA" on
  # NA_character_, producing "Första registrerade passet: <date> (NANA)".
  # compute_fun_facts now substitutes the generic "Aktivitet" label.
  sm <- data.frame(
    sessionStart       = as.POSIXct("2020-01-01"),
    sport              = NA_character_,
    distance           = 5000,
    durationMoving     = as.difftime(30, units = "mins"),
    avgSpeedMoving     = 3,
    avgPaceMoving      = 5.5,
    avgHeartRateMoving = 140,
    stringsAsFactors   = FALSE
  )
  facts <- compute_fun_facts(sm)
  expect_match(facts$first_session$string, "\\(Aktivitet\\)")
  expect_no_match(facts$first_session$string, "NANA")
})
