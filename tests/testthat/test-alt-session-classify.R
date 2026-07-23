# Tests for R/alt_session_classify.R

.alt_session <- function(sport = "paddelsporter", min = 60, hr = 120) {
  tibble::tibble(
    sessionStart = as.POSIXct("2026-07-21 09:00", tz = "UTC"),
    sport = sport,
    distance = 4240,
    avgPaceMoving = NA_real_,
    avgHeartRateMoving = hr,
    durationMoving = as.difftime(min, units = "mins")
  )
}

# --- Intensity bands ---------------------------------------------------------

test_that(".alt_intensity_band breaks exactly at 82% and 88% HRmax", {
  expect_equal(traning:::.alt_intensity_band(0.8199), "low")
  expect_equal(traning:::.alt_intensity_band(0.82), "moderate")
  expect_equal(traning:::.alt_intensity_band(0.8799), "moderate")
  expect_equal(traning:::.alt_intensity_band(0.88), "hard")
  expect_equal(traning:::.alt_intensity_band(1.0), "hard")
  expect_true(is.na(traning:::.alt_intensity_band(NA_real_)))
})

test_that("intensity bands use the same anchors as the running classifier", {
  # Guard against the two taxonomies drifting apart: the running HR
  # fallback switches to "tempo" at VT1 and to "threshold_intervals" at
  # VT2, which is where alt sessions switch to moderate and hard.
  expect_equal(traning:::.HR_PCT_VT1, 0.82)
  expect_equal(traning:::.HR_PCT_VT2, 0.88)
  expect_equal(traning:::.classify_from_hr_avg(0.8199, 60)$type, "endurance")
  expect_equal(traning:::.classify_from_hr_avg(0.82, 60)$type, "tempo")
  expect_equal(traning:::.classify_from_hr_avg(0.8799, 60)$type, "tempo")
  expect_equal(traning:::.classify_from_hr_avg(0.88, 60)$type,
               "threshold_intervals")
})

# --- Duration bands ----------------------------------------------------------

test_that(".alt_duration_band breaks exactly at 45, 90 and 120 minutes", {
  expect_equal(traning:::.alt_duration_band(44.9), "short")
  expect_equal(traning:::.alt_duration_band(45), "medium")
  expect_equal(traning:::.alt_duration_band(89.9), "medium")
  expect_equal(traning:::.alt_duration_band(90), "long")
  expect_equal(traning:::.alt_duration_band(119.9), "long")
  expect_equal(traning:::.alt_duration_band(120), "very_long")
  expect_true(is.na(traning:::.alt_duration_band(0)))
  expect_true(is.na(traning:::.alt_duration_band(NA_real_)))
})

# --- Recovery cost -----------------------------------------------------------

test_that(".alt_recovery_cost follows intensity, then the volume rule", {
  expect_equal(traning:::.alt_recovery_cost("hard", 20), "high")
  expect_equal(traning:::.alt_recovery_cost("moderate", 20), "moderate")
  expect_equal(traning:::.alt_recovery_cost("low", 20), "low")
  # Volume rule: low intensity but >= 90 min still costs recovery
  expect_equal(traning:::.alt_recovery_cost("low", 89.9), "low")
  expect_equal(traning:::.alt_recovery_cost("low", 90), "moderate")
  expect_equal(traning:::.alt_recovery_cost("low", 360), "moderate")
})

test_that("the volume rule survives a missing HR reading", {
  expect_true(is.na(traning:::.alt_recovery_cost(NA_character_, 60)))
  expect_equal(traning:::.alt_recovery_cost(NA_character_, 95), "moderate")
})

# --- classify_alt_session ----------------------------------------------------

test_that("classify_alt_session composes class from intensity and duration", {
  # 6 h paddling at 120 bpm against HRmax 185 → 0.65 → low_very_long
  res <- classify_alt_session(
    .alt_session("paddelsporter", min = 360, hr = 120), hr_max = 185)
  expect_equal(res$class, "low_very_long")
  expect_equal(res$intensity, "low")
  expect_equal(res$duration_band, "very_long")
  expect_equal(res$recovery_cost, "moderate")
  expect_equal(res$confidence, "low")
  expect_equal(res$modality, "aerobic")
  expect_equal(res$hr_reliability, "continuous")
})

test_that("classify_alt_session flags hard intermittent sessions", {
  res <- classify_alt_session(.alt_session("fotboll", min = 60, hr = 165),
                              hr_max = 185)
  expect_equal(res$class, "hard_medium")
  expect_equal(res$recovery_cost, "high")
  expect_equal(res$modality, "other")
  expect_equal(res$hr_reliability, "intermittent")
})

