library(shiny)
library(DT)
library(plotly)

# Helper: standard tab layout with plotly + DT table
plot_tab <- function(id, title, ...) {
  tabPanel(title,
    ...,
    fluidRow(
      column(12, plotly::plotlyOutput(paste0("plot_", id), height = "500px"))
    ),
    fluidRow(
      column(12, DT::dataTableOutput(paste0("table_", id)))
    )
  )
}

shinyUI(
  navbarPage("tRäning",
    header = fluidRow(
      column(3,
        dateRangeInput("global_daterange", NULL,
          start = Sys.Date() - 365,
          end   = Sys.Date(),
          separator = "—"
        )
      ),
      column(2,
        checkboxInput("use_daterange", "Filtrera på datum", value = FALSE)
      )
    ),

    # ------------------------------------------------------------------ Månad
    navbarMenu("Månad",
      plot_tab("monthstatus", "Löpande månad"),
      plot_tab("month_this", "Denna månad"),
      plot_tab("monthlast", "Förra månaden"),
      plot_tab("monthtop", "Toppmånader")
    ),

    # --------------------------------------------------------------------- År
    navbarMenu("År",
      plot_tab("yearstatus", "Löpande år"),
      plot_tab("yearstop", "Hela år")
    ),

    # ------------------------------------------------------------------- Tempo
    plot_tab("pace", "Tempo"),

    # --------------------------------------------------------------- Datumperiod
    tabPanel("Datumperiod",
      fluidRow(
        column(4,
          dateRangeInput("datesum_range", "Datumperiod",
            start = Sys.Date() - 180,
            end   = Sys.Date()
          )
        )
      ),
      fluidRow(
        column(12, plotly::plotlyOutput("plot_datesum", height = "500px"))
      ),
      fluidRow(
        column(12, DT::dataTableOutput("table_datesum"))
      )
    ),

    # ---------------------------------------------------------------- Avancerat
    navbarMenu("Avancerat",
      plot_tab("ef", "EF"),
      plot_tab("hre", "HRE"),
      plot_tab("acwr", "ACWR"),
      plot_tab("monotony", "Monotoni"),
      plot_tab("pmc", "PMC"),
      plot_tab("recovery_hr", "Recovery HR")
    )
  )
)
