# Tests verifying that report_* honour the sport= parameter.

.multisport_summaries <- function() {
  base <- as.POSIXct("2026-01-01 08:00:00", tz = "UTC")
  data.frame(
    sessionStart = base + (0:11) * 86400,  # 12 daily sessions
    sport = c("running", "cycling", "walking", "running",
              "cycling", "running", "walking", "cycling",
              "running", "cycling", "walking", "running"),
    distance = c(8000, 25000, 3000, 6000,
                 15000, 10000, 4000, 30000,
                 7000, 20000, 2500, 8500),
    avgPaceMoving = c(5.0, 2.4, 12.0, 5.2,
                      2.5, 4.8, 11.5, 2.3,
                      5.1, 2.4, 12.5, 5.0),
    avgHeartRateMoving = c(140, 130, 95, 142,
                           135, 138, 100, 132,
                           145, 128, 92, 140),
    durationMoving = as.difftime(
      c(40, 60, 36, 31, 38, 48, 46, 70, 36, 50, 31, 42),
      units = "mins"),
    stringsAsFactors = FALSE
  )
}

test_that("report_monthtop default returns running only (back-compat)", {
  df <- .multisport_summaries()
  result <- report_monthtop(df)
  # 5 running entries: 8 + 6 + 10 + 7 + 8.5 = 39.5 km
  expect_equal(nrow(result), 1)
  expect_equal(result$`Km, tot`[1], 39.5)
})

test_that("report_monthtop sport='cycling' returns cycling only", {
  df <- .multisport_summaries()
  result <- report_monthtop(df, sport = "cycling")
  # 4 cycling entries: 25 + 15 + 30 + 20 = 90 km
  expect_equal(nrow(result), 1)
  expect_equal(result$`Km, tot`[1], 90.0)
  expect_equal(result$Turer[1], 4)
})

test_that("report_monthtop sport='all' aggregates everything", {
  df <- .multisport_summaries()
  result <- report_monthtop(df, sport = "all")
  total_km <- sum(df$distance) / 1000
  expect_equal(result$`Km, tot`[1], round(total_km, 1))
  expect_equal(result$Turer[1], 12)
})

test_that("report_monthtop sport='endurance' picks running+cycling+walking", {
  df <- .multisport_summaries()
  result <- report_monthtop(df, sport = "endurance")
  # All 12 are running/cycling/walking
  expect_equal(result$Turer[1], 12)
})

test_that("report_yearstop sport='cycling' returns cycling totals", {
  df <- .multisport_summaries()
  result <- report_yearstop(df, sport = "cycling")
  expect_equal(nrow(result), 1)
  expect_equal(result$Turer[1], 4)
  expect_equal(result$`Km, tot`[1], 90.0)
})

test_that("report_datesum honours sport filter", {
  df <- .multisport_summaries()
  result <- report_datesum(
    df,
    do_datesum_from = as.POSIXct("2026-01-01 00:00:00", tz = "UTC"),
    do_datesum_to   = as.POSIXct("2026-01-13 00:00:00", tz = "UTC"),
    sport = "walking"
  )
  # 3 walking entries: 3 + 4 + 2.5 = 9.5 km
  expect_equal(result$Turer[1], 3)
  expect_equal(result$`Km, tot`[1], 9.5)
})

test_that("report_runs_year_month returns sessions for any sport", {
  df <- .multisport_summaries()
  result <- report_runs_year_month(
    df, sport = "cycling",
    from = as.Date("2026-01-01"),
    to = as.Date("2026-02-01")
  )
  expect_equal(nrow(result), 4)
})

test_that("report_insight uses sport-neutral labels", {
  df <- .multisport_summaries()
  # Cycling should produce "Cykling …", not "Löpning …"
  txt_cyk <- report_insight(df, sport = "cycling")
  expect_match(txt_cyk, "^Cykling ")
  expect_false(grepl("Löpning", txt_cyk))

  # Walking should produce "Gång …"
  txt_gng <- report_insight(df, sport = "walking")
  expect_match(txt_gng, "^Gång ")

  # Default still says "Löpning" (back-compat)
  txt_run <- report_insight(df)
  expect_match(txt_run, "^Löpning ")
})

test_that("report_insight handles unknown sport gracefully", {
  df <- .multisport_summaries()
  txt <- report_insight(df, sport = "fictional_sport_xyz")
  expect_equal(txt, "Ingen data.")
})

test_that("report_insight does not crash when latest pace is NA", {
  # Regression: strength/gym sessions and HAE rows without HR data leave
  # avgPaceMoving as NA; previously dec_to_mmss(NA) raised
  # "missing value where TRUE/FALSE needed".
  df <- data.frame(
    sessionStart = as.POSIXct(c("2026-01-10", "2026-01-12"), tz = "UTC"),
    sport = c("strength", "strength"),
    distance = c(0, 0),
    avgPaceMoving = c(NA_real_, NA_real_),
    avgHeartRateMoving = c(NA_real_, NA_real_),
    durationMoving = as.difftime(c(45, 50), units = "mins"),
    stringsAsFactors = FALSE
  )
  txt <- report_insight(df, sport = "strength")
  expect_type(txt, "character")
  expect_true(nchar(txt) > 0)
  # No "NA/km" fragment — pace is omitted when missing
  expect_false(grepl("NA/km", txt))
  expect_false(grepl("puls NA", txt))
})

test_that("report_insight handles partial NA (HR present, pace absent)", {
  df <- data.frame(
    sessionStart = as.POSIXct(c("2026-01-10"), tz = "UTC"),
    sport = "strength",
    distance = 0,
    avgPaceMoving = NA_real_,
    avgHeartRateMoving = 130,
    durationMoving = as.difftime(45, units = "mins"),
    stringsAsFactors = FALSE
  )
  txt <- report_insight(df, sport = "strength")
  expect_match(txt, "puls 130")
  expect_false(grepl("/km", txt))
})
