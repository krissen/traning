# mod_overview.R — Overview dashboard with KPI value boxes and mini charts

mod_overview_ui <- function(id) {
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
    bslib::layout_columns(col_widths = 6, class = "section-spacer",
      bslib::card(
        full_screen = TRUE,
        bslib::card_header("Beredskap"),
        bslib::card_body(
          fillable = FALSE,
          shiny::plotOutput(ns("mini_readiness"), height = "220px")
        )
      ),
      bslib::card(
        full_screen = TRUE,
        bslib::card_header("Veckovolym"),
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
    ),
    # --- Fun facts ---
    tags$div(class = "section-spacer",
      bslib::accordion(
        open = FALSE,
        bslib::accordion_panel("Trivia",
          shiny::uiOutput(ns("fun_facts"))
        )
      )
    )
  )
}

mod_overview_server <- function(id, data, dates, is_mobile, data_version) {
  force(data)
  # compute_pmc/compute_acwr/compute_readiness were NOT migrated to the
  # S7 traning_data(data, ...) contract — they still take positional
  # summaries/health_daily args, so unpack the bundle's slots once here.
  summaries    <- data@summaries
  health_daily <- data@health_daily
  shiny::moduleServer(id, function(input, output, session) {

    # `dates()` styr de två mini-graferna nedan. Värde-boxarna avviker
    # medvetet: de visar senaste tillgängliga snapshot (dvs. dagens
    # läge för beredskap/CTL/TSB/ACWR) oberoende av navbar-presetet.
    # Se docs/dev/filter-consistency.md.
    dr_from <- shiny::reactive(dates()$from)
    dr_to   <- shiny::reactive(dates()$to)

    # --- Shared computed data (cached per session) ---
    # bindCache() default `cache = "app"` is shared across ALL sessions
    # of this R process (not just this session) — so every key MUST
    # include `data_version`, a snapshot of the cache-file mtimes taken
    # in app.R just before load_session_data() populated `data` for
    # *this* session. Two sessions that loaded the same on-disk data
    # share `data_version` and safely share cache entries; a session
    # that starts after a mid-run import (new mtimes → new
    # data_version) gets a fresh key and never reads another session's
    # stale entry.
    #
    # All four metrics below come from ONE disk-cached
    # load_overview_metrics() call (R/advanced_metrics.R) instead of
    # four independent compute_*() calls — the overview page never
    # varies these by sport, so a single non-sport-keyed precache
    # covers it. `read_only = TRUE` means Shiny sessions never write
    # the cache (only `cli.R --import` / `--overview-cache` do), so
    # parallel sessions can't race on the file. bindCache() on
    # `overview_metrics` itself is kept as belt-and-suspenders — a
    # cache hit still costs a disk read + validity check, cheap but
    # not free.
    overview_metrics <- shiny::reactive({
      tryCatch(load_overview_metrics(summaries, health_daily,
                                     read_only = TRUE),
               error = function(e) NULL)
    }) |> shiny::bindCache(data_version)

    pmc_data <- shiny::reactive({
      m <- overview_metrics()
      if (is.null(m)) NULL else m$pmc
    })

    # Overview ACWR card uses whole-system load (sport="all" → TRIMP
    # mode) so it stays coherent with the PMC card above it; vardags-
    # gång räknas också. The dedicated PMC page can still render a
    # running-only ACWR via fetch.plot.acwr() / report_acwr() when the
    # user asks for sport=running.
    acwr_data <- shiny::reactive({
      m <- overview_metrics()
      if (is.null(m)) NULL else m$acwr_all
    })

    # "Vecka km" KPI explicitly tracks running km — km doesn't compose
    # across sports, so this card stays sport="running" / mode="km"
    # even when the ACWR card above goes whole-system.
    running_volume_data <- shiny::reactive({
      m <- overview_metrics()
      if (is.null(m)) NULL else m$volume_running
    })

    # The cached readiness was built from compute_readiness(health_daily,
    # summaries, pmc = pmc) using the SAME pmc as pmc_data() above (see
    # load_overview_metrics()), so this still skips a second TRIMP scan
    # — the reuse just happens once at cache-build time instead of once
    # per session.
    readiness_data <- shiny::reactive({
      m <- overview_metrics()
      if (is.null(m)) NULL else m$readiness
    })

    # --- Value box: Readiness ---
    output$vb_readiness <- shiny::renderUI({
      rd <- readiness_data()
      if (is.null(rd)) {
        return(.vb_placeholder("Beredskap", "\u2014", "neutral", kpi_type = "readiness"))
      }
      latest <- rd |> dplyr::filter(!is.na(readiness_score)) |>
        dplyr::slice_max(date, n = 1)
      if (nrow(latest) == 0) {
        return(.vb_placeholder("Beredskap", "\u2014", "neutral", kpi_type = "readiness"))
      }

      score <- round(latest$readiness_score[1])
      rs <- latest$readiness_status[1]
      cls <- if (is.na(rs)) "neutral"
             else if (rs == "Gr\u00f6n") "green"
             else if (rs == "Gul") "yellow"
             else if (rs == "R\u00f6d") "red"
             else "neutral"

      .vb("Beredskap", score, cls,
        bsicons::bs_icon("heart-pulse-fill"),
        kpi_type = "readiness")
    })

    # --- Value box: Weekly km ---
    output$vb_weekly_km <- shiny::renderUI({
      ad <- running_volume_data()
      if (is.null(ad)) return(.vb_placeholder("Vecka km", "\u2014", "neutral", kpi_type = "weekly_km"))
      latest <- ad |> dplyr::slice_max(date, n = 1)
      if (nrow(latest) == 0L) {
        return(.vb_placeholder("Vecka km", "\u2014", "neutral", kpi_type = "weekly_km"))
      }
      km <- round(latest$weekly_km[1], 1)
      .vb("Vecka km", paste0(km, " km"), "neutral",
        bsicons::bs_icon("speedometer2"),
        kpi_type = "weekly_km")
    })

    # --- Value box: CTL (fitness) ---
    output$vb_ctl <- shiny::renderUI({
      pd <- pmc_data()
      if (is.null(pd)) return(.vb_placeholder("Fitness", "\u2014", "neutral", kpi_type = "ctl"))
      latest <- pd |> dplyr::filter(!is.na(ctl)) |> dplyr::slice_max(date, n = 1)
      if (nrow(latest) == 0L) {
        return(.vb_placeholder("Fitness", "\u2014", "neutral", kpi_type = "ctl"))
      }
      ctl <- round(latest$ctl[1])
      .vb("Fitness (CTL)", ctl, "neutral",
        bsicons::bs_icon("graph-up"),
        kpi_type = "ctl")
    })

    # --- Value box: TSB (form) ---
    output$vb_tsb <- shiny::renderUI({
      pd <- pmc_data()
      if (is.null(pd)) return(.vb_placeholder("Form", "\u2014", "neutral", kpi_type = "tsb"))
      latest <- pd |> dplyr::filter(!is.na(tsb)) |> dplyr::slice_max(date, n = 1)
      if (nrow(latest) == 0L) {
        return(.vb_placeholder("Form", "\u2014", "neutral", kpi_type = "tsb"))
      }
      tsb <- round(latest$tsb[1])
      cls <- if (tsb > 5) "green" else if (tsb > -10) "yellow" else "red"
      label <- if (tsb > 5) "Utvilad" else if (tsb > -10) "Neutral" else "Tr\u00f6tt"
      .vb("Form (TSB)", paste0(tsb, " \u2014 ", label), cls,
        bsicons::bs_icon("battery-half"),
        kpi_type = "tsb")
    })

    # --- Value box: ACWR ---
    output$vb_acwr <- shiny::renderUI({
      ad <- acwr_data()
      if (is.null(ad)) return(.vb_placeholder("ACWR", "\u2014", "neutral", kpi_type = "acwr"))
      latest <- ad |> dplyr::filter(!is.na(acwr)) |> dplyr::slice_max(date, n = 1)
      # compute_acwr() can return zero qualifying rows when summaries
      # have distance data but no HR-qualifying workouts (e.g. a fresh
      # account with manual entries only, or the TRIMP-mode path with
      # all sessions filtered out). slice_max() returns nrow == 0
      # there, and the `ratio >= 0.8 && ratio <= 1.3` test then sees
      # numeric(0) and raises "missing value where TRUE/FALSE needed".
      if (nrow(latest) == 0L) {
        return(.vb_placeholder("ACWR", "\u2014", "neutral", kpi_type = "acwr"))
      }
      ratio <- round(latest$acwr[1], 2)
      cls <- if (ratio >= 0.8 && ratio <= 1.3) "green" else if (ratio < 0.8) "yellow" else "red"
      .vb("ACWR", ratio, cls,
        bsicons::bs_icon("activity"),
        kpi_type = "acwr")
    })

    # --- Mini readiness chart (följer globalt datumspann) ---
    output$mini_readiness <- shiny::renderPlot({
      rd <- readiness_data()
      shiny::req(rd)
      recent <- traning:::.filter_readiness_range(rd, dr_from(), dr_to()) |>
        dplyr::filter(!is.na(readiness_score))
      shiny::req(nrow(recent) > 0)
      pal <- traning::traning_palette
      ggplot2::ggplot(recent, ggplot2::aes(date, readiness_score)) +
        ggplot2::geom_rect(ggplot2::aes(xmin = min(date), xmax = max(date),
          ymin = 70, ymax = 100),
          fill = pal$readiness_bg[["high"]], alpha = 0.5) +
        ggplot2::geom_rect(ggplot2::aes(xmin = min(date), xmax = max(date),
          ymin = 40, ymax = 70),
          fill = pal$readiness_bg[["medium"]], alpha = 0.5) +
        ggplot2::geom_rect(ggplot2::aes(xmin = min(date), xmax = max(date),
          ymin = 0, ymax = 40),
          fill = pal$readiness_bg[["low"]], alpha = 0.5) +
        ggplot2::geom_line(linewidth = 1, color = pal$primary) +
        ggplot2::geom_point(size = 2, color = pal$primary) +
        ggplot2::scale_y_continuous(limits = c(0, 100)) +
        ggplot2::labs(x = NULL, y = NULL) +
        ggplot2::theme_minimal(base_size = 11) +
        ggplot2::theme(
          panel.grid.minor = ggplot2::element_blank(),
          plot.background = ggplot2::element_rect(fill = pal$bg_card, color = NA)
        )
    })

    # --- Mini volume chart (följer globalt datumspann) ---
    output$mini_volume <- plotly::renderPlotly({
      running <- summaries |>
        dplyr::filter(stringr::str_detect(sport, "running"))
      running <- traning:::.filter_running_range(running, dr_from(), dr_to())
      shiny::req(nrow(running) > 0)
      running <- running |>
        dplyr::mutate(
          week = lubridate::floor_date(as.Date(sessionStart), "week",
            week_start = 1)
        ) |>
        dplyr::group_by(week) |>
        dplyr::summarise(km = sum(distance / 1000, na.rm = TRUE), .groups = "drop")

      pal <- traning::traning_palette
      p <- ggplot2::ggplot(running, ggplot2::aes(week, km)) +
        ggplot2::geom_col(fill = pal$accent, width = 5) +
        ggplot2::labs(x = NULL, y = "km") +
        ggplot2::theme_minimal(base_size = 11) +
        ggplot2::theme(
          panel.grid.minor = ggplot2::element_blank(),
          plot.background = ggplot2::element_rect(fill = pal$bg_card, color = NA)
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

    # --- Fun facts ---
    output$fun_facts <- shiny::renderUI({
      facts <- compute_fun_facts(summaries)
      .format_fun_facts_html(facts)
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
# kpi_type (optional) g\u00f6r korten klickbara \u2014 onclick s\u00e4tter
# input$kpi_click i app-server, som navigerar + scrollar till detaljvyn.
.vb <- function(title, value, status = "neutral", icon = NULL,
                kpi_type = NULL) {
  cls <- paste0("value-box-", status)
  box <- bslib::value_box(
    title = title,
    value = value,
    showcase = icon,
    class = cls,
    theme = bslib::value_box_theme(bg = "transparent",
                                    fg = traning::traning_palette$text_dark)
  )
  if (!is.null(kpi_type)) {
    onclick <- sprintf(
      "Shiny.setInputValue('kpi_click', {type:'%s', nonce:Math.random()}, {priority:'event'})",
      kpi_type
    )
    box <- htmltools::tagAppendAttributes(
      box,
      class = "value-box-clickable",
      onclick = onclick,
      tabindex = "0",
      role = "button",
      `aria-label` = sprintf("\u00d6ppna detaljvy f\u00f6r %s", title),
      onkeydown = sprintf(
        "if(event.key==='Enter'||event.key===' '){event.preventDefault();%s}",
        onclick
      )
    )
  }
  box
}

.vb_placeholder <- function(title, value = "\u2014", status = "neutral",
                            kpi_type = NULL) {
  .vb(title, value, status, bsicons::bs_icon("dash-circle"),
      kpi_type = kpi_type)
}
