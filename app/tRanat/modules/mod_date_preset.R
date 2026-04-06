# mod_date_preset.R — Global date range selector module

date_preset_ui <- function(id) {
  ns <- shiny::NS(id)
  tags$div(class = "date-preset-container",
    bslib::layout_columns(
      col_widths = bslib::breakpoints(sm = 12, md = c(3, 5, 4)),
      shiny::selectInput(ns("preset"), NULL,
        choices = c(
          "Allt"              = "all",
          "7 dagar"           = "7d",
          "4 veckor"          = "4w",
          "3 m\u00e5nader"    = "3m",
          "6 m\u00e5nader"    = "6m",
          "I \u00e5r"         = "ytd",
          "12 m\u00e5nader"   = "12m",
          "2 \u00e5r"         = "2y",
          "5 \u00e5r"         = "5y",
          "Anpassa\u2026"     = "custom"
        ),
        selected = "12m",
        width = "100%"
      ),
      shiny::conditionalPanel(
        condition = "input.preset === 'custom'",
        ns = ns,
        shiny::dateRangeInput(ns("custom_range"), NULL,
          start     = Sys.Date() - 365,
          end       = Sys.Date(),
          separator = "\u2014",
          width     = "100%"
        )
      ),
      NULL
    )
  )
}

date_preset_server <- function(id) {
  shiny::moduleServer(id, function(input, output, session) {
    shiny::reactive({
      today <- Sys.Date()
      switch(input$preset,
        "all"    = list(from = NULL, to = NULL),
        "7d"     = list(from = today - 7,     to = today),
        "4w"     = list(from = today - 28,    to = today),
        "3m"     = list(from = today - 90,    to = today),
        "6m"     = list(from = today - 182,   to = today),
        "ytd"    = list(from = as.Date(paste0(format(today, "%Y"), "-01-01")),
                        to = today),
        "12m"    = list(from = today - 365,   to = today),
        "2y"     = list(from = today - 730,   to = today),
        "5y"     = list(from = today - 1826,  to = today),
        "custom" = list(from = input$custom_range[1],
                        to   = input$custom_range[2])
      )
    })
  })
}
