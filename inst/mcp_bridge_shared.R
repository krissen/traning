# Shared dispatch logic for the Vayu MCP R bridge.
#
# Sourced by both the per-call bridge (inst/mcp_bridge.R, spawned fresh
# for every MCP tool call) and the persistent warm bridge
# (inst/mcp_bridge_server.R, loaded once and reused across calls). This
# file defines only pure functions and static data — no side effects,
# no stdout/stderr I/O, no top-level execution — so it is safe to
# `source()` from either entry point without changing either one's
# behavior.
#
# Splitting this out is a pure de-duplication: func_registry and
# build_call_args used to be defined inline in mcp_bridge.R. Moving
# them here (and giving build_call_args an explicit `bundle` parameter
# instead of relying on lexical scoping into a script-global `bundle`
# variable) does not change the JSON any function call produces.

# .load_traning(): load the `traning` package for a bridge invocation
# (spawn or warm-server boot).
#
# Production default is `library(traning)` against the INSTALLED
# package — ~0.45s faster per call than devtools::load_all() (measured:
# ~0.47s vs ~0.92s), which matters for the per-call spawn path
# (inst/mcp_bridge.R) and only happens ONCE for the warm server
# (inst/mcp_bridge_server.R), where it matters even more (boot cost is
# amortized over the process lifetime, not paid per call). The tradeoff
# is that library() serves whatever was installed at the last
# `deploy.sh code` run, not the live checkout — deploy.sh runs
# `R CMD INSTALL` on every code deploy so the installed package can't
# go stale.
#
# Two escape hatches:
#   - TRANING_BRIDGE_LOADER=load_all forces devtools::load_all(pkg_root) —
#     used by tests/testthat/test-mcp-bridge.R so the bridge always
#     exercises the current branch's source, not a possibly-stale install.
#   - If library(traning) fails outright (package never installed on this
#     box), fall back to load_all so the bridge still works out of a bare
#     checkout; a warning is written to stderr so the fallback is visible
#     without corrupting the stdout JSON channel.
#
# All diagnostic output from this function goes to stderr via message() —
# stdout is reserved for framed JSON responses.
.load_traning <- function(pkg_root) {
  use_load_all <- identical(Sys.getenv("TRANING_BRIDGE_LOADER"), "load_all")

  if (use_load_all) {
    suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))
    message("mcp_bridge: loaded traning via load_all (TRANING_BRIDGE_LOADER=load_all)")
    return(invisible("load_all"))
  }

  loaded <- tryCatch({
    suppressMessages(library(traning, character.only = FALSE))
    TRUE
  }, error = function(e) FALSE)

  if (loaded) {
    message(sprintf(
      "mcp_bridge: loaded traning via library() (version %s)",
      as.character(utils::packageVersion("traning"))
    ))
    return(invisible("library"))
  }

  message("mcp_bridge: library(traning) failed (package not installed?); falling back to load_all")
  suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))
  invisible("load_all_fallback")
}

