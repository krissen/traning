library(shiny)
library(DT)
library(plotly)

shinyServer(function(input, output, session) {

  # --- Global date range from preset selector ---
  preset_dates <- reactive({
    today <- Sys.Date()
    switch(input$date_preset,
      "all"    = list(from = NULL, to = NULL),
      "7d"     = list(from = today - 7,               to = today),
      "4w"     = list(from = today - 28,              to = today),
      "3m"     = list(from = today - 90,              to = today),
      "6m"     = list(from = today - 182,             to = today),
      "ytd"    = list(from = as.Date(paste0(format(today, "%Y"), "-01-01")),
                      to = today),
      "12m"    = list(from = today - 365,             to = today),
      "2y"     = list(from = today - 730,             to = today),
      "5y"     = list(from = today - 1826,            to = today),
      "custom" = list(from = input$global_daterange[1],
                      to   = input$global_daterange[2])
    )
  })

  dr_from <- reactive(preset_dates()$from)
  dr_to   <- reactive(preset_dates()$to)

  # Filtered summaries for basic reports (month/year comparisons)
  summaries_f <- reactive({
    from <- dr_from()
    if (is.null(from)) return(summaries)
    dr <- build_date_range(
      after  = as.character(from),
      before = as.character(dr_to())
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

  # --- Hälsa: Apple Watch data ---

  output$plot_resting_hr <- plotly::renderPlotly({
    req(health_daily)
    ply(fetch.plot.resting_hr(health_daily, from = dr_from(), to = dr_to()))
  })
  output$table_resting_hr <- DT::renderDataTable({
    req(health_daily)
    health_daily |>
      dplyr::filter(metric == "resting_heart_rate") |>
      dplyr::select(date, value, source) |>
      dplyr::arrange(dplyr::desc(date))
  })

  output$plot_hrv <- plotly::renderPlotly({
    req(health_daily)
    ply(fetch.plot.hrv(health_daily, from = dr_from(), to = dr_to()))
  })
  output$table_hrv <- DT::renderDataTable({
    req(health_daily)
    health_daily |>
      dplyr::filter(metric == "heart_rate_variability") |>
      dplyr::mutate(ln_rmssd = round(log(value), 2),
                    value = round(value, 1)) |>
      dplyr::select(date, RMSSD = value, Ln_RMSSD = ln_rmssd) |>
      dplyr::arrange(dplyr::desc(date))
  })

  output$plot_sleep <- plotly::renderPlotly({
    req(health_daily)
    ply(fetch.plot.sleep(health_daily, from = dr_from(), to = dr_to()))
  })
  output$table_sleep <- DT::renderDataTable({
    req(health_daily)
    get_readiness(health_daily, after = dr_from(), before = dr_to()) |>
      dplyr::select(date, dplyr::any_of(c(
        "sleep_totalSleep", "sleep_deep", "sleep_rem",
        "sleep_core", "sleep_awake"
      ))) |>
      dplyr::mutate(dplyr::across(dplyr::where(is.numeric),
                                   \(x) round(x, 2))) |>
      dplyr::arrange(dplyr::desc(date))
  })

  output$plot_vo2max <- plotly::renderPlotly({
    req(health_daily)
    ply(fetch.plot.vo2max(health_daily, from = dr_from(), to = dr_to()))
  })
  output$table_vo2max <- DT::renderDataTable({
    req(health_daily)
    health_daily |>
      dplyr::filter(metric == "vo2_max") |>
      dplyr::mutate(value = round(value, 1)) |>
      dplyr::select(date, VO2max = value) |>
      dplyr::arrange(dplyr::desc(date))
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
