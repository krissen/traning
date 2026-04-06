# mod_overview.R — Overview dashboard with KPI value boxes and mini charts

overview_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    # --- KPI value boxes ---
    bslib::layout_column_wrap(
      width = 1/5,
      heights_equal = "row",
      class = "section-spacer",
      shiny::uiOutput(ns("vb_readiness")),
      shiny::uiOutput(ns("vb_weekly_km")),
      shiny::uiOutput(ns("vb_ctl")),
      shiny::uiOutput(ns("vb_tsb")),
      shiny::uiOutput(ns("vb_acwr"))
    ),
    # --- Mini trend charts ---
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      bslib::card(
        full_screen = TRUE,
        bslib::card_header("Beredskap (14 dagar)"),
        bslib::card_body(
          fillable = FALSE,
          shiny::plotOutput(ns("mini_readiness"), height = "220px")
        )
      ),
      bslib::card(
        full_screen = TRUE,
        bslib::card_header("Veckovolym (12 veckor)"),
        bslib::card_body(
          fillable = FALSE,
          plotly::plotlyOutput(ns("mini_volume"), height = "220px")
        )
      )
    ),
    # --- Recent runs ---
    tags$div(class = "section-spacer",
      bslib::accordion(
        open = FALSE,
        bslib::accordion_panel("Senaste l\u00f6ppass",
          DT::dataTableOutput(ns("recent_runs"))
        )
      )
    )
  )
}

