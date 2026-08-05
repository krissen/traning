# Health Auto Export (HAE) workout JSON parser
#
# Reads workout JSON files exported by the Health Auto Export iOS app and
# returns rows shaped like Garmin trackeR summaries so they can be appended
# to the same `summaries` data frame that powers PMC, ACWR and reports.

# --- Parser -------------------------------------------------------------------

# Every HAE workout name observed in the data, mapped to its canonical
# sport value. Enumerated rather than left to the slug fallback below so
# that a name whose Swedish spelling doesn't slugify to the value we
# already have in the cache can't silently create a second sport for the
# same activity.
#
# Canonical values are the existing cache values — "paddelsporter",
# "karntraning", "sinne_&_kropp" and friends stay slugs on purpose;
# renaming them would split the persisted `sport` column in two until a
# full re-import has run. Swedish display names live in
# .SPORT_LABELS_SV (R/sport_filter.R).
#
# "Vandring" deliberately maps to "walking": a separate "hiking" value
# would not match the c("running", "walking") deduction in
# compute_background_trimp(), so hiking kilometres would be counted both
# as session TRIMP and as background TRIMP.
.HAE_SPORT_NAMES <- list(
  "löpning"                 = "running",
  "kör"                     = "running",
  "utomhus kör"             = "running",
  "inomhus kör"             = "running",
  "cykling"                 = "cycling",
  "utomhus cykling"         = "cycling",
  "inomhus cykling"         = "cycling",
  "gång"                    = "walking",
  "utomhus gång"            = "walking",
  "inomhus gång"            = "walking",
  "vandring"                = "walking",
  "simning"                 = "swimming",
  "öppet vatten-simning"    = "swimming",
  "poolsimning"             = "swimming",
  "paddelsporter"           = "paddelsporter",
  "rodd"                    = "rodd",
  "skridskosporter"         = "skridskosporter",
  "snösporter"              = "snosporter",
  "utförsåkning"            = "utforsakning",
  "funktionell styrketräning" = "strength",
  "traditionell styrketräning" = "strength",
  "kärnträning"             = "karntraning",
  "yoga"                    = "yoga",
  "sinne & kropp"           = "sinne_&_kropp",
  "badminton"               = "badminton",
  "bordtennis"              = "bordtennis",
  "tennis"                  = "tennis",
  "fotboll"                 = "fotboll",
  "hockey"                  = "hockey",
  "fitness-spel"            = "fitness-spel",
  "bågskytte"               = "bagskytte",
  "övrigt"                  = "ovrigt"
)

# Normalise an HAE name for table lookup: lowercase, collapse runs of
# whitespace, trim. Keeps diacritics — the table is keyed on the Swedish
# spelling HAE actually writes.
.hae_name_key <- function(name) {
  n <- tolower(trimws(name))
  gsub("\\s+", " ", n)
}

#' Map an HAE workout name to a sport bucket
#'
#' Matches Garmin's `sport` strings ("running", "cycling") so that downstream
#' filtering (e.g. PMC's `str_detect(sport, "running")`) works without changes.
#' Resolution order: the enumerated \code{.HAE_SPORT_NAMES} table, then
#' substring rules for name variants Apple may add ("Utomhus Löpning"),
#' then a slug fallback.
#'
#' @param name HAE workout `name` string (Swedish UI labels like
#'   "Utomhus Kör", "Utomhus Cykling", "Utomhus Gång").
#' @return Character sport bucket (e.g. "running", "cycling", "walking").
#' @keywords internal
.hae_sport_from_name <- function(name) {
  .hae_sport_lookup(name)$sport
}

#' Whether an HAE workout name is covered by a known mapping
#'
#' Names that fall through to the slug fallback get no Swedish label and
#' no bucket, so the importer counts them and reports them rather than
#' letting a new Apple activity type appear silently.
#'
#' @param name HAE workout `name` string.
#' @return TRUE when the name resolved via table or substring rule.
#' @keywords internal
.hae_sport_is_mapped <- function(name) {
  .hae_sport_lookup(name)$mapped
}

# Shared resolution used by both helpers above.
.hae_sport_lookup <- function(name) {
  if (is.null(name) || length(name) == 0 || is.na(name) || !nzchar(name)) {
    return(list(sport = "unknown", mapped = FALSE))
  }
  key <- .hae_name_key(name)

  exact <- .HAE_SPORT_NAMES[[key]]
  if (!is.null(exact)) return(list(sport = exact, mapped = TRUE))

  # Substring rules — cover "Utomhus X" / "Inomhus X" variants of names
  # Apple may introduce without us having seen them yet.
  if (grepl("kör|löpning|löp", key)) return(list(sport = "running", mapped = TRUE))
  if (grepl("cykling|cykel", key)) return(list(sport = "cycling", mapped = TRUE))
  if (grepl("gång|promenad|vandring|walking", key)) {
    return(list(sport = "walking", mapped = TRUE))
  }
  if (grepl("simning|simma|swimming", key)) {
    return(list(sport = "swimming", mapped = TRUE))
  }
  if (grepl("styrk|gym|strength", key)) {
    return(list(sport = "strength", mapped = TRUE))
  }
  if (grepl("paddel", key)) return(list(sport = "paddelsporter", mapped = TRUE))

  # Fallback: lowercase, strip diacritics, replace spaces
  out <- tolower(name)
  out <- chartr("åäö", "aao", out)
  out <- gsub("\\s+", "_", out)
  list(sport = out, mapped = FALSE)
}

# Pick a numeric quantity from an HAE field that's either {qty, units} or NA/NULL
.hae_qty <- function(field) {
  if (is.null(field)) return(NA_real_)
  if (is.list(field) && !is.null(field[["qty"]])) return(as.numeric(field[["qty"]]))
  NA_real_
}

# Parse HAE timestamp ("YYYY-MM-DD HH:MM:SS +ZZZZ") to POSIXct
.hae_parse_time <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) return(as.POSIXct(NA))
  # %z handles "+0200"; HAE writes "+0200" without colon
  t <- as.POSIXct(s, format = "%Y-%m-%d %H:%M:%OS %z", tz = "UTC")
  t
}

