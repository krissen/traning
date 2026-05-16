# Tests för dot-prefixade range-filter som driver Översiktens mini-grafer
# (`mod_overview.R`). Filtrerings-logiken ligger i `R/shiny_helpers.R`
# så att den kan testas utan att starta Shiny. Anropas via `traning:::`
# för att matcha konventionen i resten av sviten (test-readiness.R m.fl.)
# och vara robust mot `R CMD check` mot installerat paket.
#
# Båda helpers använder halvöppet intervall [from, to) — samma
# konvention som `.filter_date_range()` och `filter_by_daterange()`.

test_that(".filter_readiness_range avgränsar med from/to (halvöppet)", {
  today <- as.Date("2026-05-16")
  rd <- data.frame(
    date             = today - (30:0),
    readiness_score  = c(rep(60, 31)),
    readiness_status = rep("Gul", 31)
  )

  # Bounded — [today-7, today) ger 7 dagar: today-7 .. today-1
  out <- traning:::.filter_readiness_range(rd, from = today - 7, to = today)
  expect_equal(nrow(out), 7)
  expect_equal(min(out$date), today - 7)
  expect_equal(max(out$date), today - 1)

  # Halvöppna intervall — `to = today - 10` (exklusiv): t.o.m. today-11
  out <- traning:::.filter_readiness_range(rd, from = NULL, to = today - 10)
  expect_equal(nrow(out), 20)
  expect_equal(max(out$date), today - 11)

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
