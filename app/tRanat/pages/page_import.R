# page_import.R — upload a health-export archive and backfill it.
#
# Wraps the Python `traning backfill` CLI with a two-step Shiny flow:
#  1. User selects a zip; we run `--dry-run` and show a per-metric
#     preview of how many new canonical files would be written.
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
            "Sidan visar en förhandsgranskning per mått av hur ",
            "många nya canonical-filer som skulle skrivas, innan ",
            "något hamnar i datalagret."
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

    # Three reactive values: dry-run preview, the in-flight flag for
    # the commit step (prevents a second Confirm click while we're
    # still writing files), and the committed result.
    preview_rv    <- shiny::reactiveVal(NULL)
    committing_rv <- shiny::reactiveVal(FALSE)
    result_rv     <- shiny::reactiveVal(NULL)

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
      # Distinguish "CLI ran clean and explicitly reported no new
      # dates" from "CLI ran clean but our parser couldn't pull any
      # metric: N lines out of the stdout". The no_new_dates flag
      # comes from spotting the CLI's literal "Inga nya datum att
      # backfilla."-line; without it the parser regression and a
      # quiet archive look identical.
      if (isFALSE(out$parse_ok)) {
        return(bslib::card(
          class = "section-spacer",
          bslib::card_header(
            class = "bg-warning",
            "Förhandsgranskning — kunde inte tolka räknarna"
          ),
          bslib::card_body(
            shiny::p("CLI:n gick igenom utan fel men varken ",
                     "per-mått-rader eller no-op-signalen kände ",
                     "vi igen. Rå-utskrift:"),
            shiny::pre(paste(out$stdout, collapse = "\n"))
          )
        ))
      }
      total <- sum(counts)
      if (isTRUE(out$no_new_dates) || total == 0L) {
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
        class = "btn-primary",
        # Disable the button as soon as a commit is in flight so a
        # second click can't queue another backfill run while the
        # first one is still writing files.
        disabled = isTRUE(committing_rv())
      )
    })

    shiny::observeEvent(input$confirm, {
      shiny::req(input$zip)
      # Guard against the observer re-firing before the disabled
      # attribute reaches the client (the renderUI round-trip lags
      # the first click).
      if (isTRUE(committing_rv())) return(NULL)
      committing_rv(TRUE)
      on.exit(committing_rv(FALSE), add = TRUE)
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
      counts <- out$counts
      # Mirror the preview branch's parse_ok check — only flag a
      # parser failure when the CLI didn't also signal the explicit
      # no-op shape.
      if (isFALSE(out$parse_ok)) {
        return(bslib::card(
          class = "section-spacer",
          bslib::card_header(
            class = "bg-warning",
            "Backfill klart — kunde inte tolka räknarna"
          ),
          bslib::card_body(
            shiny::p("CLI:n rapporterade lyckat men varken ",
                     "per-mått-rader eller no-op-signalen kände ",
                     "vi igen. Rå-utskrift:"),
            shiny::pre(paste(out$stdout, collapse = "\n")),
            shiny::p("Kör ", shiny::code("traning import health --force"),
                     " för att hämta in eventuellt nyskrivna filer.")
          )
        ))
      }
      total <- sum(counts)
      if (isTRUE(out$no_new_dates) && total == 0L) {
        return(bslib::card(
          class = "section-spacer",
          bslib::card_header("Backfill klart"),
          bslib::card_body(
            shiny::p("Inga nya datum att skriva — datalagret var ",
                     "redan komplett.")
          )
        ))
      }
      bslib::card(
        class = "section-spacer",
        bslib::card_header(
          class = "bg-success text-white",
          paste0("Klart — ", total, " nya filer skrivna")
        ),
        bslib::card_body(
          shiny::p("Kör ",
                   shiny::code("traning import health --force"),
                   " för att läsa in dem i R-cachen — receiverns ",
                   "automatiska health-flush importerar bara filer ",
                   "som pushas via HAE. Dashboarden uppdateras ",
                   "automatiskt när importen är klar.")
        )
      )
    })
  })
}