#' Parse a single HAE workout JSON file
#'
#' Reads one HAE workout JSON file and returns a 1-row data frame with
#' columns matching Garmin trackeR summary output.  Missing fields become
#' `NA`.  Returns `NULL` if the file is unreadable or lacks required keys
#' (`start`, `duration`).
#'
#' @param path Path to a single HAE workout `.json` file.
#' @return One-row data frame, or `NULL` on parse failure.
#' @export
parse_hae_workout <- function(path) {
  raw <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                  error = function(e) NULL)
  if (is.null(raw)) return(NULL)
  workouts <- raw[["data"]][["workouts"]]
  if (is.null(workouts) || length(workouts) == 0) return(NULL)
  w <- workouts[[1]]

  # Required fields
  start <- .hae_parse_time(w[["start"]])
  duration <- if (!is.null(w[["duration"]])) as.numeric(w[["duration"]]) else NA_real_
  if (is.na(start) || is.na(duration)) return(NULL)

  end <- .hae_parse_time(w[["end"]])
  dist_km <- .hae_qty(w[["distance"]])
  dist_m <- if (is.na(dist_km)) NA_real_ else dist_km * 1000
  avg_hr <- .hae_qty(w[["avgHeartRate"]])
  speed_kmh <- .hae_qty(w[["speed"]])
  speed_ms <- if (is.na(speed_kmh)) {
    if (!is.na(dist_m) && duration > 0) dist_m / duration else NA_real_
  } else {
    speed_kmh / 3.6
  }
  pace_minkm <- if (!is.na(dist_km) && dist_km > 0 && duration > 0) {
    (duration / 60) / dist_km
  } else NA_real_
  elev_up <- .hae_qty(w[["elevationUp"]])
  sport <- .hae_sport_from_name(w[["name"]])

  # trackeR stores durations as difftime in seconds.  Match that so
  # downstream code (compute_trimp et al.) that calls
  # as.numeric(durationMoving, units = "mins") gets minutes, not seconds.
  dur_dt <- as.difftime(duration, units = "secs")

  row <- data.frame(
    sessionStart = start,
    sessionEnd = end,
    duration = dur_dt,
    durationMoving = dur_dt,
    distance = dist_m,
    avgHeartRate = avg_hr,
    avgHeartRateMoving = avg_hr,
    avgSpeed = speed_ms,
    avgSpeedMoving = speed_ms,
    avgPace = pace_minkm,
    avgPaceMoving = pace_minkm,
    avgAltitude = NA_real_,
    avgAltitudeMoving = NA_real_,
    total_elevation_gain = elev_up,
    avgCadenceRunning = NA_real_,
    avgCadenceRunningMoving = NA_real_,
    avgStride = NA_real_,
    avgStrideMoving = NA_real_,
    sport = sport,
    file = paste0("hae:", basename(path)),
    source = "hae",
    stringsAsFactors = FALSE
  )
  # Carry the raw HAE name as an attribute rather than a column: the
  # importer needs it to report unmapped activity types, but `summaries`
  # is persisted and must not grow a column for it.
  attr(row, "hae_name") <- w[["name"]]
  row
}

# --- Cross-source matching ----------------------------------------------------

# Δstart window (seconds) used when at least one sanity quantity
# (distance or duration) can be compared between the two sessions.
# Apple Watch and Garmin are often started a minute or two apart on the
# same run — 2026-08-01 was 107 s — so a pure "same second" window is
# far too narrow.
.WORKOUT_MATCH_WINDOW <- 300

# Δstart window (seconds) when neither distance nor duration can be
# compared. Nothing but the clock separates the two rows then, so the
# window is tightened to avoid collapsing two genuinely adjacent
# sessions (e.g. a warm-up walk followed by a run).
.WORKOUT_MATCH_TIME_ONLY_WINDOW <- 120

# Relative tolerance for the distance/duration sanity check. GPS vs.
# wrist-measured distance for the same run typically differ by a few
# percent; 20 % leaves room for that without matching a 5 km run to a
# 12 km one.
.WORKOUT_MATCH_TOLERANCE <- 0.20

# --- Overlap criterion --------------------------------------------------------
# The start-based rule above misses the case where the Apple Watch is
# started partway into a session already being recorded by the Garmin
# watch: the starts are 11–105 minutes apart, but the wall-clock
# intervals overlap and both watches are stopped within seconds of each
# other. Roughly two thirds of the real duplicates in the cache are of
# this shape.

# Minimum wall-clock overlap (seconds). Below a minute the "overlap" is
# just two adjacent sessions touching at the edges — a cool-down walk
# started before the run was stopped, say. The smallest verified
# duplicate overlaps by 79 s, which is the margin this floor works with.
.WORKOUT_OVERLAP_MIN <- 60

# A corrupt sessionEnd is the one way the overlap criterion can destroy
# data: the 2019-12-09 cache row claims a 14.5-hour bike ride, so every
# session recorded that afternoon falls "inside" it and is deduplicated
# away. Refusing to trust an implausible interval kills that at the
# source, which is cheaper than recognising its victims afterwards.
#
# Length cannot be the test — a backyard ultra genuinely spans 12–15
# hours and a 24-hour race is not out of the question, so any span cap
# would disqualify exactly the sessions where both watches run longest
# and a duplicate is most likely. The test is instead the pace the
# interval implies, distance / (sessionEnd - sessionStart), and it has
# to be per sport family: the broken row is cycling at 0.27 m/s while
# the slowest verified duplicate is a walk at 0.21 m/s, so no single
# floor can separate them.
#
# Margins are quoted on the same footing the code uses: distance over
# wall-clock span, measured on *both* rows of each of the 321 candidate
# pairs, and labelled by that row's own sport (the slowest running
# figure below is a Garmin row whose Apple Watch twin is labelled
# walking, which is why a per-row reading and a per-pair one disagree).
# Slowest genuine row per family, against the floor that family is held
# to (only cycling has its own; the other two share the 0.10 default —
# the 0.499 below is a walking measurement, not a walking floor):
#   cycling 2.313 m/s vs. its 0.50 floor — 4.6x, and the broken row
#           sits 1.9x below that floor
#   running 0.211 m/s vs. the 0.10 default — 2.1x
#   walking 0.499 m/s vs. the 0.10 default — 5.0x
# 0.50 m/s is 1.8 km/h, slower than a stroll, so impossible as cycling
# rather than merely unusual; 0.10 m/s is in practice a guard against
# rows with no distance at all. Across the whole cache 114 of the 13832
# rows carrying both fields fall below their floor, nearly all
# zero-distance sports, and none of them is a candidate today. The
# closest any cycling row comes to its floor from below is 0.4996 m/s
# (2019-07-05, 798 m).
#
# The comparison is >=, so a row sitting exactly on its floor is
# believed. The floors are chosen to be impossible rather than merely
# unusual, so the boundary itself carries no evidence either way, and
# including it keeps the rule on the permissive side of a judgement call
# that can only cost a duplicate, never delete real data.
#
# A distrusted pair is still eligible under the start criterion.
.WORKOUT_OVERLAP_MIN_SPEED_CYCLING <- 0.50
.WORKOUT_OVERLAP_MIN_SPEED_DEFAULT <- 0.10

