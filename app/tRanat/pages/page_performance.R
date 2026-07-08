# page_performance.R — Prestation: EF, HRE, decoupling, HR zones, recovery HR

page_performance_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = 6, class = "section-spacer",
      metric_panel_ui(ns("ef"),  "Efficiency Factor (EF)"),
      metric_panel_ui(ns("hre"), "Heart Rate Efficiency (HRE)")
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("decoupling"), "Aerob dekopp.",
        use_plotly = FALSE)
    ),
    bslib::layout_columns(col_widths = 6, class = "section-spacer",
      metric_panel_ui(ns("hr_zones"),     "HR-zoner (Seiler)"),
      metric_panel_ui(ns("recovery_hr"),  "Recovery HR")
    )
  )
}

page_performance_server <- function(id, data, dates, is_mobile, sport, data_version) {
  force(data)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)
    sp      <- shiny::reactive(sport())

    # EF / HRE only read @summaries and take `sport` as an explicit
    # arg (not @sport-keyed), so the base bundle is safe to pass as-is
    # for any sport selection.
    metric_panel_server("ef",
      plot_fn   = shiny::reactive(fetch.plot.ef(data, from = dr_from(),
                                                  to = dr_to(),
                                                  sport = sp())),
      report_fn = shiny::reactive(report_ef(data, from = dr_from(),
                                              to = dr_to(),
                                              sport = sp())),
      is_mobile = is_mobile
    )

    # HRE
    metric_panel_server("hre",
      plot_fn   = shiny::reactive(fetch.plot.hre(data, from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())),
      report_fn = shiny::reactive(report_hre(data, from = dr_from(),
                                               to = dr_to(),
                                               sport = sp())),
      is_mobile = is_mobile
    )

    # Decoupling — renderPlot (faceted, works better static for this
    # one). fetch.plot.decoupling()/report_decoupling() read
    # @decoupling_data directly and recompute only when it's NULL, and
    # the cache is sport-keyed (see traning_data() docs) — so we must
    # not hand them the base bundle's running-only @decoupling_data
    # under a different @sport. S7 objects are copy-on-modify: `b <-
    # data; b@sport <- sp()` yields an independent, re-validated copy.
    # For the running default we keep the base bundle's @decoupling_data
    # (already sport="running", matching load_session_data()). For any
    # other sport, compute_decoupling() is date-independent (it scores
    # every qualifying session; date filtering happens downstream in
    # fetch.plot.decoupling()/report_decoupling() via from/to), so we
    # compute it ONCE here — in a single shared reactive — and populate
    # @decoupling_data with the result. Without this, plot_fn and
    # report_fn below would each hit fetch.plot.decoupling()'s/
    # report_decoupling()'s own "if NULL, compute_decoupling()"
    # fallback independently, duplicating the expensive computation on
    # every invalidation for non-running sports.
    decoupling_bundle <- shiny::reactive({
      b <- data
      b@sport <- sp()
      if (!identical(sp(), "running")) {
        b@decoupling_data <- compute_decoupling(b@summaries, b@myruns,
                                                 sport = sp())
      }
      b
    }) |> shiny::bindCache(sp(), data_version)

    # bindCache(): fetch.plot.decoupling()/report_decoupling() now read
    # the pre-populated @decoupling_data from decoupling_bundle() above
    # (memoized per sport()+data_version, so the expensive
    # compute_decoupling() call itself only runs once per invalidation
    # rather than once per plot_fn/report_fn). This bindCache still
    # caches the rendered plot/table for a given (from, to, sport,
    # data_version) combination. data_version guards against bindCache's
    # app-scoped (cross-session) default cache serving a stale plot to a
    # session that loaded newer data — see page_training.R for the full
    # rationale.
    metric_panel_server("decoupling",
      plot_fn = shiny::reactive({
        fetch.plot.decoupling(decoupling_bundle(),
          from = dr_from(), to = dr_to(), sport = sp())
      }) |> shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      report_fn = shiny::reactive({
        report_decoupling(decoupling_bundle(),
          from = dr_from(), to = dr_to(), sport = sp())
      }) |> shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )

    # HR Zones — no precomputed zone_data cache is threaded through the
    # app (this mirrors pre-migration behaviour: hr_zones always
    # recomputes on the fly for the current sport), so drop @zone_data
    # (already NULL on the base bundle) and just track @sport.
    hr_zones_bundle <- shiny::reactive({
      b <- data
      b@sport <- sp()
      b@zone_data <- NULL
      b
    })

    metric_panel_server("hr_zones",
      plot_fn = shiny::reactive({
        fetch.plot.hr_zones(hr_zones_bundle(), from = dr_from(), to = dr_to(),
                             sport = sp())
      }),
      report_fn = shiny::reactive({
        report_hr_zones(hr_zones_bundle(), from = dr_from(), to = dr_to(),
                        sport = sp())
      }),
      is_mobile = is_mobile
    )

    # Recovery HR — reads only @summaries; no sport-keyed cache
    # involved, but @sport is tracked for consistency with the panels
    # above.
    recovery_hr_bundle <- shiny::reactive({
      b <- data
      b@sport <- sp()
      b
    })

    metric_panel_server("recovery_hr",
      plot_fn = shiny::reactive({
        fetch.plot.recovery_hr(recovery_hr_bundle(), from = dr_from(), to = dr_to(),
                                sport = sp())
      }),
      report_fn = shiny::reactive({
        report_recovery_hr(recovery_hr_bundle(), from = dr_from(), to = dr_to(),
                           sport = sp())
      }),
      is_mobile = is_mobile
    )
  })
}