# --- Function whitelist ---
# Each entry maps to: list of required data sources
# s = summaries, m = myruns, h = health_daily, g = garmin augmentation,
# z = zone cache, d = decoupling cache
func_registry <- list(
  # Basic reports (summaries only)
  report_monthtop        = "s",
  report_runs_year_month = "s",
  report_monthlast       = "s",
  report_yearstop        = "s",
  report_yearstatus      = "s",
  report_monthstatus     = "s",
  report_datesum         = "s",
  report_ef              = "s",
  report_hre             = "s",
  # ACWR / PMC need health_daily so the multi-sport (TRIMP-mode) paths
  # can fold in background-activity TRIMP from steps/walking distance.
  report_acwr            = "sh",
  report_monotony        = "s",
  report_pmc             = "sh",
  # Garmin-augmented reports
  report_recovery_hr     = "sg",
  report_hr_zones        = "smgz",
  report_decoupling      = "smgd",
  # Health reports
  report_readiness       = "sh",
  report_metric          = "h",
  # Alcohol reports read the nights table from its own cache
  # (load_alcohol_data()), but still need health_daily for the energy
  # denominator and summaries for the Garmin rest-day suppression.
  report_alcohol         = "sh",
  report_alcohol_weekly  = "sh",
  health_insight_readiness = "sh",
  health_insight_update    = "sh",
  recent_data_dump         = "sh",
  latest_known_metrics     = "h",
  # Basic plots (summaries only)
  plot_monthtop          = "s",
  plot_runs_month        = "s",
  plot_monthstatus       = "s",
  plot_monthlast         = "s",
  plot_yearstop          = "s",
  plot_datesum           = "s",
  # Löpprofil — yearly characterization plots
  fetch.plot.pace_year          = "s",
  fetch.plot.pace_year_ridges   = "s",
  fetch.plot.pace_tertile_share = "s",
  fetch.plot.longest_runs_year  = "s",
  fetch.plot.season_pace        = "s",
  fetch.plot.heatmap_km         = "s",
  fetch.plot.cumulative_km      = "s",
  fetch.plot.distance_pace_era  = "s",
  # Advanced plots (summaries only)
  fetch.plot.ef          = "s",
  fetch.plot.hre         = "s",
  # ACWR / PMC plots need health_daily so multi-sport (TRIMP-mode)
  # paths render background-activity TRIMP in the volume panel.
  fetch.plot.acwr        = "sh",
  fetch.plot.monotony    = "s",
  fetch.plot.pmc         = "sh",
  # Garmin-augmented plots
  fetch.plot.recovery_hr = "sg",
  fetch.plot.hr_zones    = "sgz",
  fetch.plot.decoupling  = "smgd",
  # Health plots
  fetch.plot.resting_hr  = "sh",
  fetch.plot.hrv         = "h",
  fetch.plot.sleep       = "h",
  fetch.plot.vo2max      = "shg",
  fetch.plot.readiness_score = "sh",
  # Multi-sport plots
  plot_sport_mix         = "s",
  plot_sport_ctl_overlay = "s",
  plot_sport_calendar    = "s",
  # Phase 5d — race
  compute_taper_plan       = "s",
  compute_race_readiness   = "sh"
)

