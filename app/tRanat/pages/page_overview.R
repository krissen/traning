# page_overview.R — \u00d6versikt: assembles overview dashboard

page_overview_ui <- function(id) {
  ns <- shiny::NS(id)
  overview_ui(ns("dashboard"))
}

page_overview_server <- function(id, data, dates, is_mobile) {
  force(data)
  shiny::moduleServer(id, function(input, output, session) {
    overview_server("dashboard", data, dates, is_mobile)
  })
}
