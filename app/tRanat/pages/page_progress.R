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
      # use_plotly = FALSE so ggrepel milestone labels survive (plotly
      # drops geom_label_repel).
      metric_panel_ui(ns("pace"), "Tempo", use_plotly = FALSE)
    ),
    tags$div(class = "section-spacer",
      bslib::card(
        bslib::card_header("Datumperiod"),
        bslib::card_body(
          tags$div(class = "btn-group btn-group-sm mb-2", role = "group",
            shiny::actionButton(ns("preset_1w"),  "1v",    class = "btn-outline-secondary"),
            shiny::actionButton(ns("preset_1m"),  "1 mån", class = "btn-outline-secondary"),
            shiny::actionButton(ns("preset_3m"),  "3 mån", class = "btn-outline-secondary"),
            shiny::actionButton(ns("preset_6m"),  "6 mån", class = "btn-outline-secondary"),
            shiny::actionButton(ns("preset_1y"),  "1 år",  class = "btn-outline-secondary"),
            shiny::actionButton(ns("preset_all"), "Allt",  class = "btn-outline-secondary")
          ),
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

page_progress_server <- function(id, summaries, dates, is_mobile, sport) {
  # `dates` is intentionally unused. The Utveckling page presents
  # historical comparisons that are meaningful only across the full
  # dataset (e.g. "April över åren" needs every April on record);
  # forwarding the global 12-month preset would silently collapse the
  # view to one or two recent years. The "Datumperiod" card at the
  # bottom carries its own dateRangeInput for ad-hoc lookups.
  force(summaries)
  shiny::moduleServer(id, function(input, output, session) {
    sp <- shiny::reactive(sport())

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

    # --- Month/Year panels — full history, ignore global date range ---
    metric_panel_server("monthstatus",
      plot_fn   = shiny::reactive(plot_monthstatus(summaries, sport = sp())),
      report_fn = shiny::reactive(report_monthstatus(summaries, sport = sp())),
      is_mobile = is_mobile
    )
    metric_panel_server("monthlast",
      plot_fn   = shiny::reactive(plot_monthlast(summaries, sport = sp())),
      report_fn = shiny::reactive(report_monthlast(summaries, sport = sp())),
      is_mobile = is_mobile
    )
    metric_panel_server("yearstatus",
      plot_fn   = shiny::reactive(fetch.plot.cumulative_km(summaries,
                                                            sport = sp())),
      report_fn = shiny::reactive(report_yearstatus(summaries, sport = sp())),
      is_mobile = is_mobile
    )
    metric_panel_server("yearstop",
      plot_fn   = shiny::reactive(plot_yearstop(summaries, sport = sp())),
      report_fn = shiny::reactive(report_yearstop(summaries, sport = sp())),
      is_mobile = is_mobile
    )
    metric_panel_server("month_this",
      plot_fn   = shiny::reactive(plot_runs_month(summaries, sport = sp())),
      report_fn = shiny::reactive(report_runs_year_month(summaries, sport = sp())),
      is_mobile = is_mobile
    )
    metric_panel_server("pace",
      plot_fn   = shiny::reactive(fetch.plot.pace_year(summaries,
                                                        sport = sp())),
      report_fn = shiny::reactive(report_yearstop(summaries, sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )

    # --- Datumperiod (own date range) ---
    # ignoreInit = TRUE so the initial actionButton value (0) doesn't
    # fire all six observers at startup and clobber the dateRangeInput's
    # default 180-day span.
    .set_range <- function(start, end) {
      shiny::updateDateRangeInput(session, "datesum_range",
                                  start = start, end = end)
    }
    shiny::observeEvent(input$preset_1w,
      .set_range(Sys.Date() - 7,   Sys.Date()), ignoreInit = TRUE)
    shiny::observeEvent(input$preset_1m,
      .set_range(Sys.Date() - 30,  Sys.Date()), ignoreInit = TRUE)
    shiny::observeEvent(input$preset_3m,
      .set_range(Sys.Date() - 90,  Sys.Date()), ignoreInit = TRUE)
    shiny::observeEvent(input$preset_6m,
      .set_range(Sys.Date() - 180, Sys.Date()), ignoreInit = TRUE)
    shiny::observeEvent(input$preset_1y,
      .set_range(Sys.Date() - 365, Sys.Date()), ignoreInit = TRUE)
    shiny::observeEvent(input$preset_all, {
      earliest <- suppressWarnings(min(summaries$sessionStart, na.rm = TRUE))
      if (is.finite(earliest)) {
        .set_range(as.Date(earliest), Sys.Date())
      } else {
        # Empty cache — fall back to the dateRangeInput default span.
        .set_range(Sys.Date() - 180, Sys.Date())
      }
    }, ignoreInit = TRUE)

    output$plot_datesum <- plotly::renderPlotly({
      shiny::req(input$datesum_range)
      ply(plot_datesum(summaries, input$datesum_range[1],
                       input$datesum_range[2], sport = sp()))
    })
    output$table_datesum <- DT::renderDataTable({
      shiny::req(input$datesum_range)
      report_datesum(summaries, input$datesum_range[1],
                     input$datesum_range[2], sport = sp())
    })
  })
}
