# page_import.R — upload a health-export archive and backfill it.
#
# Wraps the Python `traning backfill` CLI with a two-step Shiny flow:
#  1. User selects a zip; we run `--dry-run` and show a preview of
#     metrics + dates that would be added.
#  2. User confirms; we run the real backfill and show the result.
#
# The page deliberately avoids reticulate — see R/python_cli.R for
# the lightweight system2() bridge.

page_import_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::card(
      class = "section-spacer",
      bslib::card_header("Backfill från export-arkiv"),
      bslib::card_body(
        shiny::tagList(
          shiny::p(
            "Ladda upp ett zip-arkiv (t.ex. Withings-export). ",
            "Sidan visar en förhandsgranskning av vilka mått ",
            "och datum som skulle skrivas, innan något hamnar ",
            "i datalagret."
          ),
          shiny::fileInput(
            ns("zip"), "Välj zip-arkiv",
            accept  = c(".zip", "application/zip",
                        "application/x-zip-compressed"),
            buttonLabel = "Bläddra",
            placeholder = "Ingen fil vald"
          ),
          shiny::uiOutput(ns("preview")),
          shiny::uiOutput(ns("confirm_btn")),
          shiny::uiOutput(ns("result"))
        )
      )
    )
  )
}


page_import_server <- function(id) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # Two reactive values: the dry-run result, and the committed
    # result. Separate so the preview survives the user clicking
    # "Confirm" until the real run finishes.
    preview_rv <- shiny::reactiveVal(NULL)
    result_rv  <- shiny::reactiveVal(NULL)

    # Wipe previous state when a new file lands.
    shiny::observeEvent(input$zip, {
      result_rv(NULL)
      shiny::req(input$zip)
      shiny::withProgress(message = "Förhandsgranskar …", value = 0.3, {
        out <- traning_backfill(input$zip$datapath, dry_run = TRUE)
        preview_rv(out)
      })
    }, ignoreInit = TRUE)

    output$preview <- shiny::renderUI({
      out <- preview_rv()
      if (is.null(out)) return(NULL)
      if (!out$success) {
        return(bslib::card(
          class = "section-spacer",
          bslib::card_header(
            class = "bg-danger text-white",
            "Förhandsgranskning misslyckades"
          ),
          bslib::card_body(
            shiny::pre(paste(c(out$stderr, out$stdout), collapse = "\n"))
          )
        ))
      }
      counts <- out$counts
      total  <- sum(counts)
      if (total == 0L) {
        return(bslib::card(
          class = "section-spacer",
          bslib::card_header("Förhandsgranskning"),
          bslib::card_body(
            shiny::p("Inga nya datum att backfilla — alla värden ",
                     "i arkivet finns redan i datalagret.")
          )
        ))
      }
      rows <- lapply(names(counts), function(m) {
        shiny::tags$tr(
          shiny::tags$td(m),
          shiny::tags$td(format(counts[[m]], big.mark = " "))
        )
      })
      bslib::card(
        class = "section-spacer",
        bslib::card_header(
          paste0("Förhandsgranskning (", total, " nya filer)")
        ),
        bslib::card_body(
          shiny::tags$table(
            class = "table table-sm",
            shiny::tags$thead(
              shiny::tags$tr(
                shiny::tags$th("Mått"),
                shiny::tags$th("Nya filer")
              )
            ),
            shiny::tags$tbody(rows)
          )
        )
      )
    })

    output$confirm_btn <- shiny::renderUI({
      out <- preview_rv()
      committed <- result_rv()
      if (is.null(out) || !out$success || sum(out$counts) == 0L) return(NULL)
      if (!is.null(committed)) return(NULL)
      shiny::actionButton(
        ns("confirm"), "Skriv canonical-filer",
        class = "btn-primary"
      )
    })

    shiny::observeEvent(input$confirm, {
      shiny::req(input$zip)
      shiny::withProgress(message = "Skriver canonical-filer …",
                           value = 0.5, {
        out <- traning_backfill(input$zip$datapath, dry_run = FALSE)
        result_rv(out)
      })
    })

    output$result <- shiny::renderUI({
      out <- result_rv()
      if (is.null(out)) return(NULL)
      if (!out$success) {
        return(bslib::card(
          class = "section-spacer",
          bslib::card_header(
            class = "bg-danger text-white",
            "Backfill misslyckades"
          ),
          bslib::card_body(
            shiny::pre(paste(c(out$stderr, out$stdout), collapse = "\n"))
          )
        ))
      }
      total <- sum(out$counts)
      bslib::card(
        class = "section-spacer",
        bslib::card_header(
          class = "bg-success text-white",
          paste0("Klart — ", total, " nya filer skrivna")
        ),
        bslib::card_body(
          shiny::p("Kör ", shiny::code("traning import health --force"),
                   " för att importera dem i R-cachen.")
        )
      )
    })
  })
}
