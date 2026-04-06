# page_overview.R — \u00d6versikt: assembles overview dashboard

page_overview_ui <- function(id) {
  ns <- shiny::NS(id)
  overview_ui(ns("dashboard"))
}

page_overview_server <- function(id, summaries, health_daily, myruns,
                                  decoupling_data, dates, is_mobile) {
  force(summaries); force(health_daily); force(myruns); force(decoupling_data)
  shiny::moduleServer(id, function(input, output, session) {
    overview_server("dashboard", summaries, health_daily, myruns,
                    decoupling_data, dates, is_mobile)
  })
}
