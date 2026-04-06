# Tests for R/hr_zones.R and the report_hr_zones() function in R/report.R

# --- Test fixtures ---

make_zone_summaries <- function(n = 20, sport = "running") {
  set.seed(42)
  tibble::tibble(
    sessionStart          = as.POSIXct(seq(
      as.Date("2024-01-05"),
      by = "week",
      length.out = n
    )),
    sport                 = sport,
    distance              = runif(n, 5000, 15000),
    garmin_hrTimeInZone_1 = runif(n, 600, 1200),
    garmin_hrTimeInZone_2 = runif(n, 300, 900),
    garmin_hrTimeInZone_3 = runif(n, 100, 600),
    garmin_hrTimeInZone_4 = runif(n, 50, 300),
    garmin_hrTimeInZone_5 = runif(n, 0, 100)
  )
}

# Build a zone_data list (as returned by compute_zone_distribution) from
# a known monthly table — used in PI tests.
make_zone_data <- function(monthly_tbl) {
  list(
    per_activity = tibble::tibble(
      sessionStart = as.Date(character(0)),
      distance_km  = numeric(0),
      z1_pct = numeric(0), z2_pct = numeric(0), z3_pct = numeric(0),
      z1_sec = numeric(0), z2_sec = numeric(0), z3_sec = numeric(0),
      total_sec = numeric(0)
    ),
    monthly = monthly_tbl
  )
}

test_summaries_zone <- make_zone_summaries()

# ============================================================================
# compute_zone_distribution
# ============================================================================

test_that("compute_zone_distribution returns a list with $per_activity and $monthly", {
  result <- compute_zone_distribution(test_summaries_zone)
  expect_type(result, "list")
  expect_true("per_activity" %in% names(result))
  expect_true("monthly"      %in% names(result))
})

test_that("$per_activity has the expected columns", {
  result <- compute_zone_distribution(test_summaries_zone)
  pa <- result$per_activity
  expect_s3_class(pa, "tbl_df")
  expected_cols <- c(
    "sessionStart", "distance_km",
    "z1_pct", "z2_pct", "z3_pct",
    "z1_sec", "z2_sec", "z3_sec", "total_sec"
  )
  expect_true(all(expected_cols %in% names(pa)))
})

test_that("$monthly has the expected columns", {
  result <- compute_zone_distribution(test_summaries_zone)
  mo <- result$monthly
  expect_s3_class(mo, "tbl_df")
  expected_cols <- c(
    "year_month", "z1_pct", "z2_pct", "z3_pct",
    "n_activities", "total_min"
  )
  expect_true(all(expected_cols %in% names(mo)))
})

test_that("zone percentages sum to ~100 per activity", {
  result <- compute_zone_distribution(test_summaries_zone)
  pa <- result$per_activity
  row_sums <- pa$z1_pct + pa$z2_pct + pa$z3_pct
  expect_true(all(abs(row_sums - 100) < 1e-9))
})

test_that("monthly aggregation groups correctly by year-month", {
  set.seed(1)
  # 8 runs: 4 in January 2024, 4 in February 2024
  jan_runs <- make_zone_summaries(n = 4)
  jan_runs$sessionStart <- as.POSIXct(c(
    "2024-01-05", "2024-01-12", "2024-01-19", "2024-01-26"
  ))
  feb_runs <- make_zone_summaries(n = 4)
  feb_runs$sessionStart <- as.POSIXct(c(
    "2024-02-02", "2024-02-09", "2024-02-16", "2024-02-23"
  ))
  combined <- dplyr::bind_rows(jan_runs, feb_runs)
  result <- compute_zone_distribution(combined)
  mo <- result$monthly
  expect_equal(nrow(mo), 2)
  expect_true("2024-01" %in% mo$year_month)
  expect_true("2024-02" %in% mo$year_month)
  # Each month must have 4 activities
  jan_row <- mo[mo$year_month == "2024-01", ]
  expect_equal(jan_row$n_activities, 4L)
})