# One of three pieces of corroborating evidence is then required. Each
# distinguishes one session recorded twice from two that merely share
# wall clock:
#   - the overlap covers half the shorter session (one recording sits
#     inside the other),
#   - the two stop within a minute of each other (both watches stopped
#     by hand at the same moment; observed offsets are 1–28 s),
#   - the distances agree within .WORKOUT_MATCH_TOLERANCE (a skewed
#     clock explains the timing; 8707 m vs. 8702 m does not happen
#     twice by chance).
# The one verified false positive among the overlapping pairs — a 2554 m
# and a 4798 m bike ride sharing seven minutes in 2022 — fails all three.
.WORKOUT_OVERLAP_COVERAGE <- 0.50
.WORKOUT_OVERLAP_END_WINDOW <- 60

# Sports exempt from the overlap criterion. A strength session logged on
# one watch while the other records a run is a legitimate pair of
# sessions, not a duplicate — the same is true of anything landing in
# the catch-all buckets, where the label says nothing about what was
# done. The physical argument above only covers activities that move you
# somewhere, so these are excluded and left to the start rule.
#
# The list stays narrow on purpose: every sport on it is one whose
# duplicates the overlap criterion can no longer catch.
.WORKOUT_OVERLAP_EXEMPT_SPORTS <- c(
  "strength", "styrka", "styrketraning", "karntraning",
  "ovrigt", "other", "unknown"
)

# The sport families used when two rows come from the same device and
# their labels can therefore be compared. Deliberately narrow: running,
# walking and cycling are three different things, and a commute of ride
# out, run, ride home is three sessions whose edges touch — not one
# session recorded three times.
#
# Canonical cache values are already English; the Swedish spellings are
# here so a row that predates the mapping table is read the same way.
.sport_family <- function(sport) {
  s <- tolower(trimws(as.character(sport)))
  s[is.na(s) | !nzchar(s)] <- NA_character_
  s[grepl("^(running|l\u00f6pning|k\u00f6r)$", s)] <- "running"
  s[grepl("^(walking|g\u00e5ng|promenad|vandring)$", s)] <- "walking"
  s[grepl("^(cycling|cykling|cykel)$", s)] <- "cycling"
  s
}

# TRUE where both labels are known and name the same family. An unknown
# label is never "the same": without it there is nothing to confirm two
# recordings from one device are the same activity.
.same_sport_family <- function(a, b, n) {
  fa <- rep(.sport_family(a), length.out = n)
  fb <- rep(.sport_family(b), length.out = n)
  !is.na(fa) & !is.na(fb) & fa == fb
}

# Pull a field out of a data frame, list or bare vector holder.
.workout_field <- function(x, name) {
  if (is.data.frame(x) || is.list(x)) {
    if (!name %in% names(x)) return(NULL)
    return(x[[name]])
  }
  NULL
}

# Coerce a duration to seconds. trackeR stores durations as difftime
# whose units vary by session; a bare numeric is assumed to be seconds.
.workout_secs <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_real_)
  if (inherits(x, "difftime")) return(as.numeric(x, units = "secs"))
  as.numeric(x)
}

# TRUE where both quantities are present, positive and within `tol` of
# each other (relative to the larger of the two).
.within_relative <- function(x, y, tol) {
  ok <- !is.na(x) & !is.na(y) & x > 0 & y > 0
  out <- rep(FALSE, length(ok))
  out[ok] <- abs(x[ok] - y[ok]) / pmax(x[ok], y[ok]) <= tol
  out
}