# --- Build function arguments ---
# Map JSON args to R function arguments.  Common patterns:
#   n, from, to — date range / limit
#   Other args vary by function.
#
# `bundle` is the traning_data object built by the caller for this
# request (see the "Build the traning_data bundle" block in
# mcp_bridge.R / the memoized equivalent in mcp_bridge_server.R) — it
# is injected as the `data =` argument at the end, identically for
# every func_registry entry.
build_call_args <- function(func_name, func_args, bundle) {
  a <- list()

  # Functions that accept 'n' parameter (report functions, not plot functions)
  n_funcs <- c(
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_ef", "report_hre", "report_acwr", "report_monotony",
    "report_pmc", "report_recovery_hr", "report_hr_zones",
    "report_decoupling", "report_readiness", "report_metric"
  )

  # Functions that accept a 'sport' parameter (for sport-agnostic
  # filtering — running, cycling, walking, ...). Plot wrappers inherit
  # via their underlying report_* / compute_* call.
  sport_funcs <- c(
    "report_monthtop", "report_runs_year_month", "report_monthlast",
    "report_yearstop", "report_yearstatus", "report_monthstatus",
    "report_datesum", "report_ef", "report_hre", "report_acwr",
    "report_monotony", "report_pmc", "report_recovery_hr",
    "report_hr_zones", "report_decoupling",
    "plot_monthtop", "plot_runs_month", "plot_monthstatus",
    "plot_monthlast", "plot_yearstop", "plot_datesum",
    "fetch.plot.ef", "fetch.plot.hre", "fetch.plot.acwr",
    "fetch.plot.monotony", "fetch.plot.pmc", "fetch.plot.recovery_hr",
    "fetch.plot.hr_zones", "fetch.plot.decoupling",
    # Löpprofil
    "fetch.plot.pace_year", "fetch.plot.pace_year_ridges",
    "fetch.plot.pace_tertile_share", "fetch.plot.longest_runs_year",
    "fetch.plot.season_pace", "fetch.plot.heatmap_km",
    "fetch.plot.cumulative_km", "fetch.plot.distance_pace_era",
    # Multi-sport plots that accept `sport=` as a population filter
    # (default NULL = all sports). plot_sport_ctl_overlay is omitted
    # because it takes a `sports` vector instead of a single bucket;
    # see the multi-sport extras block below.
    "plot_sport_mix", "plot_sport_calendar"
  )

  if (!is.null(func_args$n) && func_name %in% n_funcs)
    a$n <- as.integer(func_args$n)
  # Date args can arrive as ISO strings (YYYY, YYYY-MM, YYYY-MM-DD) or
  # relative expressions like "-2w" / "-1y" — Python's _build_args
  # passes them through verbatim, except for absolute ISO `before`
  # values where +1 day is already added so the user-facing
  # "inclusive" boundary becomes our exclusive `to`. parse_date_expr()
  # handles both forms; for relative `to` we apply the same +1 day
  # shift here so a "-2w" boundary day still gets included.
  .is_relative_date <- function(x) {
    is.character(x) && length(x) == 1 && grepl("^-\\d+[dwmy]$", x)
  }
  if (!is.null(func_args$from))    a$from   <- parse_date_expr(func_args$from)
  if (!is.null(func_args$to)) {
    a$to <- parse_date_expr(func_args$to)
    if (.is_relative_date(func_args$to)) a$to <- a$to + 1L
  }
  if (!is.null(func_args$hr_max))  a$hr_max <- as.numeric(func_args$hr_max)
  if (!is.null(func_args$hr_rest)) a$hr_rest <- as.numeric(func_args$hr_rest)
  if (!is.null(func_args$metric))  a$metric <- func_args$metric
  if (!is.null(func_args$sport) && func_name %in% sport_funcs)
    a$sport <- as.character(func_args$sport)
  if (!is.null(func_args$recent) && func_name == "report_runs_year_month")
    a$recent <- isTRUE(func_args$recent)

  # Every func_registry function takes a single `data =` traning_data
  # bundle (see the "Build the traning_data bundle" block above). `a` is
  # built here from JSON args only; `bundle` is injected generically, at
  # the end of this function (see below) — everything from here down is
  # purely per-function SCALAR argument extraction.

  # Phase 5d: race tools.
  if (func_name == "compute_taper_plan") {
    if (!is.null(func_args$race_date))
      a$race_date <- as.Date(func_args$race_date)
    if (!is.null(func_args$distance_km))
      a$distance_km <- as.numeric(func_args$distance_km)
    if (!is.null(func_args$taper_weeks))
      a$taper_weeks <- as.integer(func_args$taper_weeks)
  }
  if (func_name == "compute_race_readiness") {
    if (!is.null(func_args$target_date))
      a$target_date <- as.Date(func_args$target_date)
    if (!is.null(func_args$taper_weeks))
      a$taper_weeks <- as.integer(func_args$taper_weeks)
  }

  # Multi-sport plot extras
  if (func_name == "plot_sport_mix") {
    if (!is.null(func_args$period)) a$period <- as.character(func_args$period)
    if (!is.null(func_args$min_value)) {
      a$min_value <- as.numeric(func_args$min_value)
    } else if (!is.null(func_args$min_km)) {
      # Backward-compat: pre-2026-05 MCP clients sent `min_km`. Map it
      # to the renamed `min_value` so they keep working until they
      # upgrade. `min_value` (when both are sent) wins.
      a$min_value <- as.numeric(func_args$min_km)
    }
    # `metric` is already injected above (it's a generic forwarded arg);
    # plot_sport_mix accepts "distance" / "duration" / "trimp".
  }
  if (func_name == "plot_sport_ctl_overlay") {
    if (!is.null(func_args$sports)) {
      # JSON arrays arrive as a list under simplifyVector = FALSE, so
      # as.character() on the list itself would error. Coerce each
      # element to a scalar string explicitly.
      a$sports <- vapply(func_args$sports,
                          function(x) as.character(x)[[1]],
                          character(1))
    }
  }

  # report_datesum / plot_datesum: special positional args
  if (func_name %in% c("report_datesum", "plot_datesum")) {
    dr_from <- if (!is.null(func_args$from)) parse_date_expr(func_args$from)
               else as.Date("1970-01-01")
    dr_to   <- if (!is.null(func_args$to))   parse_date_expr(func_args$to)
               else Sys.Date() + 1
    # report_datesum/plot_datesum take do_datesum_from/do_datesum_to, not
    # the generic from/to that the date handler above stashed into `a` —
    # drop those so they don't reach the (from/to-less) function formals.
    a$from <- NULL
    a$to   <- NULL
    a <- c(list(do_datesum_from = dr_from, do_datesum_to = dr_to), a)
    if (!is.null(func_args$sport)) {
      a$sport <- as.character(func_args$sport)
    }
  }

  # report_alcohol / report_alcohol_weekly take `after`/`before` instead
  # of the house `from`/`to`, and treat the upper bound as INCLUSIVE
  # (filter_by_daterange(..., closed_upper = TRUE)). So the generic
  # from/to values stashed above are dropped and re-bound by name, with
  # no +1 day shift — Python's get_alcohol() deliberately sends the
  # boundary unshifted for the same reason.
  if (func_name %in% c("report_alcohol", "report_alcohol_weekly")) {
    a$from <- NULL
    a$to   <- NULL
    if (!is.null(func_args$from)) a$after  <- parse_date_expr(func_args$from)
    if (!is.null(func_args$to))   a$before <- parse_date_expr(func_args$to)
  }

  if (func_name == "recent_data_dump" && !is.null(func_args$hours)) {
    a$hours <- as.numeric(func_args$hours)
  }
  if (func_name == "health_insight_readiness" && !is.null(func_args$on_date)) {
    a$on_date <- as.Date(func_args$on_date)
  }
  if (func_name == "health_insight_update") {
    if (!is.null(func_args$prev_state)) {
      a$prev_state <- func_args$prev_state
    }
    if (!is.null(func_args$on_date)) {
      a$on_date <- as.Date(func_args$on_date)
    }
  }

  # Every func_registry function takes `data` as its first formal —
  # inject the bundle passed in by the caller generically, for every
  # call.
  c(list(data = bundle), a)
}

