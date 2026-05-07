# page_performance.R — Prestation: EF, HRE, decoupling, HR zones, recovery HR

page_performance_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("ef"),  "Efficiency Factor (EF)"),
      metric_panel_ui(ns("hre"), "Heart Rate Efficiency (HRE)")
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("decoupling"), "Aerob dekopp.",
        use_plotly = FALSE)
    ),
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("hr_zones"),     "HR-zoner (Seiler)"),
      metric_panel_ui(ns("recovery_hr"),  "Recovery HR")
    )
  )
}

page_performance_server <- function(id, summaries, myruns, health_daily,
                                     decoupling_data, dates, is_mobile,
                                     sport) {
  force(summaries); force(myruns); force(decoupling_data)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)
    sp      <- shiny::reactive(sport())

    # EF
    metric_panel_server("ef",
      plot_fn   = shiny::reactive(fetch.plot.ef(summaries, from = dr_from(),
                                                  to = dr_to(),
                                                  sport = sp())),
      report_fn = shiny::reactive(report_ef(summaries, from = dr_from(),
                                              to = dr_to(),
                                              sport = sp())),
      is_mobile = is_mobile
    )

    # HRE
    metric_panel_server("hre",
      plot_fn   = shiny::reactive(fetch.plot.hre(summaries, from = dr_from(),
                                                   to = dr_to(),
                                                   sport = sp())),
      report_fn = shiny::reactive(report_hre(summaries, from = dr_from(),
                                               to = dr_to(),
                                               sport = sp())),
      is_mobile = is_mobile
    )

    # Decoupling — renderPlot (faceted, works better static for this
    # one). The decoupling cache is keyed to running; for any other
    # sport we recompute, but cache the result via shiny::reactive() so
    # the plot and table renders share one full-history pass instead
    # of triggering two on every reactive invalidation.
    decoupling_for_sport <- shiny::reactive({
      if (identical(sp(), "running")) {
        decoupling_data
      } else {
        compute_decoupling(summaries, myruns, sport = sp())
      }
    })

    metric_panel_server("decoupling",
      plot_fn = shiny::reactive({
        fetch.plot.decoupling(summaries, myruns,
          from = dr_from(), to = dr_to(),
          decoupling_data = decoupling_for_sport(),
          sport = sp())
      }),
      report_fn = shiny::reactive({
        report_decoupling(summaries = summaries, myruns = myruns,
          from = dr_from(), to = dr_to(),
          decoupling_data = decoupling_for_sport(),
          sport = sp())
      }),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )

    # HR Zones
    metric_panel_server("hr_zones",
      plot_fn = shiny::reactive({
        fetch.plot.hr_zones(summaries, from = dr_from(), to = dr_to(),
                             sport = sp())
      }),
      report_fn = shiny::reactive({
        report_hr_zones(summaries, from = dr_from(), to = dr_to(),
                        sport = sp())
      }),
      is_mobile = is_mobile
    )

    # Recovery HR
    metric_panel_server("recovery_hr",
      plot_fn = shiny::reactive({
        fetch.plot.recovery_hr(summaries, from = dr_from(), to = dr_to(),
                                sport = sp())
      }),
      report_fn = shiny::reactive({
        report_recovery_hr(summaries, from = dr_from(), to = dr_to(),
                           sport = sp())
      }),
      is_mobile = is_mobile
    )
  })
}
