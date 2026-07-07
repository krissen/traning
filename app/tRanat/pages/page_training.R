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

page_training_server <- function(id, summaries, health_daily, dates,
                                  is_mobile, sport) {
  force(summaries)
  force(health_daily)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)
    sp      <- shiny::reactive(sport())
    # fetch.plot.pmc/acwr and report_pmc/acwr are S7-migrated (PR 4):
    # they take a single traning_data bundle instead of separate
    # summaries/health_daily args. Build it once and reuse.
    td_bundle <- traning_data(summaries = summaries, health_daily = health_daily,
                               augmented = "garmin_matched" %in% names(summaries))

    metric_panel_server("pmc",
      plot_fn   = shiny::reactive(fetch.plot.pmc(td_bundle,
                                                  from = dr_from(),
                                                  to = dr_to(),
                                                  sport = sp())),
      report_fn = shiny::reactive(report_pmc(td_bundle,
                                              from = dr_from(),
                                              to = dr_to(),
                                              sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("acwr",
      plot_fn   = shiny::reactive(fetch.plot.acwr(td_bundle,
                                                   from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())),
      report_fn = shiny::reactive(report_acwr(td_bundle,
                                               from = dr_from(),
                                               to = dr_to(),
                                               sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("monotony",
      plot_fn   = shiny::reactive(fetch.plot.monotony(summaries,
                                                       from = dr_from(),
                                                       to = dr_to(),
                                                       sport = sp())),
      report_fn = shiny::reactive(report_monotony(summaries,
                                                   from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("pace_week_delta",
      plot_fn = shiny::reactive(fetch.plot.pace_week_delta(summaries,
                                                            from = dr_from(),
                                                            to = dr_to(),
                                                            sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
  })
}
