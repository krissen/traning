# page_health.R — H\u00e4lsa & \u00c5terh\u00e4mtning: readiness, RHR, HRV, sleep, VO2max

page_health_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    # Readiness dashboard — full width, static (patchwork)
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("readiness"), "Beredskap",
        use_plotly = FALSE, plot_height = "800px")
    ),
    bslib::layout_columns(col_widths = 6, class = "section-spacer",
      metric_panel_ui(ns("resting_hr"), "Vilopuls"),
      metric_panel_ui(ns("hrv"),        "HRV")
    ),
    bslib::layout_columns(col_widths = 6, class = "section-spacer",
      metric_panel_ui(ns("sleep"),  "S\u00f6mn"),
      metric_panel_ui(ns("vo2max"), "VO2max")
    )
  )
}

page_health_server <- function(id, data, dates, is_mobile, data_version) {
  force(data)
  health_daily <- data@health_daily
  shiny::moduleServer(id, function(input, output, session) {
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)
    # fetch.plot.readiness_score/resting_hr/hrv/sleep/vo2max and
    # report_readiness are S7-migrated (PR 4): they take a single
    # traning_data bundle instead of separate summaries/health_daily
    # args. `data` is that bundle already.

    # Readiness — patchwork, must use renderPlot. bindCache(): calls
    # compute_readiness() (which calls compute_pmc()) internally —
    # genuinely expensive. Key is (from, to, data_version); no sport
    # dimension on this page. data_version guards against bindCache's
    # app-scoped (cross-session) default cache serving a stale plot to
    # a session that loaded newer data — see page_training.R for the
    # full rationale. resting_hr/hrv/sleep/vo2max below are cheap
    # filter/select reshapes of health_daily (no compute_*) and stay
    # uncached.
    metric_panel_server("readiness",
      plot_fn = shiny::reactive({
        shiny::req(health_daily)
        fetch.plot.readiness_score(data,
          from = dr_from(), to = dr_to())
      }) |> shiny::bindCache(dr_from(), dr_to(), data_version),
      report_fn = shiny::reactive({
        shiny::req(health_daily)
        report_readiness(data,
          from = dr_from(), to = dr_to())
      }) |> shiny::bindCache(dr_from(), dr_to(), data_version),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )

    # Resting HR
    metric_panel_server("resting_hr",
      plot_fn = shiny::reactive({
        shiny::req(health_daily)
        fetch.plot.resting_hr(data, from = dr_from(), to = dr_to())
      }),
      report_fn = shiny::reactive({
        shiny::req(health_daily)
        health_daily |>
          dplyr::filter(metric == "resting_heart_rate") |>
          dplyr::select(date, value, source) |>
          dplyr::arrange(dplyr::desc(date))
      }),
      is_mobile = is_mobile
    )

    # HRV
    metric_panel_server("hrv",
      plot_fn = shiny::reactive({
        shiny::req(health_daily)
        fetch.plot.hrv(data, from = dr_from(), to = dr_to())
      }),
      report_fn = shiny::reactive({
        shiny::req(health_daily)
        health_daily |>
          dplyr::filter(metric == "heart_rate_variability") |>
          dplyr::mutate(ln_rmssd = round(log(value), 2),
                        value = round(value, 1)) |>
          dplyr::select(date, RMSSD = value, Ln_RMSSD = ln_rmssd) |>
          dplyr::arrange(dplyr::desc(date))
      }),
      is_mobile = is_mobile
    )

    # Sleep
    metric_panel_server("sleep",
      plot_fn = shiny::reactive({
        shiny::req(health_daily)
        fetch.plot.sleep(data, from = dr_from(), to = dr_to())
      }),
      report_fn = shiny::reactive({
        shiny::req(health_daily)
        get_readiness(health_daily, after = dr_from(), before = dr_to()) |>
          dplyr::select(date, dplyr::any_of(c(
            "sleep_totalSleep", "sleep_deep", "sleep_rem",
            "sleep_core", "sleep_awake"
          ))) |>
          dplyr::mutate(dplyr::across(dplyr::where(is.numeric),
                                       \(x) round(x, 2))) |>
          dplyr::arrange(dplyr::desc(date))
      }),
      is_mobile = is_mobile
    )

    # VO2max
    metric_panel_server("vo2max",
      plot_fn = shiny::reactive({
        shiny::req(health_daily)
        fetch.plot.vo2max(data, from = dr_from(), to = dr_to())
      }),
      report_fn = shiny::reactive({
        shiny::req(health_daily)
        health_daily |>
          dplyr::filter(metric == "vo2_max") |>
          dplyr::mutate(value = round(value, 1)) |>
          dplyr::select(date, VO2max = value) |>
          dplyr::arrange(dplyr::desc(date))
      }),
      is_mobile = is_mobile
    )
  })
}
