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
      column(2,
        selectInput("date_preset", NULL,
          choices = c(
            "Allt"              = "all",
            "7 dagar"           = "7d",
            "4 veckor"          = "4w",
            "3 månader"        = "3m",
            "6 månader"        = "6m",
            "I år"             = "ytd",
            "12 månader"       = "12m",
            "2 år"             = "2y",
            "5 år"             = "5y",
            "Anpassa\u2026"     = "custom"
          ),
          selected = "all",
          width = "160px"
        )
      ),
      column(3,
        conditionalPanel(
          condition = "input.date_preset === 'custom'",
          dateRangeInput("global_daterange", NULL,
            start     = Sys.Date() - 365,
            end       = Sys.Date(),
            separator = "\u2014"
          )
        )
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

    # -------------------------------------------------------------- Readiness
    tabPanel("Readiness",
      fluidRow(
        column(12, plotly::plotlyOutput("plot_readiness_score", height = "800px"))
      ),
      fluidRow(
        column(12, DT::dataTableOutput("table_readiness_score"))
      )
    ),

    # ------------------------------------------------------------------- Hälsa
    navbarMenu("Hälsa",
      plot_tab("resting_hr", "Vilopuls"),
      plot_tab("hrv", "HRV"),
      plot_tab("sleep", "Sömn"),
      plot_tab("vo2max", "VO2max")
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