#' Whether two workout records describe the same session
#'
#' The shared rule behind every cross-source dedup in the package (HAE
#' import, TCX import, \code{dedup_summaries()}). Two records are the
#' same workout when **either** criterion below holds.
#'
#' \strong{Start criterion.} They start within \code{window_seconds} of
#' each other **and** either their distances or their durations agree
#' within \code{tolerance}. When neither quantity can be compared — one
#' side lacks both — the decision falls back to time alone, with the
#' narrower \code{time_only_seconds} window. This catches the ordinary
#' case of two watches started a minute or two apart.
#'
#' \strong{Overlap criterion.} Their wall-clock intervals overlap by at
#' least \code{overlap_min_seconds}, both intervals are believable, and
#' one of three pieces of corroborating evidence holds: the overlap
#' covers \code{overlap_coverage} of the shorter session, the two stop
#' within \code{overlap_end_seconds} of each other, or their distances
#' agree within \code{tolerance}. This catches the second watch being
#' started partway into a session the first one is already recording
#' (starts up to an hour and a half apart), a watch stopped an hour
#' early, and pairs whose clocks disagree outright — all shapes the start
#' criterion cannot see.
#'
#' "Believable" means the interval implies at least
#' \code{.workout_min_speed()} for the session's sport — there is no
#' length limit, since a backyard ultra genuinely spans half a day; see
#' the constant definitions for the calibration. The criterion is skipped
#' entirely when either sessionEnd or either distance is missing, and for
#' the sports in \code{.WORKOUT_OVERLAP_EXEMPT_SPORTS}, where a genuinely
#' separate session can share the wall clock with another one.
#'
#' All three overlap thresholds are measured against wall-clock spans
#' (`sessionEnd - sessionStart`), never the `duration` column: the
#' overlap itself is wall clock, and the two quantities diverge for a
#' paused session, so mixing them would drift silently.
#'
#' Sport is otherwise deliberately not part of the rule: Apple Watch
#' sometimes labels a slow jog "Utomhus Gång" while Garmin records it as
#' running.
#'
#' Vectorised over \code{b} (and over \code{a}, if given more than one
#' row); the usual recycling rules apply.
#'
#' @param a,b Data frames or lists with `sessionStart` and, optionally,
#'   `sessionEnd`, `distance` (metres), `duration` (difftime or seconds)
#'   and `sport`.
#' @param window_seconds Δstart window when a sanity quantity is
#'   comparable.
#' @param time_only_seconds Δstart window when neither distance nor
#'   duration is comparable on both sides.
#' @param tolerance Relative tolerance for the distance/duration check.
#' @param same_sport Require both rows to name the same sport family.
#'   FALSE between an Apple Watch row and a Garmin one, whose labels
#'   disagree often enough to be useless — a slow jog is "Utomhus Gång"
#'   on one and running on the other. TRUE between two rows from the same
#'   device, where the labels are comparable and a ride and a run really
#'   are two sessions however their edges overlap.
#' @param overlap_min_seconds Minimum wall-clock overlap.
#' @param overlap_coverage Fraction of the shorter session the overlap
#'   may cover as evidence.
#' @param overlap_end_seconds Δend window accepted as evidence.
#' @return Logical vector, one element per compared pair.
#' @keywords internal
.is_same_workout <- function(a, b,
                             window_seconds = .WORKOUT_MATCH_WINDOW,
                             time_only_seconds = .WORKOUT_MATCH_TIME_ONLY_WINDOW,
                             tolerance = .WORKOUT_MATCH_TOLERANCE,
                             same_sport = FALSE,
                             overlap_min_seconds = .WORKOUT_OVERLAP_MIN,
                             overlap_coverage = .WORKOUT_OVERLAP_COVERAGE,
                             overlap_end_seconds = .WORKOUT_OVERLAP_END_WINDOW) {
  sa <- .workout_field(a, "sessionStart")
  sb <- .workout_field(b, "sessionStart")
  if (is.null(sa) || is.null(sb) || length(sa) == 0 || length(sb) == 0) {
    return(logical(0))
  }

  n <- max(length(sa), length(sb))
  rec <- function(x, default = NA_real_) {
    if (is.null(x) || length(x) == 0) return(rep(default, n))
    rep(x, length.out = n)
  }

  sa <- rep(as.POSIXct(sa), length.out = n)
  sb <- rep(as.POSIXct(sb), length.out = n)
  da <- rec(as.numeric(.workout_field(a, "distance")))
  db <- rec(as.numeric(.workout_field(b, "distance")))
  ta <- rec(.workout_secs(.workout_field(a, "duration")))
  tb <- rec(.workout_secs(.workout_field(b, "duration")))

  dt <- abs(as.numeric(difftime(sa, sb, units = "secs")))
  dt[is.na(dt)] <- Inf

  dist_ok <- .within_relative(da, db, tolerance)
  dur_ok <- .within_relative(ta, tb, tolerance)
  comparable <- (!is.na(da) & !is.na(db) & da > 0 & db > 0) |
                (!is.na(ta) & !is.na(tb) & ta > 0 & tb > 0)

  by_start <- ifelse(comparable,
                     dt <= window_seconds & (dist_ok | dur_ok),
                     dt <= time_only_seconds)

  out <- by_start | .overlaps_same_workout(
    a, b, n, da, db, dist_ok,
    overlap_min_seconds = overlap_min_seconds,
    overlap_coverage = overlap_coverage,
    overlap_end_seconds = overlap_end_seconds
  )

  # Two recordings from the same device carry comparable labels, and a
  # ride and a run are two sessions however their edges overlap. Between
  # devices the labels disagree too often to be evidence of anything.
  if (isTRUE(same_sport)) {
    out <- out & .same_sport_family(.workout_field(a, "sport"),
                                    .workout_field(b, "sport"), n)
  }
  out
}

# The overlap criterion, split out to keep .is_same_workout() readable.
# `n` is the recycled length already established by the caller, `da`/`db`
# the recycled distances and `dist_ok` the distance comparison it has
# already made.
.overlaps_same_workout <- function(a, b, n, da, db, dist_ok,
                                   overlap_min_seconds = .WORKOUT_OVERLAP_MIN,
                                   overlap_coverage = .WORKOUT_OVERLAP_COVERAGE,
                                   overlap_end_seconds = .WORKOUT_OVERLAP_END_WINDOW) {
  no <- rep(FALSE, n)

  ea <- .workout_field(a, "sessionEnd")
  eb <- .workout_field(b, "sessionEnd")
  if (is.null(ea) || is.null(eb) || length(ea) == 0 || length(eb) == 0) {
    return(no)
  }

  num <- function(x) rep(as.numeric(as.POSIXct(x)), length.out = n)
  start_a <- num(.workout_field(a, "sessionStart"))
  start_b <- num(.workout_field(b, "sessionStart"))
  end_a <- num(ea)
  end_b <- num(eb)

  # Two independent guards against applying the physical argument to
  # something that isn't a distance-bearing session: the sport label, and
  # a recorded distance. Either alone would have sufficed on the
  # observed data (all three legitimate overlapping pairs are strength or
  # "ovrigt" *and* have no distance), so both are kept — a strength
  # session that happens to log distance is still caught by the label,
  # and a mislabelled session is still caught by the missing distance.
  movement <- !.is_overlap_exempt(.workout_field(a, "sport"), n) &
              !.is_overlap_exempt(.workout_field(b, "sport"), n) &
              !is.na(da) & !is.na(db)

  span_a <- end_a - start_a
  span_b <- end_b - start_b
  # An interval is believable if it implies the session actually moved.
  believable <- function(span, dist, sport) {
    !is.na(dist) & span > 0 & dist / span >= .workout_min_speed(sport, n)
  }
  usable <- !is.na(start_a) & !is.na(start_b) & !is.na(end_a) & !is.na(end_b) &
            span_a > 0 & span_b > 0 & movement &
            believable(span_a, da, .workout_field(a, "sport")) &
            believable(span_b, db, .workout_field(b, "sport"))
  if (!any(usable)) return(no)

  overlap <- pmin(end_a, end_b) - pmax(start_a, start_b)
  shorter <- pmin(span_a, span_b)
  end_gap <- abs(end_a - end_b)

  out <- no
  out[usable] <-
    overlap[usable] >= overlap_min_seconds &
    (overlap[usable] >= overlap_coverage * shorter[usable] |
     end_gap[usable] <= overlap_end_seconds |
     dist_ok[usable])
  out
}

# Speed floor (m/s) below which a session's interval is not believed.
# Cycling gets its own floor because it is the only family where the
# observed corruption is faster than a genuine slow session in another.
.workout_min_speed <- function(sport, n) {
  if (is.null(sport) || length(sport) == 0) {
    return(rep(.WORKOUT_OVERLAP_MIN_SPEED_DEFAULT, n))
  }
  s <- rep(tolower(trimws(as.character(sport))), length.out = n)
  ifelse(!is.na(s) & grepl("cycling|cykl", s),
         .WORKOUT_OVERLAP_MIN_SPEED_CYCLING,
         .WORKOUT_OVERLAP_MIN_SPEED_DEFAULT)
}

