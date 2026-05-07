# mod_sport_select.R — global sport bucket selector.
#
# Mirrors the curated buckets exposed by R/sport_filter.R so the
# selector and the underlying data path stay in sync.

# Curated buckets that aggregate multiple sports. Sourced from
# traning::sport_bucket_names() so the Shiny dropdown and the
# page-level "is this a population narrow-down?" check stay in sync
# with .SPORT_BUCKETS in R/sport_filter.R.
SPORT_BUCKET_VALUES <- traning::sport_bucket_names()

sport_select_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::selectInput(
    ns("sport"),
    label = "Sport",  # visible label needed for screen readers
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
