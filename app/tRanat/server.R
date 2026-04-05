library(shiny)
library(DT)
library(plotly)

shinyServer(function(input, output, session) {

  # --- Global date range ---
  dr_from <- reactive({
    if (input$use_daterange) input$global_daterange[1] else NULL
  })
  dr_to <- reactive({
    if (input$use_daterange) input$global_daterange[2] else NULL
  })

  # Filtered summaries for basic reports (month/year comparisons)
  summaries_f <- reactive({
    if (!input$use_daterange) return(summaries)
    dr <- build_date_range(
      after  = as.character(input$global_daterange[1]),
      before = as.character(input$global_daterange[2])
    )
    filter_by_daterange(summaries, dr)
  })

  # --- Helper: wrap ggplot in plotly ---
  ply <- function(p) plotly::ggplotly(p) %>% plotly::config(displayModeBar = TRUE)

  # ---------------------------------------------------------------- Löpande månad
  output$plot_monthstatus <- plotly::renderPlotly({
    ply(plot_monthstatus(summaries_f()))
  })
  output$table_monthstatus <- DT::renderDataTable({
    report_monthstatus(summaries_f())
  })

  # ----------------------------------------------------------------- Denna månad
  output$plot_month_this <- plotly::renderPlotly({
    ply(plot_runs_month(summaries_f()))
  })
  output$table_month_this <- DT::renderDataTable({
    report_runs_year_month(summaries_f())
  })

  # --------------------------------------------------------------- Förra månaden
  output$plot_monthlast <- plotly::renderPlotly({
    ply(plot_monthlast(summaries_f()))
  })
  output$table_monthlast <- DT::renderDataTable({
    report_monthlast(summaries_f())
  })

  # --------------------------------------------------------------- Toppmånader
  output$plot_monthtop <- plotly::renderPlotly({
    ply(plot_monthtop(summaries_f()))
  })
  output$table_monthtop <- DT::renderDataTable({
    report_monthtop(summaries_f())
  })

  # ----------------------------------------------------------------- Löpande år
  output$plot_yearstatus <- plotly::renderPlotly({
    ply(plot_yearstatus(summaries_f()))
  })
  output$table_yearstatus <- DT::renderDataTable({
    report_yearstatus(summaries_f())
  })

  # -------------------------------------------------------------------- Hela år
  output$plot_yearstop <- plotly::renderPlotly({
    ply(plot_yearstop(summaries_f()))
  })
  output$table_yearstop <- DT::renderDataTable({
    report_yearstop(summaries_f())
  })

  # ----------------------------------------------------------------------- Tempo
  output$plot_pace <- plotly::renderPlotly({
    ply(fetch.plot.mean.pace(fetch.my.mean.pace(summaries_f())))
  })
  output$table_pace <- DT::renderDataTable({
    fetch.my.mean.pace(summaries_f())
  })

  # ----------------------------------------------------------------- Datumperiod
  output$plot_datesum <- plotly::renderPlotly({
    req(input$datesum_range)
    ply(plot_datesum(summaries, input$datesum_range[1], input$datesum_range[2]))
  })
  output$table_datesum <- DT::renderDataTable({
    req(input$datesum_range)
    report_datesum(summaries, input$datesum_range[1], input$datesum_range[2])
  })

  # --- Avancerat: full data in, date range on output only ---

  # -------------------------------------------------------------------- EF
  output$plot_ef <- plotly::renderPlotly({
    ply(fetch.plot.ef(summaries, from = dr_from(), to = dr_to()))
  })
  output$table_ef <- DT::renderDataTable({
    report_ef(summaries, from = dr_from(), to = dr_to())
  })

  # -------------------------------------------------------------------- HRE
  output$plot_hre <- plotly::renderPlotly({
    ply(fetch.plot.hre(summaries, from = dr_from(), to = dr_to()))
  })
  output$table_hre <- DT::renderDataTable({
    report_hre(summaries, from = dr_from(), to = dr_to())
  })

  # ------------------------------------------------------------------- ACWR
  output$plot_acwr <- plotly::renderPlotly({
    ply(fetch.plot.acwr(summaries, from = dr_from(), to = dr_to()))
  })
  output$table_acwr <- DT::renderDataTable({
    report_acwr(summaries, from = dr_from(), to = dr_to())
  })

  # ----------------------------------------------------------------- Monotoni
  output$plot_monotony <- plotly::renderPlotly({
    ply(fetch.plot.monotony(summaries, from = dr_from(), to = dr_to()))
  })
  output$table_monotony <- DT::renderDataTable({
    report_monotony(summaries, from = dr_from(), to = dr_to())
  })

  # -------------------------------------------------------------------- PMC
  output$plot_pmc <- plotly::renderPlotly({
    ply(fetch.plot.pmc(summaries, from = dr_from(), to = dr_to()))
  })
  output$table_pmc <- DT::renderDataTable({
    report_pmc(summaries, from = dr_from(), to = dr_to())
  })

  # --------------------------------------------------------------- Recovery HR
  output$plot_recovery_hr <- plotly::renderPlotly({
    p <- tryCatch(
      fetch.plot.recovery_hr(summaries, from = dr_from(), to = dr_to()),
      error = function(e) {
        ggplot2::ggplot() +
          ggplot2::ggtitle(paste("Ej tillgänglig:", e$message))
      }
    )
    ply(p)
  })
  output$table_recovery_hr <- DT::renderDataTable({
    tryCatch(
      report_recovery_hr(summaries, from = dr_from(), to = dr_to()),
      error = function(e) {
        data.frame(fel = paste("Ej tillgänglig:", e$message))
      }
    )
  })

})
