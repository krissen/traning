# Invariant matrix for the canonical sport-day unit.
#
# The three day-summary blockers in Nagelfar round 1 on PR #76 were one
# shape: "what counts as a session" was decided in four places with four
# answers. This matrix enumerates the session forms x the surfaces that
# read them and pins that every cell agrees. It is the lock the reviewer
# asked for — point regression tests would only push the next instance
# forward.
#
# Surfaces under test:
#   canonical   .day_sport_units()           — the one aggregation
#   day class   .day_alt_class()             — dominant effort line
#   week        .alt_week_stats()            — weekly hours / hard-count
#   inventory   .day_per_sport()             — "Dagens pass" counts
#   context     .session_today_context_line()— "Tidigare idag"
#
# Forms:
#   (a) segmented long paddle (4 x 95 min, low)
#   (b) three short passes same sport same day (3 x 15 min)
#   (c) mixed intensity within the day (60 @130 + 30 @172)
#   (d) a single sub-floor pass (12 min)
#   (e) a pass without HR

HR_MAX <- 185
HR_REST <- 50
D <- as.Date("2026-07-21")

# Build rows for one sport on 2026-07-21 from (min, hr) segment pairs.
# `km` defaults to 5 per segment; pass km = 0 for distance-less sports
# like strength/core.
.mk_segments <- function(sport, segs, start_hour = 9, km = 5) {
  dplyr::bind_rows(lapply(seq_along(segs), function(i) {
    seg <- segs[[i]]
    tibble::tibble(
      sessionStart = as.POSIXct(sprintf("2026-07-21 %02d:00", start_hour + i),
                                tz = "UTC"),
      sport = sport,
      distance = km * 1000,
      avgPaceMoving = NA_real_,
      avgHeartRateMoving = seg[["hr"]],
      durationMoving = as.difftime(seg[["min"]], units = "mins"),
      garmin_directWorkoutRpe = NA_real_
    )
  }))
}

.form <- list(
  a_segmented_long = .mk_segments("paddelsporter", list(
    list(min = 95, hr = 120), list(min = 95, hr = 118),
    list(min = 95, hr = 121), list(min = 95, hr = 119))),
  b_three_short = .mk_segments("cycling", list(
    list(min = 15, hr = 130), list(min = 15, hr = 128),
    list(min = 15, hr = 131))),
  c_mixed = .mk_segments("cycling", list(
    list(min = 60, hr = 130), list(min = 30, hr = 172))),
  d_subfloor = .mk_segments("karntraning", list(list(min = 12, hr = 110)),
                            km = 0),
  e_nohr = .mk_segments("paddelsporter", list(
    list(min = 90, hr = NA_real_), list(min = 90, hr = NA_real_),
    list(min = 90, hr = NA_real_), list(min = 90, hr = NA_real_)))
)

.units <- function(s) traning:::.day_sport_units(s, hr_max = HR_MAX,
                                                 classify = TRUE)
.day_class <- function(s, min_minutes = 20) {
  traning:::.day_alt_class(s, s, hr_max = HR_MAX, min_minutes = min_minutes)
}
.week <- function(s) traning:::.alt_week_stats(s, D, hr_max = HR_MAX,
                                               hr_rest = HR_REST)

# --- One unit per sport-day -------------------------------------------------

test_that("segments of one sport collapse to a single unit everywhere", {
  for (nm in names(.form)) {
    u <- .units(.form[[nm]])
    expect_equal(nrow(u), 1L, info = nm)
  }
})

# --- I1: segment count is identical across surfaces -------------------------

test_that("I1: the pass count agrees between canonical, inventory and context", {
  s <- .form$a_segmented_long
  u <- .units(s)
  inv <- traning:::.day_per_sport(s)
  ctx <- traning:::.session_today_context_line(s)
  expect_equal(u$n_segments, 4L)
  expect_equal(inv$n, 4L)
  expect_match(traning:::.day_sports_line(inv), "\\(4 pass\\)")
  expect_match(ctx, "\\(4 pass\\)")
})

# --- I2: total time is identical across surfaces ----------------------------

test_that("I2: unit minutes agree between canonical, day class and week", {
  s <- .form$a_segmented_long          # 4 x 95 = 380 min
  u <- .units(s)
  cls <- .day_class(s)
  wk <- .week(s)
  expect_equal(u$min, 380)
  expect_equal(cls$duration_min, 380)
  expect_equal(wk$hours * 60, 380)
})

# --- I3: no surface contradicts another on intensity ------------------------

test_that("I3: a hard block makes the day hard in every surface", {
  s <- .form$c_mixed                   # 60 @130 low + 30 @172 hard
  cls <- .day_class(s)
  wk <- .week(s)
  u <- .units(s)
  expect_equal(cls$intensity, "hard")
  expect_equal(cls$recovery_cost, "high")
  expect_true(u$hard)
  expect_equal(wk$hard_count, 1L)      # one unit, counted once — not two
})

test_that("I3: a segmented easy day is low everywhere, never hard", {
  s <- .form$a_segmented_long
  cls <- .day_class(s)
  wk <- .week(s)
  expect_equal(cls$intensity, "low")
  expect_equal(wk$hard_count, 0L)      # 4 segments != 4 hard passes
})

# --- I4: a sub-floor unit shows in the inventory, counts for nothing --------

test_that("I4: a unit under min_minutes shows in inventory but adds 0 to the week", {
  s <- .form$d_subfloor                # single 12-min unit
  inv <- traning:::.day_per_sport(s)
  expect_equal(inv$n, 1L)
  expect_equal(inv$min, 12)
  expect_match(traning:::.day_sports_line(inv), "kärnträning 12 min")
  # Below the 20-min gate for classification and the week
  expect_null(.day_class(s))
  wk <- .week(s)
  expect_equal(wk$hours, 0)
  expect_equal(wk$hard_count, 0L)
})

test_that("I4: three short segments aggregate past the gate as one unit", {
  s <- .form$b_three_short             # 3 x 15 = 45 min
  # Old bug: filtered per row (each 15 < 20) -> 0 h in the week while the
  # day line showed a full unit. Now both aggregate first.
  cls <- .day_class(s)
  wk <- .week(s)
  expect_false(is.null(cls))
  expect_equal(cls$duration_min, 45)
  expect_equal(wk$hours * 60, 45)
})

# --- I5: a no-HR unit contributes time but never intensity ------------------

test_that("I5: a no-HR unit adds hours but no intensity and no hard count", {
  s <- .form$e_nohr                    # 4 x 90 = 360 min, no HR
  cls <- .day_class(s)
  wk <- .week(s)
  expect_true(startsWith(cls$class, "nohr_"))
  expect_true(is.na(cls$intensity))
  expect_equal(wk$hours * 60, 360)
  expect_equal(wk$hard_count, 0L)
  expect_equal(wk$nohr_fraction, 1)
})

# --- classify_alt_session agrees with a one-segment unit --------------------

test_that("a single session equals a one-segment unit", {
  one <- .mk_segments("cycling", list(list(min = 60, hr = 150)))
  via_session <- classify_alt_session(one, hr_max = HR_MAX)
  via_unit <- .units(one)
  expect_equal(via_session$class, via_unit$class)
  expect_equal(via_session$intensity, via_unit$intensity)
  expect_equal(via_session$duration_min, via_unit$min)
})