# --- Execute + shape the response envelope ---
# Runs func_name(call_args...) and returns a response envelope list
# (never emits JSON, never quits) — same three shapes mcp_bridge.R has
# always produced on stdout:
#   list(type = "plot", path = <path R wrote the PNG to>)
#   list(type = "data", rows = <n>, data = <data.frame>)
#   list(type = "data", data = <result>)          # non-data.frame result
#   list(type = "error", message = <string>)       # on any error
run_dispatch <- function(func_name, call_args, do_plot, plot_path) {
  tryCatch({
    result <- do.call(func_name, call_args)

    if (do_plot || inherits(result, "gg") || inherits(result, "patchwork")) {
      # Prefer the path the caller passed in (--plot_path / request
      # plot_path) so the PNG survives process exit. tempfile() lives
      # under R's per-process tempdir, which for the per-call bridge
      # gets removed on quit() before Python can read it; for the warm
      # server there's no such tempdir race, but the caller-owned path
      # is still required (ownership/verification lives in Python).
      out_path <- if (!is.null(plot_path) && nzchar(plot_path)) {
        plot_path
      } else {
        tempfile(pattern = "vayu_", fileext = ".png")
      }
      dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
      ggplot2::ggsave(out_path, plot = result, width = 10, height = 6,
                      dpi = 150, bg = "white")
      list(type = "plot", path = out_path)
    } else if (is.data.frame(result)) {
      list(type = "data", rows = nrow(result), data = result)
    } else {
      list(type = "data", data = result)
    }
  }, error = function(e) {
    list(type = "error",
        message = paste0("R error in ", func_name, ": ", conditionMessage(e)))
  })
}
