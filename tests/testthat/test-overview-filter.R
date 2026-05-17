# Tests för dot-prefixade range-filter som driver Översiktens mini-grafer
# (`mod_overview.R`). Filtrerings-logiken ligger i `R/shiny_helpers.R`
# så att den kan testas utan att starta Shiny. Anropas via `traning:::`
# för att matcha konventionen i resten av sviten (test-readiness.R m.fl.)
# och vara robust mot `R CMD check` mot installerat paket.
#
# `.filter_readiness_range` använder inklusivt intervall [from, to] —
# readiness är dagliga aggregat (en rad per kalenderdag), och inklusiv
# övre gräns krävs för att KPI-boxens slice_max(date) ska matcha
# mini-grafens rightmost-punkt när to = Sys.Date().
# `.filter_running_range` behåller halvöppet [from, to) — sessionStart
# är POSIXct och en pågående löprunda exkluderas tills dagen är slut.

test_that(".filter_readiness_range avgränsar med from/to (inklusiv övre gräns)", {
  today <- as.Date("2026-05-16")
  rd <- data.frame(
    date             = today - (30:0),
    readiness_score  = c(rep(60, 31)),
    readiness_status = rep("Gul", 31)
  )

  # Inklusiv övre gräns — [today-7, today] ger 8 dagar: today-7 .. today
  out <- traning:::.filter_readiness_range(rd, from = today - 7, to = today)
  expect_equal(nrow(out), 8)
  expect_equal(min(out$date), today - 7)
  expect_equal(max(out$date), today)

  # Inklusiva intervall — `to = today - 10` (inklusiv): t.o.m. today-10
  out <- traning:::.filter_readiness_range(rd, from = NULL, to = today - 10)
  expect_equal(nrow(out), 21)
  expect_equal(max(out$date), today - 10)

  # Bara `from` satt, ingen övre gräns
  out <- traning:::.filter_readiness_range(rd, from = today - 5, to = NULL)
  expect_equal(nrow(out), 6)
  expect_equal(min(out$date), today - 5)
  expect_equal(max(out$date), today)

  # NULL/NULL = inget filter
  out <- traning:::.filter_readiness_range(rd, from = NULL, to = NULL)
  expect_equal(nrow(out), nrow(rd))
})

test_that(".filter_readiness_range hanterar tom/NULL input", {
  expect_null(traning:::.filter_readiness_range(NULL))
  empty <- data.frame(date = as.Date(character()), readiness_score = numeric())
  expect_equal(nrow(traning:::.filter_readiness_range(empty,
                                                     from = as.Date("2026-05-01"),
                                                     to   = as.Date("2026-05-16"))),
               0)
})

test_that("NA-gränser hanteras som NULL (rensad custom dateRangeInput)", {
  today <- as.Date("2026-05-16")
  rd <- data.frame(
    date            = today - (10:0),
    readiness_score = rep(60, 11)
  )

  # En tom dateRangeInput ger NA tillbaka från mod_date_preset.
  # `from = NA` / `to = NA` ska tolkas som "ingen gräns".
  out <- traning:::.filter_readiness_range(rd, from = NA, to = NA)
  expect_equal(nrow(out), nrow(rd))

  # NA `to` behandlas inklusivt: to = today - 5 inkluderar today - 5
  out <- traning:::.filter_readiness_range(rd, from = NA, to = today - 5)
  expect_equal(max(out$date), today - 5)

  out <- traning:::.filter_readiness_range(rd, from = today - 3, to = NA)
  expect_equal(min(out$date), today - 3)

  s <- data.frame(
    sessionStart = as.POSIXct("2026-05-16 06:00:00", tz = "UTC") -
                   as.difftime(0:9, units = "days"),
    sport        = rep("running", 10),
    distance     = rep(10000, 10)
  )
  out <- traning:::.filter_running_range(s, from = NA, to = NA)
  expect_equal(nrow(out), nrow(s))
})

test_that(".filter_readiness_range hoppar över NA-datum vid bounded filter", {
  today <- as.Date("2026-05-16")
  rd <- data.frame(
    date            = c(today - 1, NA, today - 5),
    readiness_score = c(70, 60, 50)
  )
  out <- traning:::.filter_readiness_range(rd, from = today - 6, to = today)
  # NA-datumet ska INTE komma med när vi har en explicit gräns.
  expect_equal(nrow(out), 2)
  expect_false(any(is.na(out$date)))
})

