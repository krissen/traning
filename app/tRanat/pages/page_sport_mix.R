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
          col_widths = bslib::breakpoints(sm = 12, md = c(4, 4)),
          shiny::selectInput(ns("period"), "Period",
            choices = c("Månad" = "month",
                        "Vecka" = "week",
                        "År"    = "year"),
            selected = "month",
            width = "100%"
          ),
          shiny::radioButtons(ns("metric"), "Mätare",
            choices = c("Distans (km)" = "distance",
                        "Tid (min)"    = "duration",
                        "TRIMP"        = "trimp"),
            selected = "distance",
            inline = TRUE
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
          shiny::uiOutput(ns("ctl_sports_ui"))
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
  # Bucket allowlist sourced directly from the package so this page's
  # logic doesn't depend on mod_sport_select having been sourced first.
  bucket_values <- traning::sport_bucket_names()

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

    # Sport-mix tab semantics: a curated bucket (endurance / ballsport
    # / gym / wintersport / all) narrows the population while still
    # showing the mix; a plain sport name like "running" would defeat
    # the point of this tab, so fall back to "all" in that case.
    population_sport <- shiny::reactive({
      if (sp() %in% bucket_values) sp() else "all"
    })

    # Pre-scope summaries so all three cards describe the same
    # population; otherwise picking "gym" or "ballsport" would still
    # show the full running/cycling/walking CTL overlay.
    scoped_summaries <- shiny::reactive({
      pop <- population_sport()
      if (identical(pop, "all")) summaries
      else traning::filter_sport(summaries, pop)
    })

    # CTL overlay: derive selectable sports from the active bucket so
    # buckets like "ballsport" / "gym" / "wintersport" expose their
    # actual member sports instead of the previous endurance-only
    # hard-coded list (which left those buckets with empty overlays).
    # For "all" we use the sports actually present in the data so the
    # checkbox row reflects what the user can actually overlay
    # (instead of a fixed running/cycling/walking/swimming list that
    # ignored e.g. strength or wintersport activity).
    ctl_choices <- shiny::reactive({
      pop <- population_sport()
      members <- if (identical(pop, "all")) {
        if ("sport" %in% names(scoped_summaries())) {
          present <- unique(scoped_summaries()$sport)
          present <- present[!is.na(present) & nzchar(present)]
          if (length(present) > 12) {
            # Keep the panel readable — pick the 12 most common
            # sports by row count.
            counts <- sort(table(scoped_summaries()$sport),
                           decreasing = TRUE)
            present <- names(counts)[seq_len(min(12, length(counts)))]
          }
          sort(present)
        } else {
          character(0)
        }
      } else {
        traning::sport_bucket_members(pop)
      }
      if (is.null(members) || length(members) == 0) {
        members <- c("running", "cycling", "walking", "swimming")
      }
      labels <- vapply(members, traning::sport_label, character(1))
      vals   <- c(members, "all")
      names(vals) <- c(labels, "Totalt")
      vals
    })

    output$ctl_sports_ui <- shiny::renderUI({
      choices <- ctl_choices()
      # Default-select up to four members + the "Totalt" series so the
      # overlay starts with something meaningful regardless of bucket.
      preselect <- utils::head(choices, 4)
      shiny::checkboxGroupInput(session$ns("ctl_sports"),
        "Sporter att överlagra",
        choices  = choices,
        selected = c(preselect, "all"),
        inline   = TRUE
      )
    })

    output$plot_mix <- plotly::renderPlotly({
      shiny::req(input$period, input$metric)
      ply(plot_sport_mix(scoped_summaries(), period = input$period,
                          metric = input$metric,
                          from = dr_from(), to = dr_to(),
                          sport = "all"))  # already scoped
    })

    output$plot_ctl <- plotly::renderPlotly({
      shiny::req(input$ctl_sports)
      ply(plot_sport_ctl_overlay(scoped_summaries(),
                                  sports = input$ctl_sports,
                                  from = dr_from(), to = dr_to()))
    })

    output$plot_calendar <- shiny::renderPlot({
      plot_sport_calendar(scoped_summaries(),
                           from = dr_from(), to = dr_to(),
                           sport = "all")  # already scoped
    })
  })
}