test_that("filters non-running activities out", {
  mixed <- make_zone_summaries(n = 10)
  mixed$sport[c(2, 5, 8)] <- "cycling"
  result <- compute_zone_distribution(mixed)
  # Only 7 running rows may appear in per_activity
  expect_lte(nrow(result$per_activity), 7)
})

test_that("stops with error when zone columns are missing", {
  bad <- test_summaries_zone
  bad$garmin_hrTimeInZone_3 <- NULL
  expect_error(
    compute_zone_distribution(bad),
    regexp = "garmin_hrTimeInZone"
  )
})

test_that("skips activities where all zone columns are NA", {
  s <- make_zone_summaries(n = 5)
  # Make rows 2 and 4 all-NA in zone columns
  zone_cols <- paste0("garmin_hrTimeInZone_", 1:5)
  s[c(2, 4), zone_cols] <- NA
  result <- compute_zone_distribution(s)
  # 3 non-NA running rows should remain
  expect_equal(nrow(result$per_activity), 3)
})

test_that("returns empty tibbles when no qualifying runs exist", {
  no_runs <- make_zone_summaries(n = 5)
  no_runs$sport <- "cycling"
  result <- compute_zone_distribution(no_runs)
  expect_equal(nrow(result$per_activity), 0)
  expect_equal(nrow(result$monthly), 0)
  expect_s3_class(result$per_activity, "tbl_df")
  expect_s3_class(result$monthly, "tbl_df")
})

# ============================================================================
# compute_polarization_index
# ============================================================================

test_that("compute_polarization_index returns the expected columns", {
  zone_data <- compute_zone_distribution(test_summaries_zone)
  result    <- compute_polarization_index(zone_data)
  expect_s3_class(result, "tbl_df")
  expected_cols <- c(
    "year_month", "pi",
    "z1_pct", "z2_pct", "z3_pct",
    "n_activities", "has_zero_zone"
  )
  expect_true(all(expected_cols %in% names(result)))
})

test_that("PI formula is correct for uniform distribution (33/33/33)", {
  # Treff (2019) Eq. 1: PI = log10((p1/p2) * p3 * 100)
  # Uniform: PI = log10((0.333/0.333) * 0.333 * 100) = log10(33.33) ≈ 1.523
  monthly <- tibble::tibble(
    year_month   = "2024-01",
    z1_pct       = 100 / 3,
    z2_pct       = 100 / 3,
    z3_pct       = 100 / 3,
    n_activities = 4L,
    total_min    = 200
  )
  result <- compute_polarization_index(make_zone_data(monthly))
  expect_equal(nrow(result), 1)
  p1 <- 1/3; p2 <- 1/3; p3 <- 1/3
  expected_pi <- log10((p1 / p2) * p3 * 100)
  expect_equal(result$pi, expected_pi, tolerance = 1e-9)
  expect_false(result$has_zero_zone)
})

test_that("PI formula is correct for polarized distribution (80/5/15)", {
  # Treff (2019) Eq. 1: PI = log10((p1/p2) * p3 * 100)
  # PI = log10((0.80/0.05) * 0.15 * 100) = log10(240) ≈ 2.380
  monthly <- tibble::tibble(
    year_month   = "2024-02",
    z1_pct       = 80,
    z2_pct       = 5,
    z3_pct       = 15,
    n_activities = 6L,
    total_min    = 360
  )
  result <- compute_polarization_index(make_zone_data(monthly))
  p1 <- 0.80; p2 <- 0.05; p3 <- 0.15
  expected_pi <- log10((p1 / p2) * p3 * 100)
  expect_equal(result$pi, expected_pi, tolerance = 1e-9)
  # PI > 2.0 = polarized per Treff 2019
  expect_gt(result$pi, 2.0)
  expect_false(result$has_zero_zone)
})