# TRUE where the sport is one the overlap criterion must not touch.
# A missing sport counts as exempt: without a label we can't tell a
# parallel strength session from a duplicate recording.
.is_overlap_exempt <- function(sport, n) {
  if (is.null(sport) || length(sport) == 0) return(rep(TRUE, n))
  s <- rep(tolower(trimws(as.character(sport))), length.out = n)
  is.na(s) | !nzchar(s) | s %in% .WORKOUT_OVERLAP_EXEMPT_SPORTS
}

# --- Winner selection ---------------------------------------------------------

# Garmin normally wins a duplicate: it is the purpose-built device and
# its numbers are the ones the reports are calibrated on. The exception
# is the session Garmin barely caught — a watch started late or stopped
# after a few hundred metres — where the Apple Watch holds the real
# workout and deferring to Garmin would delete most of the distance.
# 2023-04-10 is the clearest: Garmin 460 m over three minutes against
# 10 274 m over 53 minutes on the wrist.
#
# The threshold is a ratio rather than an absolute distance so it scales
# from a 5 km run to a 40 km ride. Ratios between 1.2 and 2.0 are the
# ordinary GPS-versus-wrist disagreement and stay with Garmin.
.WORKOUT_FRAGMENT_RATIO <- 0.5

#' Whether the Garmin row wins a duplicate pair
#'
#' Vectorised over either side. Garmin wins unless its distance is below
#' \code{fragment_ratio} of the Apple Watch distance, in which case the
#' Garmin row is only a fragment of the session and the HAE row is kept.
#' A missing distance on either side leaves Garmin the winner, since
#' nothing contradicts the default.
#'
#' The decision depends only on the two distances, so the same pair
#' always resolves the same way whichever import path meets it — the
#' property that keeps repeated imports from oscillating.
#'
#' @param hae_distance,tcx_distance Distances in metres.
#' @param fragment_ratio Below this fraction of the HAE distance, the
#'   Garmin row counts as a fragment.
#' @return Logical vector; TRUE where the Garmin row wins.
#' @keywords internal
# Two Garmin rows starting within this many seconds of each other are
# one recording under two names — a re-export, a stale copy — rather
# than two legs of a session. Legs are consecutive and minutes apart.
.SAME_RECORDING_SECONDS <- 2

#' Which of a set of Garmin rows are distinct recordings
#'
#' Copies of one recording must not both count towards what Garmin holds
#' for a session: two copies of a 40 % fragment would add up to 80 % and
#' take a session Garmin only ever recorded in part. Legs are unaffected,
#' being minutes apart.
#'
#' The first of a set of copies is the one kept. They are the same
#' recording, so the choice only has to be deterministic — and the
#' removal lists elsewhere still take every copy; it is the arithmetic
#' that must not count one recording twice.
#'
#' @param starts Session start times of the rows, in order.
#' @return Logical vector, TRUE for the rows to count.
#' @keywords internal
.distinct_recordings <- function(starts) {
  n <- length(starts)
  if (n < 2) return(rep(TRUE, n))
  s <- as.numeric(starts)
  keep <- rep(TRUE, n)
  for (k in seq_len(n)[-1]) {
    earlier <- which(keep[seq_len(k - 1L)])
    if (any(!is.na(s[earlier]) & !is.na(s[k]) &
            abs(s[earlier] - s[k]) < .SAME_RECORDING_SECONDS)) {
      keep[k] <- FALSE
    }
  }
  keep
}

#' Whether one copy of a session is fuller than another
#'
#' The copies describe the same session, so what separates them is how
#' much each recording captured. In order:
#' \enumerate{
#'   \item A copy that recorded a distance beats one that did not. The
#'     distance column is what the reports read, so a copy missing it is
#'     the less complete record of the same session whatever else it has.
#'   \item Among copies with a distance, the longest.
#'   \item Among copies without one — a strength session, yoga, core
#'     work, where no distance is ever recorded — the longest duration,
#'     which is all that is left to tell them apart and is what the
#'     training load is computed from.
#' }
#' Never richer than an equal, so ties leave whatever is already in
#' place and the order files happen to be read in decides nothing.
#'
#' @param a_distance,a_duration The candidate.
#' @param b_distance,b_duration What it is measured against.
#' @return TRUE when the candidate is the fuller record.
#' @keywords internal
.copy_is_richer <- function(a_distance, a_duration, b_distance, b_duration) {
  ad <- as.numeric(a_distance)[1]
  bd <- as.numeric(b_distance)[1]
  if (!is.na(ad) && is.na(bd)) return(TRUE)
  if (is.na(ad) && !is.na(bd)) return(FALSE)
  if (!is.na(ad) && !is.na(bd)) return(isTRUE(ad > bd))

  at <- .workout_secs(a_duration)[1]
  bt <- .workout_secs(b_duration)[1]
  if (is.na(at)) return(FALSE)
  if (is.na(bt)) return(TRUE)
  isTRUE(at > bt)
}

#' Which of several copies of one session to keep
#'
#' The fullest, by \code{.copy_is_richer()}. Used both when the cleanup
#' finds several Apple Watch rows for one session and when the importer
#' meets a copy of a row already cached, so that the two cannot come to
#' different conclusions about the same pair.
#'
#' @param distances Distances of the copies, in metres.
#' @param durations Durations of the copies, for the sports that record
#'   no distance. Optional; without them only distance is consulted.
#' @return Index of the copy to keep.
#' @keywords internal
.best_copy <- function(distances, durations = NULL) {
  n <- length(distances)
  if (n == 0) return(1L)
  if (is.null(durations)) durations <- rep(NA_real_, n)
  best <- 1L
  for (k in seq_len(n)[-1]) {
    if (.copy_is_richer(distances[k], durations[k],
                        distances[best], durations[best])) {
      best <- k
    }
  }
  best
}

#' Total distance Garmin holds for one session
#'
#' A watch stopped and restarted writes one file per leg, so the session
#' Garmin recorded is the sum of the matching rows, not the longest of
#' them. Weighing the legs one at a time called a session split three
#' ways — or evenly in two — a fragment and discarded the whole Garmin
#' recording.
#'
#' A single unknown distance makes the whole total unknown. Skipping it
#' and adding up the rest answers a question nobody asked: the partial
#' sum can fall under the threshold and evict the whole set, the
#' unmeasured row included, on the strength of a number that was never
#' the total. `.garmin_wins()` treats an unknown total as a win for
#' Garmin, which is the documented default when there is no evidence of
#' a fragment.
#'
#' @param distances Distances of the matching Garmin rows, in metres.
#' @return Single numeric total, or NA when any of it is unknown.
#' @keywords internal
.garmin_total <- function(distances) {
  d <- as.numeric(distances)
  if (length(d) == 0 || anyNA(d)) return(NA_real_)
  sum(d)
}

