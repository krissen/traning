# mod_metric_panel.R — Generic plot + table card module

metric_panel_ui <- function(id, title = NULL, use_plotly = TRUE,
                            plot_height = "500px", full_screen = TRUE) {
  ns <- shiny::NS(id)

  plot_output <- if (use_plotly) {
    plotly::plotlyOutput(ns("plot"), height = plot_height, width = "100%")
  } else {
    shiny::plotOutput(ns("plot"), height = plot_height, width = "100%")
  }

  bslib::card(
    full_screen = full_screen,
    if (!is.null(title)) bslib::card_header(title),
    bslib::card_body(
      fillable = FALSE,
      plot_output
    ),
    bslib::accordion(
      id = ns("acc"),
      open = FALSE,
      bslib::accordion_panel("Data",
        DT::dataTableOutput(ns("table"))
      )
    )
  )
}

metric_panel_server <- function(id, plot_fn, report_fn = NULL,
                                use_plotly = TRUE, is_mobile = shiny::reactive(FALSE)) {
  force(plot_fn); force(report_fn); force(use_plotly)
  shiny::moduleServer(id, function(input, output, session) {
    ply <- function(p, mobile = FALSE) {
      pp <- plotly::ggplotly(p) |>
        plotly::config(
          displayModeBar = !mobile,
          modeBarButtonsToRemove = c("lasso2d", "select2d", "autoScale2d")
        ) |>
        plotly::layout(
          title = list(x = 0.01, xanchor = "left", y = 0.99,
                       font = list(size = 13)),
          margin = list(t = 40, b = 60, l = 50, r = 30),
          legend = list(orientation = "h", x = 0, y = -0.12,
                        xanchor = "left", font = list(size = 10))
        )
      if (mobile) {
        pp <- pp |> plotly::layout(
          dragmode = FALSE,
          xaxis = list(fixedrange = TRUE),
          yaxis = list(fixedrange = TRUE)
        )
      }
      pp
    }

    if (use_plotly) {
      output$plot <- plotly::renderPlotly({
        p <- tryCatch(plot_fn(), error = function(e) {
          ggplot2::ggplot() +
            ggplot2::annotate("text", x = 0.5, y = 0.5,
              label = paste("Ej tillg\u00e4nglig:", e$message),
              size = 4, color = "#6d5d4f") +
            ggplot2::theme_void()
        })
        ply(p, mobile = is_mobile())
      })
    } else {
      output$plot <- shiny::renderPlot({
        tryCatch(plot_fn(), error = function(e) {
          ggplot2::ggplot() +
            ggplot2::annotate("text", x = 0.5, y = 0.5,
              label = paste("Ej tillg\u00e4nglig:", e$message),
              size = 4, color = "#6d5d4f") +
            ggplot2::theme_void()
        })
      })
    }

    if (!is.null(report_fn)) {
      output$table <- DT::renderDataTable({
        tryCatch({
          data <- report_fn()
          DT::datatable(data,
            extensions = "Responsive",
            options = list(
              responsive = TRUE,
              pageLength = 15,
              dom = "tip",
              language = list(
                info = "Visar _START_\u2013_END_ av _TOTAL_",
                paginate = list(previous = "\u2190", `next` = "\u2192")
              )
            ),
            rownames = FALSE
          )
        }, error = function(e) {
          DT::datatable(
            data.frame(fel = paste("Ej tillg\u00e4nglig:", e$message)),
            options = list(dom = "t"),
            rownames = FALSE
          )
        })
      })
    }
  })
}
