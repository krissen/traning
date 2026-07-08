# page_training.R — Tr\u00e4ningsstatus: PMC, ACWR, monotony

page_training_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("pmc"),  "PMC (Fitness / Tr\u00f6tthet / Form)", use_plotly = FALSE),
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

page_training_server <- function(id, data, dates, is_mobile, sport) {
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

    metric_panel_server("pmc",
      plot_fn   = shiny::reactive(fetch.plot.pmc(data,
                                                  from = dr_from(),
                                                  to = dr_to(),
                                                  sport = sp())),
      report_fn = shiny::reactive(report_pmc(data,
                                              from = dr_from(),
                                              to = dr_to(),
                                              sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("acwr",
      plot_fn   = shiny::reactive(fetch.plot.acwr(data,
                                                   from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())),
      report_fn = shiny::reactive(report_acwr(data,
                                               from = dr_from(),
                                               to = dr_to(),
                                               sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("monotony",
      plot_fn   = shiny::reactive(fetch.plot.monotony(data,
                                                       from = dr_from(),
                                                       to = dr_to(),
                                                       sport = sp())),
      report_fn = shiny::reactive(report_monotony(data,
                                                   from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())),
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
