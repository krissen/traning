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
    )
  )
}

page_training_server <- function(id, summaries, dates, is_mobile) {
  force(summaries)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)

    metric_panel_server("pmc",
      plot_fn   = shiny::reactive(fetch.plot.pmc(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_pmc(summaries, from = dr_from(), to = dr_to())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("acwr",
      plot_fn   = shiny::reactive(fetch.plot.acwr(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_acwr(summaries, from = dr_from(), to = dr_to())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
    metric_panel_server("monotony",
      plot_fn   = shiny::reactive(fetch.plot.monotony(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_monotony(summaries, from = dr_from(), to = dr_to())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
  })
}