overview_server <- function(id, summaries, health_daily, myruns,
                            decoupling_data, dates, is_mobile) {
  force(summaries)
  force(health_daily)
  shiny::moduleServer(id, function(input, output, session) {

    # --- Shared computed data (cached per session) ---
    pmc_data <- shiny::reactive({
      tryCatch(compute_pmc(summaries), error = function(e) NULL)
    })

    acwr_data <- shiny::reactive({
      tryCatch(compute_acwr(summaries), error = function(e) NULL)
    })

    readiness_data <- shiny::reactive({
      tryCatch({
        shiny::req(health_daily)
        compute_readiness(health_daily, summaries)
      }, error = function(e) NULL)
    })

    # --- Value box: Readiness ---
    output$vb_readiness <- shiny::renderUI({
      rd <- readiness_data()
      if (is.null(rd)) {
        return(.vb_placeholder("Beredskap", "\u2014", "neutral"))
      }
      latest <- rd |> dplyr::filter(!is.na(readiness_score)) |>
        dplyr::slice_max(date, n = 1)
      if (nrow(latest) == 0) return(.vb_placeholder("Beredskap", "\u2014", "neutral"))

      score <- round(latest$readiness_score[1])
      rs <- latest$readiness_status[1]
      cls <- if (is.na(rs)) "neutral"
             else if (rs == "Gr\u00f6n") "green"
             else if (rs == "Gul") "yellow"
             else if (rs == "R\u00f6d") "red"
             else "neutral"

      .vb("Beredskap", score, cls,
        bsicons::bs_icon("heart-pulse-fill"))
    })

    # --- Value box: Weekly km ---
    output$vb_weekly_km <- shiny::renderUI({
      ad <- acwr_data()
      if (is.null(ad)) return(.vb_placeholder("Vecka km", "\u2014", "neutral"))
      latest <- ad |> dplyr::slice_max(date, n = 1)
      km <- round(latest$weekly_km[1], 1)
      .vb("Vecka km", paste0(km, " km"), "neutral",
        bsicons::bs_icon("speedometer2"))
    })

    # --- Value box: CTL (fitness) ---
    output$vb_ctl <- shiny::renderUI({
      pd <- pmc_data()
      if (is.null(pd)) return(.vb_placeholder("Fitness", "\u2014", "neutral"))
      latest <- pd |> dplyr::filter(!is.na(ctl)) |> dplyr::slice_max(date, n = 1)
      ctl <- round(latest$ctl[1])
      .vb("Fitness (CTL)", ctl, "neutral",
        bsicons::bs_icon("graph-up"))
    })

    # --- Value box: TSB (form) ---
    output$vb_tsb <- shiny::renderUI({
      pd <- pmc_data()
      if (is.null(pd)) return(.vb_placeholder("Form", "\u2014", "neutral"))
      latest <- pd |> dplyr::filter(!is.na(tsb)) |> dplyr::slice_max(date, n = 1)
      tsb <- round(latest$tsb[1])
      cls <- if (tsb > 5) "green" else if (tsb > -10) "yellow" else "red"
      label <- if (tsb > 5) "Utvilad" else if (tsb > -10) "Neutral" else "Tr\u00f6tt"
      .vb("Form (TSB)", paste0(tsb, " \u2014 ", label), cls,
        bsicons::bs_icon("battery-half"))
    })

    # --- Value box: ACWR ---
    output$vb_acwr <- shiny::renderUI({
      ad <- acwr_data()
      if (is.null(ad)) return(.vb_placeholder("ACWR", "\u2014", "neutral"))
      latest <- ad |> dplyr::filter(!is.na(acwr)) |> dplyr::slice_max(date, n = 1)
      ratio <- round(latest$acwr[1], 2)
      cls <- if (ratio >= 0.8 && ratio <= 1.3) "green" else if (ratio < 0.8) "yellow" else "red"
      .vb("ACWR", ratio, cls,
        bsicons::bs_icon("activity"))
    })

    # --- Mini readiness chart (14 days) ---
    output$mini_readiness <- shiny::renderPlot({
      rd <- readiness_data()
      shiny::req(rd)
      recent <- rd |>
        dplyr::filter(date >= Sys.Date() - 14, !is.na(readiness_score))
      shiny::req(nrow(recent) > 0)
      ggplot2::ggplot(recent, ggplot2::aes(date, readiness_score)) +
        ggplot2::geom_rect(ggplot2::aes(xmin = min(date), xmax = max(date),
          ymin = 70, ymax = 100), fill = "#e8f0e8", alpha = 0.5) +
        ggplot2::geom_rect(ggplot2::aes(xmin = min(date), xmax = max(date),
          ymin = 40, ymax = 70), fill = "#f5f0e0", alpha = 0.5) +
        ggplot2::geom_rect(ggplot2::aes(xmin = min(date), xmax = max(date),
          ymin = 0, ymax = 40), fill = "#f0e8e6", alpha = 0.5) +
        ggplot2::geom_line(linewidth = 1, color = "#3e2723") +
        ggplot2::geom_point(size = 2, color = "#3e2723") +
        ggplot2::scale_y_continuous(limits = c(0, 100)) +
        ggplot2::labs(x = NULL, y = NULL) +
        ggplot2::theme_minimal(base_size = 11) +
        ggplot2::theme(
          panel.grid.minor = ggplot2::element_blank(),
          plot.background = ggplot2::element_rect(fill = "#faf8f5", color = NA)
        )
    })

    # --- Mini volume chart (12 weeks) ---
    output$mini_volume <- plotly::renderPlotly({
      running <- summaries |>
        dplyr::filter(
          stringr::str_detect(sport, "running"),
          sessionStart >= Sys.Date() - 84
        ) |>
        dplyr::mutate(
          week = lubridate::floor_date(as.Date(sessionStart), "week",
            week_start = 1)
        ) |>
        dplyr::group_by(week) |>
        dplyr::summarise(km = sum(distance / 1000, na.rm = TRUE), .groups = "drop")

      p <- ggplot2::ggplot(running, ggplot2::aes(week, km)) +
        ggplot2::geom_col(fill = "#8d6e63", width = 5) +
        ggplot2::labs(x = NULL, y = "km") +
        ggplot2::theme_minimal(base_size = 11) +
        ggplot2::theme(
          panel.grid.minor = ggplot2::element_blank(),
          plot.background = ggplot2::element_rect(fill = "#faf8f5", color = NA)
        )
      pp <- plotly::ggplotly(p) |>
        plotly::config(displayModeBar = FALSE) |>
        plotly::layout(
          dragmode = FALSE,
          xaxis = list(fixedrange = TRUE),
          yaxis = list(fixedrange = TRUE)
        )
      pp
    })

    # --- Recent runs table ---
    output$recent_runs <- DT::renderDataTable({
      running <- summaries |>
        dplyr::filter(stringr::str_detect(sport, "running")) |>
        dplyr::arrange(dplyr::desc(sessionStart)) |>
        dplyr::slice_head(n = 10) |>
        dplyr::mutate(
          Datum = format(sessionStart, "%Y-%m-%d"),
          Km    = round(distance / 1000, 1),
          Tempo = sapply(avgPaceMoving, dec_to_mmss),
          HR    = round(avgHeartRateMoving),
          Tid   = sapply(as.numeric(durationMoving, units = "mins"), dec_to_mmss)
        ) |>
        dplyr::select(Datum, Km, Tempo, HR, Tid)
      DT::datatable(running,
        options = list(dom = "t", pageLength = 10, ordering = FALSE),
        rownames = FALSE
      )
    })
  })
}

# --- Value box helpers ---
.vb <- function(title, value, status = "neutral", icon = NULL) {
  cls <- paste0("value-box-", status)
  bslib::value_box(
    title = title,
    value = value,
    showcase = icon,
    class = cls,
    theme = bslib::value_box_theme(bg = "transparent", fg = "#2c2013")
  )
}

.vb_placeholder <- function(title, value = "\u2014", status = "neutral") {
  .vb(title, value, status, bsicons::bs_icon("dash-circle"))
}
