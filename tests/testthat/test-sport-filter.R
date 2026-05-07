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

# --- .sport_match_mask --------------------------------------------------------

test_that(".sport_match_mask returns logical vector of nrow(summaries)", {
  df <- .fixture()
  mask <- traning:::.sport_match_mask(df, "running")
  expect_type(mask, "logical")
  expect_length(mask, nrow(df))
})

test_that(".sport_match_mask matches the same rows as .filter_sport", {
  df <- .fixture()
  for (s in c("running", "cycling", "endurance",
              c("running", "cycling"), "all", NULL, "")) {
    mask <- traning:::.sport_match_mask(df, s)
    filtered <- traning:::.filter_sport(df, s)
    expect_equal(sum(mask), nrow(filtered),
                 info = paste("sport=", deparse(s)))
  }
})

test_that(".sport_match_mask treats NULL/all/any/character(0) as match-all", {
  df <- .fixture()
  expect_true(all(traning:::.sport_match_mask(df, NULL)))
  expect_true(all(traning:::.sport_match_mask(df, "all")))
  expect_true(all(traning:::.sport_match_mask(df, "any")))
  expect_true(all(traning:::.sport_match_mask(df, character(0))))
})

test_that(".sport_match_mask treats blank/NA as match-none", {
  df <- .fixture()
  expect_false(any(traning:::.sport_match_mask(df, "")))
  expect_false(any(traning:::.sport_match_mask(df, NA_character_)))
})

test_that(".sport_match_mask handles missing sport column", {
  df <- data.frame(distance = c(1000, 2000), stringsAsFactors = FALSE)
  expect_false(any(traning:::.sport_match_mask(df, "running")))
  # NULL still means "match all" — there are no sport-specific rows to filter
  expect_true(all(traning:::.sport_match_mask(df, NULL)))
})

test_that(".filter_sport returns empty (not pass-through) for blank/NA input", {
  # Regression: previously sport="" or sport=NA_character_ resolved to
  # character(0), Reduce produced NULL, and dplyr::filter with NULL was a
  # silent pass-through that returned every row.  Only NULL / "all" / "any"
  # are documented as "no filter".
  df <- .fixture()
  expect_equal(nrow(traning:::.filter_sport(df, "")), 0)
  expect_equal(nrow(traning:::.filter_sport(df, NA_character_)), 0)
  expect_equal(nrow(traning:::.filter_sport(df, c(NA_character_, ""))), 0)
})

test_that(".filter_sport handles values containing regex metacharacters", {
  # Regression: previously buckets were concatenated into a regex pattern
  # without escaping, so values like "running (treadmill)" would be parsed
  # as a regex group and fail to match a literal label.
  df <- data.frame(
    sport = c("running (treadmill)", "running", "cycling.indoor",
              "swimming|open"),
    stringsAsFactors = FALSE
  )
  # "running" should match both literal "running" and the parenthesised one
  expect_equal(nrow(traning:::.filter_sport(df, "running")), 2)
  # "cycling.indoor" must match a sport with a literal dot
  expect_equal(nrow(traning:::.filter_sport(df, "cycling.indoor")), 1)
  # Pipe character is regex alternation; must be matched literally
  expect_equal(nrow(traning:::.filter_sport(df, "swimming|open")), 1)
})

test_that(".sport_label_sv returns Swedish display labels", {
  expect_equal(traning:::.sport_label_sv("running"), "Löpning")
  expect_equal(traning:::.sport_label_sv("cycling"), "Cykling")
  expect_equal(traning:::.sport_label_sv("walking"), "Gång")
  expect_equal(traning:::.sport_label_sv("swimming"), "Simning")
  expect_equal(traning:::.sport_label_sv("strength"), "Styrketräning")
})

test_that(".sport_label_sv falls back gracefully", {
  expect_equal(traning:::.sport_label_sv(NULL), "Aktivitet")
  expect_equal(traning:::.sport_label_sv("all"), "Aktivitet")
  expect_equal(traning:::.sport_label_sv(c("running", "cycling")), "Aktivitet")
  # Unknown sport: capitalize first letter
  expect_equal(traning:::.sport_label_sv("yoga"), "Yoga")
})
