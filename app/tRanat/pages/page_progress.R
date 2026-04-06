# page_progress.R — Utveckling: month/year comparisons, pace trends

page_progress_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("monthstatus"), "L\u00f6pande m\u00e5nad"),
      metric_panel_ui(ns("monthlast"),   "F\u00f6rra m\u00e5naden")
    ),
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("yearstatus"), "L\u00f6pande \u00e5r"),
      metric_panel_ui(ns("yearstop"),   "Hela \u00e5r")
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("month_this"), "Denna m\u00e5nad")
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("monthtop"), "Toppm\u00e5nader")
    ),
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("pace"), "Tempo")
    ),
    tags$div(class = "section-spacer",
      bslib::card(
        bslib::card_header("Datumperiod"),
        bslib::card_body(
          bslib::layout_columns(
            col_widths = bslib::breakpoints(sm = 12, md = 4),
            shiny::dateRangeInput(ns("datesum_range"), NULL,
              start = Sys.Date() - 180,
              end   = Sys.Date(),
              width = "100%"
            )
          )
        ),
        bslib::card_body(
          fillable = FALSE,
          plotly::plotlyOutput(ns("plot_datesum"), height = "500px")
        ),
        bslib::accordion(
          open = FALSE,
          bslib::accordion_panel("Data",
            DT::dataTableOutput(ns("table_datesum"))
          )
        )
      )
    )
  )
}

page_progress_server <- function(id, summaries, dates, is_mobile) {
  force(summaries)
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)

    # Filtered summaries for pace tab
    summaries_f <- shiny::reactive({
      from <- dr_from()
      if (is.null(from)) return(summaries)
      dr <- build_date_range(after = as.character(from),
                             before = as.character(dr_to()))
      filter_by_daterange(summaries, dr)
    })

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

    # --- Month/Year panels ---
    metric_panel_server("monthstatus",
      plot_fn   = shiny::reactive(plot_monthstatus(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_monthstatus(summaries, from = dr_from(), to = dr_to())),
      is_mobile = is_mobile
    )
    metric_panel_server("monthlast",
      plot_fn   = shiny::reactive(plot_monthlast(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_monthlast(summaries, from = dr_from(), to = dr_to())),
      is_mobile = is_mobile
    )
    metric_panel_server("yearstatus",
      plot_fn   = shiny::reactive(plot_yearstatus(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_yearstatus(summaries, from = dr_from(), to = dr_to())),
      is_mobile = is_mobile
    )
    metric_panel_server("yearstop",
      plot_fn   = shiny::reactive(plot_yearstop(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_yearstop(summaries, from = dr_from(), to = dr_to())),
      is_mobile = is_mobile
    )
    metric_panel_server("month_this",
      plot_fn   = shiny::reactive(plot_runs_month(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_runs_year_month(summaries, from = dr_from(), to = dr_to())),
      is_mobile = is_mobile
    )
    metric_panel_server("monthtop",
      plot_fn   = shiny::reactive(plot_monthtop(summaries, from = dr_from(), to = dr_to())),
      report_fn = shiny::reactive(report_monthtop(summaries, from = dr_from(), to = dr_to())),
      is_mobile = is_mobile
    )
    metric_panel_server("pace",
      plot_fn   = shiny::reactive(fetch.plot.mean.pace(fetch.my.mean.pace(summaries_f()))),
      report_fn = shiny::reactive(fetch.my.mean.pace(summaries_f())),
      is_mobile = is_mobile
    )

    # --- Datumperiod (own date range) ---
    output$plot_datesum <- plotly::renderPlotly({
      shiny::req(input$datesum_range)
      ply(plot_datesum(summaries, input$datesum_range[1], input$datesum_range[2]))
    })
    output$table_datesum <- DT::renderDataTable({
      shiny::req(input$datesum_range)
      report_datesum(summaries, input$datesum_range[1], input$datesum_range[2])
    })
  })
}
