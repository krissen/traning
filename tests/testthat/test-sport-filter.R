# Tests for R/sport_filter.R

.fixture <- function() {
  data.frame(
    sport = c("running", "running", "cycling", "cycling", "walking",
              "swimming", "strength", "badminton", "bordtennis", "ovrigt"),
    distance = c(5000, 8000, 25000, 12000, 3000, 1500, 0, 0, 0, 0),
    stringsAsFactors = FALSE
  )
}

test_that(".resolve_sport_bucket handles direct sport names", {
  expect_equal(traning:::.resolve_sport_bucket("running"), "running")
  expect_equal(traning:::.resolve_sport_bucket("cycling"), "cycling")
  expect_equal(traning:::.resolve_sport_bucket("walking"), "walking")
})

test_that(".resolve_sport_bucket handles Swedish aliases", {
  expect_equal(traning:::.resolve_sport_bucket("löpning"), "running")
  expect_equal(traning:::.resolve_sport_bucket("lopning"), "running")
  expect_equal(traning:::.resolve_sport_bucket("cykling"), "cycling")
  expect_equal(traning:::.resolve_sport_bucket("gång"), "walking")
  expect_equal(traning:::.resolve_sport_bucket("gang"), "walking")
})

test_that(".resolve_sport_bucket expands curated buckets", {
  expect_setequal(traning:::.resolve_sport_bucket("endurance"),
                  c("running", "cycling", "walking", "swimming"))
  expect_setequal(traning:::.resolve_sport_bucket("ballsport"),
                  c("badminton", "bordtennis", "fotboll", "tennis",
                    "paddelsporter", "hockey", "fitness-spel"))
  expect_setequal(traning:::.resolve_sport_bucket("gym"),
                  c("strength", "karntraning", "ovrigt"))
})

test_that(".resolve_sport_bucket returns NULL for all/any/NULL", {
  expect_null(traning:::.resolve_sport_bucket("all"))
  expect_null(traning:::.resolve_sport_bucket("any"))
  expect_null(traning:::.resolve_sport_bucket(NULL))
  expect_null(traning:::.resolve_sport_bucket(character(0)))
})

test_that(".resolve_sport_bucket combines vector inputs", {
  expect_setequal(traning:::.resolve_sport_bucket(c("running", "cycling")),
                  c("running", "cycling"))
  expect_setequal(traning:::.resolve_sport_bucket(c("löpning", "cykling")),
                  c("running", "cycling"))
  expect_setequal(traning:::.resolve_sport_bucket(c("endurance", "strength")),
                  c("running", "cycling", "walking", "swimming", "strength"))
})

test_that(".filter_sport keeps only matching rows", {
  df <- .fixture()
  expect_equal(nrow(traning:::.filter_sport(df, "running")), 2)
  expect_equal(nrow(traning:::.filter_sport(df, "cycling")), 2)
  expect_equal(nrow(traning:::.filter_sport(df, "walking")), 1)
})

test_that(".filter_sport with curated bucket pulls all matching sports", {
  df <- .fixture()
  result <- traning:::.filter_sport(df, "endurance")
  # 2 running + 2 cycling + 1 walking + 1 swimming = 6
  expect_equal(nrow(result), 6)
  expect_setequal(result$sport, c("running", "cycling", "walking", "swimming"))
})

test_that(".filter_sport with 'all' returns everything", {
  df <- .fixture()
  expect_equal(nrow(traning:::.filter_sport(df, "all")), nrow(df))
  expect_equal(nrow(traning:::.filter_sport(df, NULL)), nrow(df))
})

test_that(".filter_sport with vector matches union", {
  df <- .fixture()
  result <- traning:::.filter_sport(df, c("running", "cycling"))
  expect_equal(nrow(result), 4)
  expect_setequal(result$sport, c("running", "cycling"))
})

test_that(".filter_sport handles substring matches like trackeR's variants", {
  # trackeR sometimes emits "trail running", "outdoor running" etc.
  df <- data.frame(
    sport = c("running", "trail running", "outdoor running", "cycling"),
    stringsAsFactors = FALSE
  )
  expect_equal(nrow(traning:::.filter_sport(df, "running")), 3)
})

test_that(".filter_sport returns empty data frame when sport column missing", {
  df <- data.frame(distance = c(1000, 2000), stringsAsFactors = FALSE)
  result <- traning:::.filter_sport(df, "running")
  expect_equal(nrow(result), 0)
})
