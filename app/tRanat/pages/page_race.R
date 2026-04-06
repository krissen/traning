# page_race.R — T\u00e4vling: placeholder for Phase 5d

page_race_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::card(class = "placeholder-card mt-3",
    tags$div(class = "placeholder-icon", "\U0001F3C1"),
    tags$h4("T\u00e4vlingsplanering"),
    tags$p(
      "H\u00e4r kommer verktyg f\u00f6r att planera inf\u00f6r t\u00e4vling:",
      tags$br(),
      tags$strong("Taper-plan"), " \u2014 veckovis km-m\u00e5l med ACWR-begr\u00e4nsning",
      tags$br(),
      tags$strong("Race readiness"), " \u2014 CTL/ACWR/HRV-bed\u00f6mning inf\u00f6r m\u00e5ldatum"
    ),
    tags$p(class = "text-muted", "Fas 5d \u2014 kr\u00e4ver MCP-server (5c)")
  )
}

page_race_server <- function(id, summaries, dates, is_mobile) {
  shiny::moduleServer(id, function(input, output, session) {
    # Placeholder — no server logic yet
  })
}
