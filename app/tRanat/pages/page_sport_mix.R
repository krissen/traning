# page_sport_mix.R — Sport-mix overview
#
# Hosts the multi-sport plots from R/plot_multisport.R: stacked bar of
# distance per period × sport, cross-sport CTL overlay, and the daily
# activity-calendar heatmap.

page_sport_mix_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Sport-mix per period"),
      bslib::card_body(
        bslib::layout_columns(
          col_widths = bslib::breakpoints(sm = 12, md = 4),
          shiny::selectInput(ns("period"), "Period",
            choices = c("Månad" = "month",
                        "Vecka" = "week",
                        "År"    = "year"),
            selected = "month",
            width = "100%"
          )
        ),
        plotly::plotlyOutput(ns("plot_mix"), height = "420px")
      )
    ),
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Kronisk belastning per sport"),
      bslib::card_body(
        bslib::layout_columns(
          col_widths = bslib::breakpoints(sm = 12, md = 8),
          shiny::checkboxGroupInput(ns("ctl_sports"),
            "Sporter att överlagra",
            choices = c(
              "Löpning" = "running",
              "Cykling" = "cycling",
              "Gång"    = "walking",
              "Simning" = "swimming",
              "Totalt"  = "all"
            ),
            selected = c("running", "cycling", "walking", "all"),
            inline = TRUE
          )
        ),
        plotly::plotlyOutput(ns("plot_ctl"), height = "380px")
      )
    ),
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Aktivitetskalender"),
      bslib::card_body(
        shiny::plotOutput(ns("plot_calendar"), height = "320px")
      )
    )
  )
}

page_sport_mix_server <- function(id, summaries, dates, is_mobile, sport) {
  force(summaries)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)
    sp      <- shiny::reactive(sport())

    ply <- function(p) {
      pp <- plotly::ggplotly(p) |>
        plotly::config(displayModeBar = !is_mobile())
      if (is_mobile()) {
        pp <- pp |> plotly::layout(
          dragmode = FALSE,
          xaxis = list(fixedrange = TRUE),
          yaxis = list(fixedrange = TRUE)
        )
      }
      pp
    }

    output$plot_mix <- plotly::renderPlotly({
      shiny::req(input$period)
      sp_val <- sp()
      # On the Sport-mix tab, "running" as an *override* would defeat
      # the purpose of seeing the mix — treat the page-level dropdown
      # as a population narrow-down only when it's a curated bucket
      # (endurance/ballsport/gym/wintersport) or "all". For plain
      # sport names, fall back to "all" so all sports show up.
      pop <- if (sp_val %in% c("endurance", "ballsport", "gym",
                                "wintersport", "all")) sp_val else NULL
      ply(plot_sport_mix(summaries, period = input$period,
                          from = dr_from(), to = dr_to(),
                          sport = pop))
    })

    output$plot_ctl <- plotly::renderPlotly({
      shiny::req(input$ctl_sports)
      ply(plot_sport_ctl_overlay(summaries,
                                  sports = input$ctl_sports,
                                  from = dr_from(), to = dr_to()))
    })

    output$plot_calendar <- shiny::renderPlot({
      pop <- if (sp() %in% c("endurance", "ballsport", "gym",
                              "wintersport", "all")) sp() else NULL
      plot_sport_calendar(summaries, from = dr_from(), to = dr_to(),
                           sport = pop)
    })
  })
}