test_that("classify_alt_session invents no intensity without HR", {
  res <- classify_alt_session(
    .alt_session("strength", min = 45, hr = NA_real_), hr_max = 185)
  expect_equal(res$class, "nohr_medium")
  expect_true(is.na(res$intensity))
  expect_true(is.na(res$recovery_cost))
  expect_equal(res$confidence, "none")

  # But the volume rule still applies to a long session without HR
  long <- classify_alt_session(
    .alt_session("paddelsporter", min = 360, hr = NA_real_), hr_max = 185)
  expect_equal(long$class, "nohr_very_long")
  expect_equal(long$recovery_cost, "moderate")
  expect_true(is.na(long$intensity))
})

test_that("classify_alt_session handles a zero HR reading as missing", {
  res <- classify_alt_session(.alt_session("cycling", min = 50, hr = 0),
                              hr_max = 185)
  expect_equal(res$class, "nohr_medium")
  expect_true(is.na(res$intensity))
})

test_that("classify_alt_session returns unknown for unusable input", {
  expect_equal(classify_alt_session(NULL)$confidence, "unknown")
  expect_equal(classify_alt_session(.alt_session(min = 0))$confidence,
               "unknown")
})

test_that("classify_alt_session anchors HRmax on all sports, not running", {
  # A dataset where the running ceiling sits well below the all-sport
  # ceiling. Anchoring on running would inflate hr_pct and report a
  # moderate cycling session as hard.
  summaries <- dplyr::bind_rows(
    lapply(1:12, function(i) tibble::tibble(
      sessionStart = as.POSIXct("2026-06-01 07:00", tz = "UTC") + i * 86400,
      sport = "running", distance = 10000,
      avgHeartRateMoving = 140, garmin_maxHR = 160,
      duration = as.difftime(60, units = "mins"),
      durationMoving = as.difftime(60, units = "mins")
    )),
    lapply(1:12, function(i) tibble::tibble(
      sessionStart = as.POSIXct("2026-06-01 17:00", tz = "UTC") + i * 86400,
      sport = "cycling", distance = 30000,
      avgHeartRateMoving = 150, garmin_maxHR = 200,
      duration = as.difftime(60, units = "mins"),
      durationMoving = as.difftime(60, units = "mins")
    ))
  )
  all_max <- suppressMessages(get_hr_max(summaries, sport = "all"))
  run_max <- suppressMessages(get_hr_max(summaries, sport = "running"))
  expect_equal(all_max, 200)
  expect_equal(run_max, 160)

  # 170 bpm is 85% of the all-sport anchor (moderate) but above the
  # running anchor entirely (would clip to 100% → hard).
  session <- summaries[nrow(summaries), , drop = FALSE]
  session$avgHeartRateMoving <- 170
  res <- suppressMessages(
    classify_alt_session(session, summaries = summaries))
  expect_equal(res$intensity, "moderate")
})

# --- Modality and HR reliability --------------------------------------------

test_that("modality and HR reliability classify the known sports", {
  for (s in c("cycling", "walking", "swimming", "paddelsporter", "rodd")) {
    expect_equal(traning:::.sport_modality(s), "aerobic", info = s)
    expect_equal(traning:::.sport_hr_reliability(s), "continuous", info = s)
  }
  # skridskosporter is deliberately in the cautious branch: HealthKit's
  # "Skating Sports" mixes long-distance skating with figure/inline
  # skating, so figure skating must not inherit "bygger aerob bas".
  for (s in c("strength", "karntraning", "yoga", "sinne_&_kropp",
              "badminton", "bordtennis", "tennis", "fotboll", "hockey",
              "fitness-spel", "bagskytte", "ovrigt", "snosporter",
              "utforsakning", "skridskosporter")) {
    expect_equal(traning:::.sport_modality(s), "other", info = s)
    expect_equal(traning:::.sport_hr_reliability(s), "intermittent", info = s)
  }
})

test_that("an unknown sport takes the cautious branch", {
  expect_equal(traning:::.sport_modality("klattring"), "other")
  expect_equal(traning:::.sport_hr_reliability("klattring"), "intermittent")
  expect_equal(traning:::.sport_modality(NA_character_), "other")
  expect_equal(traning:::.sport_hr_reliability(NULL), "intermittent")
})