test_that("NA-datum droppas även när inga bounds är satta", {
  # "Allt"-preset → dr_from/dr_to = NULL. Tidigare lämnade hjälparna
  # kvar NA-datum, vilket gav `min(date)/max(date) = NA` i mini-graferna
  # och tappade band/staplar. Helpers ska alltid drop NA, matchar
  # `dplyr::filter`-semantiken.
  today <- as.Date("2026-05-16")
  rd <- data.frame(
    date            = c(today - 1, NA, today - 5),
    readiness_score = c(70, 60, 50)
  )
  out <- traning:::.filter_readiness_range(rd, from = NULL, to = NULL)
  expect_equal(nrow(out), 2)
  expect_false(any(is.na(out$date)))

  s <- data.frame(
    sessionStart = c(as.POSIXct("2026-05-15 06:00:00", tz = "UTC"),
                     NA,
                     as.POSIXct("2026-05-10 06:00:00", tz = "UTC")),
    sport        = rep("running", 3),
    distance     = c(10000, 5000, 8000)
  )
  out <- traning:::.filter_running_range(s, from = NULL, to = NULL)
  expect_equal(nrow(out), 2)
  expect_false(any(is.na(out$sessionStart)))
})

test_that(".filter_running_range avgränsar via sessionStart (halvöppet)", {
  base <- as.POSIXct("2026-05-16 06:00:00", tz = "UTC")
  s <- data.frame(
    sessionStart = base - as.difftime(0:19, units = "days"),
    sport        = rep("running", 20),
    distance     = rep(10000, 20)
  )
  today <- as.Date(base)

  # [today-7, today) ger 7 dagar — today exkluderas
  out <- traning:::.filter_running_range(s, from = today - 7, to = today)
  expect_equal(nrow(out), 7)
  expect_false(today %in% as.Date(out$sessionStart))

  # NULL/NULL = inget filter
  out <- traning:::.filter_running_range(s, from = NULL, to = NULL)
  expect_equal(nrow(out), nrow(s))

  # [today-14, today-7) ger 7 dagar — today-7 exkluderas
  out <- traning:::.filter_running_range(s, from = today - 14, to = today - 7)
  expect_equal(nrow(out), 7)
  expect_false((today - 7) %in% as.Date(out$sessionStart))
})

test_that(".filter_running_range hanterar tom/NULL input", {
  expect_null(traning:::.filter_running_range(NULL))
  empty <- data.frame(sessionStart = as.POSIXct(character()), sport = character())
  expect_equal(nrow(traning:::.filter_running_range(empty,
                                                   from = as.Date("2026-05-01"),
                                                   to   = as.Date("2026-05-16"))),
               0)
})

# --- Regressionstester: KPI vs mini-graf ska matcha ------------------------

test_that(".filter_readiness_range inkluderar today när to = Sys.Date()", {
  today <- Sys.Date()
  rd <- tibble::tibble(
    date = seq(today - 6, today, by = "day"),
    readiness_score = c(60, 65, 70, 72, 68, 74, 76)  # today = 76
  )
  out <- traning:::.filter_readiness_range(rd, from = today - 7, to = today)
  expect_equal(max(out$date), today)
  expect_true(today %in% out$date)
  # KPI:s slice_max(date) och grafens max(date) ska matcha
  kpi_today  <- rd |> dplyr::slice_max(date, n = 1) |> dplyr::pull(date)
  graph_today <- max(out$date)
  expect_equal(kpi_today, graph_today)
})

test_that("compute_readiness inkluderar today när before = Sys.Date()", {
  set.seed(7)
  today <- Sys.Date()
  # Bygg hälsodata som explicit inkluderar today (make_test_health genererar
  # bara till Sys.Date() - 1, så vi konstruerar manuellt)
  dates <- seq(today - 13, today, by = "day")
  n <- length(dates)
  hd <- dplyr::bind_rows(
    tibble::tibble(date = dates, metric = "heart_rate_variability",
                   value = rnorm(n, 50, 10), source = "AW"),
    tibble::tibble(date = dates, metric = "resting_heart_rate",
                   value = rnorm(n, 52, 3), source = "AW"),
    tibble::tibble(date = dates, metric = "sleep_totalSleep",
                   value = rnorm(n, 7.2, 0.8), source = "AW"),
    tibble::tibble(date = dates, metric = "sleep_deep",
                   value = pmax(0, rnorm(n, 0.8, 0.2)), source = "AW"),
    tibble::tibble(date = dates, metric = "sleep_rem",
                   value = pmax(0, rnorm(n, 1.5, 0.3)), source = "AW")
  )
  run_dates <- seq(today - 13, today - 1, by = "day")
  s <- tibble::tibble(
    sessionStart = as.POSIXct(run_dates),
    sport = "running",
    distance = runif(length(run_dates), 5000, 15000),
    durationMoving = runif(length(run_dates), 1800, 5400),
    avgPaceMoving = runif(length(run_dates), 5, 7),
    avgSpeedMoving = runif(length(run_dates), 2.5, 3.5),
    avgHeartRateMoving = runif(length(run_dates), 130, 160),
    file = paste0("test_", seq_len(length(run_dates)), ".tcx"),
    year = format(run_dates, "%Y"),
    month = format(run_dates, "%m"),
    total_elevation_gain = runif(length(run_dates), 20, 100)
  )
  result <- suppressWarnings(compute_readiness(hd, s, before = today))
  # compute_readiness ska inkludera today i resultatet när before = today
  if (nrow(result) > 0) {
    expect_true(today %in% result$date,
      info = "compute_readiness ska inkludera today när before = today")
  }
})
