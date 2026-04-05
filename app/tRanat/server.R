library(shiny)
library(DT)

shinyServer(function(input, output, session) {

  # ---------------------------------------------------------------- Löpande månad
  output$plot_monthstatus <- renderPlot({
    plot_monthstatus(summaries)
  })
  output$table_monthstatus <- DT::renderDataTable({
    report_monthstatus(summaries)
  })

  # ----------------------------------------------------------------- Denna månad
  output$plot_month_this <- renderPlot({
    plot_runs_month(summaries)
  })
  output$table_month_this <- DT::renderDataTable({
    report_runs_year_month(summaries)
  })

  # --------------------------------------------------------------- Förra månaden
  output$plot_monthlast <- renderPlot({
    plot_monthlast(summaries)
  })
  output$table_monthlast <- DT::renderDataTable({
    report_monthlast(summaries)
  })

  # --------------------------------------------------------------- Toppmånader
  output$plot_monthtop <- renderPlot({
    plot_monthtop(summaries)
  })
  output$table_monthtop <- DT::renderDataTable({
    report_monthtop(summaries)
  })

  # ----------------------------------------------------------------- Löpande år
  output$plot_yearstatus <- renderPlot({
    plot_yearstatus(summaries)
  })
  output$table_yearstatus <- DT::renderDataTable({
    report_yearstatus(summaries)
  })

  # -------------------------------------------------------------------- Hela år
  output$plot_yearstop <- renderPlot({
    plot_yearstop(summaries)
  })
  output$table_yearstop <- DT::renderDataTable({
    report_yearstop(summaries)
  })

  # ----------------------------------------------------------------------- Tempo
  output$plot_pace <- renderPlot({
    fetch.plot.mean.pace(fetch.my.mean.pace(summaries))
  })
  output$table_pace <- DT::renderDataTable({
    fetch.my.mean.pace(summaries)
  })

  # ----------------------------------------------------------------- Datumperiod
  output$plot_datesum <- renderPlot({
    req(input$datesum_range)
    plot_datesum(summaries, input$datesum_range[1], input$datesum_range[2])
  })
  output$table_datesum <- DT::renderDataTable({
    req(input$datesum_range)
    report_datesum(summaries, input$datesum_range[1], input$datesum_range[2])
  })

  # -------------------------------------------------------------------- EF
  output$plot_ef <- renderPlot({
    fetch.plot.ef(summaries)
  })
  output$table_ef <- DT::renderDataTable({
    report_ef(summaries)
  })

  # -------------------------------------------------------------------- HRE
  output$plot_hre <- renderPlot({
    fetch.plot.hre(summaries)
  })
  output$table_hre <- DT::renderDataTable({
    report_hre(summaries)
  })

  # ------------------------------------------------------------------- ACWR
  output$plot_acwr <- renderPlot({
    fetch.plot.acwr(summaries)
  })
  output$table_acwr <- DT::renderDataTable({
    report_acwr(summaries)
  })

  # ----------------------------------------------------------------- Monotoni
  output$plot_monotony <- renderPlot({
    fetch.plot.monotony(summaries)
  })
  output$table_monotony <- DT::renderDataTable({
    report_monotony(summaries)
  })

  # -------------------------------------------------------------------- PMC
  output$plot_pmc <- renderPlot({
    fetch.plot.pmc(summaries)
  })
  output$table_pmc <- DT::renderDataTable({
    report_pmc(summaries)
  })

  # --------------------------------------------------------------- Recovery HR
  output$plot_recovery_hr <- renderPlot({
    tryCatch(
      fetch.plot.recovery_hr(summaries),
      error = function(e) {
        ggplot2::ggplot() +
          ggplot2::ggtitle(paste("Ej tillgänglig:", e$message))
      }
    )
  })
  output$table_recovery_hr <- DT::renderDataTable({
    tryCatch(
      report_recovery_hr(summaries),
      error = function(e) {
        data.frame(fel = paste("Ej tillgänglig:", e$message))
      }
    )
  })

})