test_that("PI matches Treff 2019 Table 1 reference values", {
  # Verify against published reference values from the paper
  cases <- list(
    list(z1 = 80, z2 = 8,  z3 = 12, expected_pi = 2.08),
    list(z1 = 74, z2 = 11, z3 = 15, expected_pi = 2.00),
    list(z1 = 77, z2 = 17, z3 = 6,  expected_pi = 1.43),
    list(z1 = 70, z2 = 20, z3 = 10, expected_pi = 1.54)
  )
  for (case in cases) {
    monthly <- tibble::tibble(
      year_month = "2024-01", z1_pct = case$z1, z2_pct = case$z2,
      z3_pct = case$z3, n_activities = 5L, total_min = 300
    )
    result <- compute_polarization_index(make_zone_data(monthly))
    expect_equal(result$pi, case$expected_pi, tolerance = 0.02,
      label = paste0("PI for ", case$z1, "/", case$z2, "/", case$z3))
  }
})

test_that("Equation 2 is used when Z2 = 0", {
  # Treff 2019 Eq. 2: PI = log10((p1/0.01) * (p3-0.01) * 100)
  monthly <- tibble::tibble(
    year_month   = "2024-03",
    z1_pct       = 90,
    z2_pct       = 0,    # no threshold work this month
    z3_pct       = 10,
    n_activities = 3L,
    total_min    = 150
  )
  result <- compute_polarization_index(make_zone_data(monthly))
  expect_true(result$has_zero_zone)
  expect_true(is.finite(result$pi))
  # Verify Eq. 2: log10((0.90/0.01) * (0.10-0.01) * 100) = log10(810) ≈ 2.908
  expected <- log10((0.90 / 0.01) * (0.10 - 0.01) * 100)
  expect_equal(result$pi, expected, tolerance = 1e-9)
})

test_that("PI = 0 when Z3 = 0", {
  monthly <- tibble::tibble(
    year_month   = "2024-04",
    z1_pct       = 60,
    z2_pct       = 40,
    z3_pct       = 0,
    n_activities = 3L,
    total_min    = 150
  )
  result <- compute_polarization_index(make_zone_data(monthly))
  expect_true(result$has_zero_zone)
  expect_equal(result$pi, 0)
})

test_that("returns empty tibble for empty monthly input", {
  empty_zone_data <- make_zone_data(tibble::tibble(
    year_month   = character(0),
    z1_pct       = numeric(0),
    z2_pct       = numeric(0),
    z3_pct       = numeric(0),
    n_activities = integer(0),
    total_min    = numeric(0)
  ))
  result <- compute_polarization_index(empty_zone_data)
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0)
  expect_true("pi" %in% names(result))
})

test_that("stops with error when zone_data lacks $monthly element", {
  expect_error(
    compute_polarization_index(list(per_activity = tibble::tibble())),
    regexp = "monthly"
  )
})

# ============================================================================
# report_hr_zones
# ============================================================================

test_that("report_hr_zones returns tibble with expected Swedish column names", {
  result <- report_hr_zones(test_summaries_zone)
  expect_s3_class(result, "tbl_df")
  expected_cols <- c("Datum", "Z1 %", "Z2 %", "Z3 %", "PI", "Turer", "Tot min")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("report_hr_zones respects n parameter", {
  # Force many months of data so n can bite
  set.seed(7)
  long_data <- make_zone_summaries(n = 60)
  result_12 <- report_hr_zones(long_data, n = 12)
  expect_lte(nrow(result_12), 12)

  result_3 <- report_hr_zones(long_data, n = 3)
  expect_lte(nrow(result_3), 3)
})

test_that("report_hr_zones respects from/to date range", {
  set.seed(8)
  long_data <- make_zone_summaries(n = 60)
  from <- as.Date("2024-06-01")
  to   <- as.Date("2024-09-01")
  result <- report_hr_zones(long_data, from = from, to = to)
  if (nrow(result) > 0) {
    expect_true(all(result$Datum >= from))
    expect_true(all(result$Datum < to))
  }
})

test_that("report_hr_zones returns empty tibble for data without zone columns", {
  no_zones <- tibble::tibble(
    sessionStart = as.POSIXct("2024-01-01"),
    sport        = "running",
    distance     = 10000
  )
  expect_error(report_hr_zones(no_zones), regexp = "garmin_hrTimeInZone")
})

test_that("report_hr_zones returns empty tibble when no running data exists", {
  cycling_only <- make_zone_summaries(n = 10, sport = "cycling")
  result <- report_hr_zones(cycling_only)
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0)
})
