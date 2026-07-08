# page_training.R — Träningsstatus: PMC, ACWR, monotony

page_training_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = 6, class = "section-spacer",
      metric_panel_ui(ns("pmc"),  "PMC (Fitness / Trötthet / Form)", use_plotly = FALSE),
      metric_panel_ui(ns("acwr"), "ACWR (Belastningskvot)", use_plotly = FALSE)
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("monotony"), "Monotoni & Strain", use_plotly = FALSE)
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("pace_week_delta"),
                      "Δ Mediantempo per vecka",
                      use_plotly = FALSE,
                      with_table = FALSE)
    )
  )
}

page_training_server <- function(id, data, dates, is_mobile, sport, data_version) {
  force(data)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)
    sp      <- shiny::reactive(sport())
    # fetch.plot.pmc/acwr/monotony and report_pmc/acwr/monotony are
    # S7-migrated (PR 4): they take a single traning_data bundle
    # instead of separate summaries/health_daily args. `data` is that
    # bundle already. fetch.plot.pace_week_delta is NOT migrated — it
    # still takes a bare summaries data.frame, so pass @summaries.
    #
    # bindCache(): pmc/acwr/monotony call compute_pmc()/compute_acwr()/
    # compute_monotony_strain() internally — genuinely expensive. Key
    # is (from, to, sport, data_version); data_version (a cache-file
    # mtime snapshot taken in app.R just before this session's `data`
    # was loaded) is required because bindCache's default cache is
    # app-scoped (shared across ALL sessions of this R process) — a
    # session started after a mid-run import gets a fresh data_version
    # and therefore a fresh key, so it never reads a plot cached by an
    # older session against stale data. pace_week_delta is cheap (no
    # compute_*) and stays uncached.

    metric_panel_server("pmc",
      plot_fn   = shiny::reactive(fetch.plot.pmc(data,
                                                  from = dr_from(),
                                                  to = dr_to(),
                                                  sport = sp())) |>
        shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      report_fn = shiny::reactive(report_pmc(data,
                                              from = dr_from(),
                                              to = dr_to(),
                                              sport = sp())) |>
        shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("acwr",
      plot_fn   = shiny::reactive(fetch.plot.acwr(data,
                                                   from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())) |>
        shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      report_fn = shiny::reactive(report_acwr(data,
                                               from = dr_from(),
                                               to = dr_to(),
                                               sport = sp())) |>
        shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("monotony",
      plot_fn   = shiny::reactive(fetch.plot.monotony(data,
                                                       from = dr_from(),
                                                       to = dr_to(),
                                                       sport = sp())) |>
        shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      report_fn = shiny::reactive(report_monotony(data,
                                                   from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())) |>
        shiny::bindCache(dr_from(), dr_to(), sp(), data_version),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("pace_week_delta",
      plot_fn = shiny::reactive(fetch.plot.pace_week_delta(data@summaries,
                                                            from = dr_from(),
                                                            to = dr_to(),
                                                            sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
  })
}