.garmin_wins <- function(hae_distance, tcx_distance,
                         fragment_ratio = .WORKOUT_FRAGMENT_RATIO) {
  hd <- as.numeric(hae_distance)
  td <- as.numeric(tcx_distance)
  fragment <- !is.na(hd) & !is.na(td) & hd > 0 & td < fragment_ratio * hd
  !fragment
}

#' Who keeps a session, when some distances may be unknown
#'
#' Answers the same question as \code{.garmin_wins()} but from the raw
#' set of Garmin distances rather than a total, so that an unknown one
#' can be told apart from a short one. Three answers, and the third is
#' the point:
#' \describe{
#'   \item{TRUE}{Garmin keeps the session. What is known already reaches
#'     the threshold, so what is unknown cannot change it — a lower bound
#'     is enough to win.}
#'   \item{FALSE}{The Apple Watch row keeps it: every Garmin distance is
#'     known and together they are under half of it.}
#'   \item{NA}{Nobody can tell. Something Garmin recorded has no distance
#'     and the rest falls short, so the total could land either side.}
#' }
#' An NA must never be settled by deleting a row whose distance is known.
#' Each caller reads it as "leave this pair alone", in whichever
#' direction that means for it. Passing no distances at all is a
#' different thing from passing unknown ones: a cache with no distance
#' column anywhere keeps the old default that Garmin wins.
#'
#' @param hae_distance Distances of the Apple Watch rows, in metres.
#' @param garmin_distances Distances of the Garmin rows for the same
#'   session, in metres, NA where nothing was recorded.
#' @param fragment_ratio Below this fraction of the Apple Watch distance,
#'   what Garmin holds counts as a fragment.
#' @return Logical vector, one per `hae_distance`, NA where the answer
#'   depends on a distance nobody recorded.
#' @keywords internal
.garmin_verdict <- function(hae_distance, garmin_distances,
                            fragment_ratio = .WORKOUT_FRAGMENT_RATIO) {
  gd <- as.numeric(garmin_distances)
  if (length(gd) == 0) return(rep(TRUE, length(hae_distance)))
  known <- sum(gd[!is.na(gd)])
  complete <- !anyNA(gd)
  vapply(as.numeric(hae_distance), function(h) {
    if (is.na(h) || h <= 0) return(TRUE)
    if (known >= fragment_ratio * h) return(TRUE)
    if (!complete) return(NA)
    FALSE
  }, logical(1))
}

#' Split rows into the sessions they describe
#'
#' Rows that match each other are one session; rows that do not are
#' different ones. A single Garmin file can match two Apple Watch
#' sessions — one on the clock, the other through the distance gate — and
#' a total built for one of them must not decide the fate of the other.
#'
#' @param rows Data frame of summaries rows.
#' @param same_sport Passed to \code{.is_same_workout()}. TRUE when the
#'   rows all come from the same device, so their sport labels can be
#'   compared.
#' @return List of integer vectors, positions within `rows`.
#' @keywords internal
.session_groups <- function(rows, same_sport = FALSE) {
  n <- nrow(rows)
  if (n == 0) return(list())
  if (n == 1) return(list(1L))
  label <- seq_len(n)
  for (i in seq_len(n - 1L)) {
    for (j in (i + 1L):n) {
      if (isTRUE(.is_same_workout(rows[i, , drop = FALSE],
                                  rows[j, , drop = FALSE],
                                  same_sport = same_sport)[1])) {
        merged <- min(label[i], label[j])
        label[label == label[i] | label == label[j]] <- merged
      }
    }
  }
  unname(split(seq_len(n), label))
}

# Rows of `candidates` that are the same workout as the single row `row`.
# Returns an integer vector of positions (empty when nothing matches).
.which_same_workout <- function(row, candidates, ...) {
  if (is.null(candidates) || nrow(candidates) == 0) return(integer(0))
  which(.is_same_workout(row, candidates, ...))
}

# --- Importer -----------------------------------------------------------------

