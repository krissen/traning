# mod_sport_select.R — global sport bucket selector.
#
# Mirrors the curated buckets exposed by R/sport_filter.R so the
# selector and the underlying data path stay in sync.

sport_select_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::selectInput(
    ns("sport"), NULL,
    choices = list(
      "Direkta sporter" = c(
        "Löpning"        = "running",
        "Cykling"        = "cycling",
        "Gång"           = "walking",
        "Simning"        = "swimming",
        "Styrketräning"  = "strength",
        "Bordtennis"     = "bordtennis",
        "Badminton"      = "badminton",
        "Övrigt"         = "ovrigt"
      ),
      "Sammansatta" = c(
        "Konditionspass (löp+cyk+gång+sim)" = "endurance",
        "Bollsport"   = "ballsport",
        "Gymträning"  = "gym",
        "Vintersport" = "wintersport",
        "Alla sporter" = "all"
      )
    ),
    selected = "running",
    width    = "100%"
  )
}

sport_select_server <- function(id) {
  shiny::moduleServer(id, function(input, output, session) {
    shiny::reactive({
      val <- input$sport
      if (is.null(val) || !nzchar(val)) "running" else val
    })
  })
}
