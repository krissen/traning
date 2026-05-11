# page_race.R — Tävling: taper-plan and race-readiness.
#
# Phase 5d. Replaces the original placeholder. Both cards consume
# the new R helpers in R/advanced_metrics.R, so the UI stays a thin
# layer of inputs + rendering.

page_race_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Tävlingsdatum"),
      bslib::card_body(
        bslib::layout_columns(
          col_widths = bslib::breakpoints(sm = 12, md = c(4, 4, 4)),
          shiny::dateInput(ns("race_date"), "Tävlingsdag",
                            value = Sys.Date() + 42L,
                            min   = Sys.Date(),
                            language = "sv",
                            weekstart = 1L,
                            width = "100%"),
          shiny::numericInput(ns("distance_km"), "Distans (km)",
                               value = 21.1, min = 1, max = 200,
                               step = 0.1, width = "100%"),
          shiny::sliderInput(ns("taper_weeks"), "Taper-veckor",
                              min = 1L, max = 4L, value = 2L, step = 1L,
                              width = "100%")
        )
      )
    ),
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Veckoplan"),
      bslib::card_body(
        DT::dataTableOutput(ns("plan_table"))
      ),
      bslib::card_body(
        shiny::verbatimTextOutput(ns("plan_prose"))
      )
    ),
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Tävlingsberedskap"),
      bslib::card_body(
        shiny::uiOutput(ns("readiness_header")),
        shiny::verbatimTextOutput(ns("readiness_prose"))
      )
    )
  )
}


page_race_server <- function(id, summaries, health_daily, dates,
                              is_mobile) {
  force(summaries)
  force(health_daily)
  shiny::moduleServer(id, function(input, output, session) {
    taper_plan <- shiny::reactive({
      shiny::req(input$race_date, input$taper_weeks)
      tryCatch(
        compute_taper_plan(summaries,
                            race_date = input$race_date,
                            distance_km = input$distance_km,
                            taper_weeks = as.integer(input$taper_weeks)),
        error = function(e) {
          tibble::tibble(error = conditionMessage(e))
        }
      )
    })

    readiness <- shiny::reactive({
      shiny::req(input$race_date, input$taper_weeks)
      tryCatch(
        compute_race_readiness(summaries, health_daily,
                                target_date = input$race_date,
                                taper_weeks = as.integer(input$taper_weeks)),
        error = function(e) {
          list(status = "Fel", score = NA_real_,
               prose = conditionMessage(e))
        }
      )
    })

    output$plan_table <- DT::renderDataTable({
      plan <- taper_plan()
      if ("error" %in% names(plan)) {
        return(DT::datatable(plan, rownames = FALSE,
                              options = list(dom = "t",
                                              paging = FALSE,
                                              searching = FALSE)))
      }
      display <- data.frame(
        Vecka           = format(plan$week_start, "%a %d %b"),
        Fas             = c(build = "Bygg", taper = "Taper",
                             race  = "Tävling")[plan$phase],
        `Mål (km)`      = plan$target_km,
        `% av baseline` = round(plan$relative_to_baseline * 100),
        check.names = FALSE
      )
      DT::datatable(display, rownames = FALSE,
                     options = list(dom = "t", paging = FALSE,
                                     searching = FALSE,
                                     ordering = FALSE))
    })

    output$plan_prose <- shiny::renderText({
      plan <- taper_plan()
      if ("error" %in% names(plan)) return(plan$error[[1]])
      render_taper_plan_prose(plan)
    })

    output$readiness_header <- shiny::renderUI({
      r <- readiness()
      if (is.null(r) || is.null(r$status)) return(NULL)
      color <- switch(r$status,
        "Klar"      = "bg-success text-white",
        "Tveksam"   = "bg-warning",
        "Inte klar" = "bg-danger text-white",
        "bg-secondary text-white"
      )
      score_txt <- if (is.na(r$score)) "—" else sprintf("%d/100", round(r$score))
      shiny::div(
        class = paste("p-2 rounded mb-2", color),
        shiny::strong(r$status), " · ", score_txt
      )
    })

    output$readiness_prose <- shiny::renderText({
      r <- readiness()
      if (is.null(r) || is.null(r$prose)) return("Inget att visa.")
      r$prose
    })
  })
}