#' Import HAE workout JSON files into summaries
#'
#' Scans `workouts_dir` for `*.json` files, parses each into a summary row,
#' and appends new rows to `summaries`.  Three dedup checks are applied:
#' \enumerate{
#'   \item filename already imported (matched via `file = "hae:<basename>"`)
#'   \item a Garmin (`source == "tcx"`) row describes the same workout per
#'     \code{.is_same_workout()} — either because the two start close
#'     together or because their wall-clock intervals overlap — in which
#'     case Garmin wins and the HAE row is skipped. Sport is **not**
#'     required to match, since two different activities at the same
#'     instant aren't a realistic case and the sport label sometimes
#'     disagrees between Garmin and AW (e.g. a slow jog logged as
#'     "walking" by AW).
#'   \item another HAE row — already cached or accepted earlier in this
#'     same run — describes the same workout, by the same rule. HAE
#'     frequently delivers two JSON files per session (the Apple Watch
#'     recording and the Garmin-Connect-mirrored copy, typically 0–5 s
#'     apart); the first one seen wins.
#' }
#' `myruns` receives `NULL` placeholders so positional alignment with
#' `summaries` is preserved.
#'
#' @param workouts_dir Path to directory containing HAE workout JSON.
#' @param summaries Existing summaries data frame.
#' @param myruns Existing myruns list.
#' @param verbose Logical. Print per-file progress.
#' @param tolerance_seconds Integer. Δstart window (seconds) for dedup when
#'   distance or duration can be compared (default 300).
#' @param time_only_seconds Integer. Narrower Δstart window used when
#'   neither distance nor duration is available on both sides (default 120).
#' @return List with `summaries`, `myruns`, `n_imported`, `n_skipped_dup`,
#'   `n_skipped_dup_hae`, `n_skipped_invalid`, `by_sport`,
#'   `n_unmapped_sports` and `unmapped_names`. `n_skipped_dup` counts rows
#'   dropped in favour of a Garmin row, `n_skipped_dup_hae` rows dropped in
#'   favour of another HAE row. `n_unmapped_sports`/`unmapped_names`
#'   surface activity types that fell through to the slug fallback in
#'   `.hae_sport_from_name()` — they get neither a Swedish label nor a
#'   bucket, so they should be added to `.HAE_SPORT_NAMES` the first time
#'   they appear rather than be discovered months later in a report.
#' @export
import_hae_workouts <- function(workouts_dir, summaries, myruns,
                                verbose = FALSE,
                                tolerance_seconds = .WORKOUT_MATCH_WINDOW,
                                time_only_seconds = .WORKOUT_MATCH_TIME_ONLY_WINDOW) {
  # The NULL placeholders appended below only line up with the new rows if
  # the incoming pair already lines up; correct the length first so an
  # already-skewed cache doesn't carry the skew into the new rows.
  aligned <- .align_myruns(summaries, myruns)
  summaries <- aligned$summaries
  myruns <- aligned$myruns

  result <- list(
    summaries = summaries,
    myruns = myruns,
    n_imported = 0L,
    n_skipped_dup = 0L,
    n_skipped_dup_hae = 0L,
    n_skipped_invalid = 0L,
    n_garmin_fragments = 0L,
    n_replaced_hae = 0L,
    by_sport = integer(0),
    n_unmapped_sports = 0L,
    unmapped_names = character(0)
  )

  if (!dir.exists(workouts_dir)) {
    if (verbose) message("HAE workouts dir saknas: ", workouts_dir)
    return(result)
  }

  files <- list.files(workouts_dir, pattern = "\\.json$",
                      full.names = TRUE, ignore.case = TRUE)
  if (length(files) == 0) {
    if (verbose) message("Inga HAE workout-JSON i ", workouts_dir)
    return(result)
  }

  # Already-imported HAE files (basename without "hae:" prefix)
  existing_hae <- character(0)
  if ("file" %in% names(summaries) && nrow(summaries) > 0) {
    hae_files <- summaries$file[grepl("^hae:", summaries$file)]
    existing_hae <- sub("^hae:", "", hae_files)
  }

  # Cached rows to dedup against: Garmin (TCX) rows for cross-source
  # dedup, HAE rows for the duplicate-JSON case. Both carry distance and
  # duration so .is_same_workout() can apply its sanity check.
  .candidates <- function(which_source) {
    if (!all(c("source", "sessionStart") %in% names(summaries)) ||
        nrow(summaries) == 0) {
      return(NULL)
    }
    keep <- !is.na(summaries$source) & summaries$source == which_source
    if (!any(keep)) return(NULL)
    data.frame(
      # Original row position, so a losing Garmin row can be found again
      # in `summaries` when the fragment rule sends the win to HAE.
      idx = which(keep),
      # Position in `new_rows` for copies accepted during this run, so a
      # fuller copy arriving later can strike them before anything is
      # written. Cached rows have none.
      new_pos = NA_integer_,
      sessionStart = summaries$sessionStart[keep],
      # sessionEnd and sport feed the overlap criterion; both are absent
      # from very old caches, which simply falls back to the start rule.
      sessionEnd = if ("sessionEnd" %in% names(summaries))
        summaries$sessionEnd[keep] else as.POSIXct(NA),
      sport = if ("sport" %in% names(summaries))
        as.character(summaries$sport[keep]) else NA_character_,
      distance = if ("distance" %in% names(summaries))
        as.numeric(summaries$distance[keep]) else NA_real_,
      duration = if ("duration" %in% names(summaries))
        .workout_secs(summaries$duration[keep]) else NA_real_,
      stringsAsFactors = FALSE
    )
  }
  tcx_rows <- .candidates("tcx")
  # Cached HAE rows plus the ones accepted earlier in this same run: two
  # new JSON files for one session usually arrive in the same batch, so
  # comparing against the cache alone would let the pair through.
  hae_rows <- .candidates("hae")

  by_sport <- integer(0)
  unmapped <- character(0)
  new_rows <- list()
  # Positions of Garmin rows displaced by the fragment rule, removed
  # once the whole batch has been read.
  superseded <- integer(0)

  for (f in files) {
    bn <- basename(f)
    if (bn %in% existing_hae) {
      if (verbose) cat("Redan inläst (HAE): ", bn, "\n", sep = "")
      next
    }

    pending_supersede <- integer(0)
    pending_supersede_from <- NA_real_
    row <- tryCatch(parse_hae_workout(f), error = function(e) NULL)
    if (is.null(row)) {
      result$n_skipped_invalid <- result$n_skipped_invalid + 1L
      if (verbose) cat("Ogiltig HAE-JSON: ", bn, "\n", sep = "")
      next
    }

    # Cross-source dedup: Garmin normally wins (sport label may disagree),
    # unless every Garmin row it matches is only a fragment of the
    # session — then the richer HAE row is imported and the fragments go.
    hit <- .which_same_workout(row, tcx_rows,
                               window_seconds = tolerance_seconds,
                               time_only_seconds = time_only_seconds)
    if (length(hit) > 0) {
      # Against everything Garmin holds for this session, not leg by leg.
      # Copies of one recording count once; legs count separately. The
      # rows weighed and the rows displaced are the same set. An NA
      # verdict — a Garmin row with no distance, and the rest falling
      # short — leaves the cached rows alone and turns this file away
      # rather than deleting on a total nobody can compute.
      # One file describes one session. Matching Garmin rows from two
      # different sessions means this row spans both, which no rule here
      # can resolve — displacing either would delete a session this file
      # is not a record of. Turn it away untouched.
      if (length(.session_groups(tcx_rows[hit, , drop = FALSE])) > 1) {
        result$n_skipped_dup <- result$n_skipped_dup + 1L
        if (verbose) {
          cat("Tvetydig mot flera Garmin-pass: ", bn, ", hoppar över\n",
              sep = "")
        }
        next
      }
      distinct <- hit[.distinct_recordings(tcx_rows$sessionStart[hit])]
      verdict <- .garmin_verdict(row$distance, tcx_rows$distance[distinct])
      if (!isTRUE(verdict %in% FALSE)) {
        result$n_skipped_dup <- result$n_skipped_dup + 1L
        if (verbose) {
          dt <- abs(as.numeric(difftime(tcx_rows$sessionStart[hit],
                                        row$sessionStart, units = "secs")))
          cat("Dedupp mot Garmin: ", bn,
              " (Δt = ", round(min(dt)), "s)\n", sep = "")
        }
        next
      }
      # Remembered, not applied: this file can still be turned away by
      # the HAE-to-HAE check below, and dropping the Garmin rows for a
      # file that never gets imported would leave the session with
      # nothing but the copy already cached.
      pending_supersede <- tcx_rows$idx[hit]
      pending_supersede_from <- round(min(tcx_rows$distance[hit]))
    }

    # HAE↔HAE dedup: the watch's own recording and the
    # Garmin-Connect-mirrored copy of one session arrive as two JSON
    # files. The fuller one wins, whichever order they are read in and
    # whichever of them is already cached — keeping the first seen meant
    # that if the short copy sorted first, or was already in the cache,
    # the complete recording was turned away on every import and the
    # reports read the short distance for good.
    hit <- .which_same_workout(row, hae_rows,
                               window_seconds = tolerance_seconds,
                               time_only_seconds = time_only_seconds,
                               same_sport = TRUE)
    if (length(hit) > 0) {
      # The same argument on this side: rows that are not copies of each
      # other are different sessions, and a file that matches both is not
      # a copy of either. Replacing them all would delete a session this
      # file never recorded.
      if (length(.session_groups(hae_rows[hit, , drop = FALSE],
                                 same_sport = TRUE)) > 1) {
        result$n_skipped_dup_hae <- result$n_skipped_dup_hae + 1L
        if (verbose) {
          cat("Tvetydig mot flera HAE-pass: ", bn, ", hoppar över\n", sep = "")
        }
        next
      }
      best <- hit[.best_copy(hae_rows$distance[hit], hae_rows$duration[hit])]
      incoming_is_richer <- .copy_is_richer(
        row$distance, row$duration,
        hae_rows$distance[best], hae_rows$duration[best])

      if (!incoming_is_richer) {
        result$n_skipped_dup_hae <- result$n_skipped_dup_hae + 1L
        if (verbose) {
          dt <- abs(as.numeric(difftime(hae_rows$sessionStart[hit],
                                        row$sessionStart, units = "secs")))
          cat("Dedupp mot HAE: ", bn,
              " (Δt = ", round(min(dt)), "s)\n", sep = "")
        }
        next
      }

      # This file is the fuller copy. Displace the ones it beats: those
      # already in the cache are removed with the Garmin fragments at the
      # end, and those accepted earlier in this same run are struck from
      # the pending rows.
      for (h in hit) {
        if (!is.na(hae_rows$idx[h])) {
          superseded <- c(superseded, hae_rows$idx[h])
          result$n_replaced_hae <- result$n_replaced_hae + 1L
        }
        if (!is.na(hae_rows$new_pos[h])) new_rows[hae_rows$new_pos[h]] <- list(NULL)
      }
      if (verbose) {
        cat("Fylligare HAE-kopia: ", bn, " (",
            if (is.na(as.numeric(row$distance)))
              paste0(round(.workout_secs(row$duration) / 60), " min mot ",
                     round(.workout_secs(hae_rows$duration[best]) / 60), " min")
            else
              paste0(round(as.numeric(row$distance)), " m mot ",
                     round(as.numeric(hae_rows$distance[best])), " m"),
            ")\n", sep = "")
      }
      hae_rows <- hae_rows[-hit, , drop = FALSE]
    }

    if (length(pending_supersede) > 0) {
      superseded <- c(superseded, pending_supersede)
      result$n_garmin_fragments <-
        result$n_garmin_fragments + length(pending_supersede)
      if (verbose) {
        cat("Garmin-fragment ersatt av AW: ", bn, " (",
            pending_supersede_from, " m mot ",
            round(as.numeric(row$distance)), " m)\n", sep = "")
      }
    }

    new_rows[[length(new_rows) + 1L]] <- row
    hae_rows <- rbind(hae_rows, data.frame(
      idx = NA_integer_,
      new_pos = length(new_rows),
      sessionStart = row$sessionStart,
      sessionEnd = row$sessionEnd,
      sport = as.character(row$sport),
      distance = as.numeric(row$distance),
      duration = .workout_secs(row$duration),
      stringsAsFactors = FALSE
    ))
    hae_name <- attr(row, "hae_name")
    if (!is.null(hae_name) && !.hae_sport_is_mapped(hae_name)) {
      unmapped <- c(unmapped, as.character(hae_name))
    }
    if (verbose) cat("HAE ny: ", bn, " [", row$sport, "]\n", sep = "")
  }

  unmapped <- sort(unique(unmapped))
  result$unmapped_names <- unmapped
  result$n_unmapped_sports <- length(unmapped)
  if (length(unmapped) > 0 && verbose) {
    cat("Okänd aktivitetstyp (ingen etikett, ingen bucket): ",
        paste(unmapped, collapse = ", "), "\n", sep = "")
  }

  # Copies struck by a fuller one leave holes; the per-sport tally is
  # taken from what actually survived rather than counted along the way.
  new_rows <- Filter(Negate(is.null), new_rows)
  if (length(new_rows) > 0) {
    sports <- vapply(new_rows, function(r) as.character(r$sport), character(1))
    by_sport <- table(sports)
    by_sport <- stats::setNames(as.integer(by_sport), names(by_sport))
  }
  if (length(new_rows) > 0) {
    # Reduce() rather than do.call(rbind): only the rows that displaced a
    # Garmin fragment carry `superseded_file`, so the columns differ.
    new_df <- Reduce(.rbind_align, new_rows)
    # Align columns: pad missing in summaries or new_df with NA
    summaries <- .rbind_align(summaries, new_df)
    # Add NULL placeholders to myruns
    n_new <- nrow(new_df)
    myruns <- c(myruns, vector("list", n_new))

    result$summaries <- summaries
    result$myruns <- myruns
    result$n_imported <- n_new
    result$by_sport <- by_sport
  }

  # Drop the Garmin fragments last: their positions were taken before any
  # rows were appended, and appending only adds to the end, so they are
  # still valid here.
  if (length(superseded) > 0) {
    drop <- sort(unique(superseded))
    summaries <- .restore_df_attrs(
      result$summaries[-drop, , drop = FALSE], result$summaries)
    rownames(summaries) <- NULL
    myruns <- result$myruns
    keep_runs <- drop[drop <= length(myruns)]
    if (length(keep_runs) > 0) myruns <- myruns[-keep_runs]
    result$summaries <- summaries
    result$myruns <- myruns
  }

  result
}

# Bind two data frames by union of columns, filling NA where absent
.rbind_align <- function(a, b) {
  if (nrow(a) == 0) return(b)
  if (nrow(b) == 0) return(a)
  all_cols <- union(names(a), names(b))
  for (col in setdiff(all_cols, names(a))) a[[col]] <- NA
  for (col in setdiff(all_cols, names(b))) b[[col]] <- NA
  rbind(a[, all_cols, drop = FALSE], b[, all_cols, drop = FALSE],
        deparse.level = 0, make.row.names = FALSE)
}
