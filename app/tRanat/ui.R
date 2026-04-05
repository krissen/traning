library(shiny)
library(DT)

shinyUI(
  navbarPage("tRäning",

    # ------------------------------------------------------------------ Månad
    navbarMenu("Månad",
      tabPanel("Löpande månad",
        fluidRow(
          column(12, plotOutput("plot_monthstatus", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_monthstatus"))
        )
      ),
      tabPanel("Denna månad",
        fluidRow(
          column(12, plotOutput("plot_month_this", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_month_this"))
        )
      ),
      tabPanel("Förra månaden",
        fluidRow(
          column(12, plotOutput("plot_monthlast", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_monthlast"))
        )
      ),
      tabPanel("Toppmånader",
        fluidRow(
          column(12, plotOutput("plot_monthtop", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_monthtop"))
        )
      )
    ),

    # --------------------------------------------------------------------- År
    navbarMenu("År",
      tabPanel("Löpande år",
        fluidRow(
          column(12, plotOutput("plot_yearstatus", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_yearstatus"))
        )
      ),
      tabPanel("Hela år",
        fluidRow(
          column(12, plotOutput("plot_yearstop", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_yearstop"))
        )
      )
    ),

    # ------------------------------------------------------------------- Tempo
    tabPanel("Tempo",
      fluidRow(
        column(12, plotOutput("plot_pace", height = "500px"))
      ),
      fluidRow(
        column(12, DT::dataTableOutput("table_pace"))
      )
    ),

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
        column(12, plotOutput("plot_datesum", height = "500px"))
      ),
      fluidRow(
        column(12, DT::dataTableOutput("table_datesum"))
      )
    ),

    # ---------------------------------------------------------------- Avancerat
    navbarMenu("Avancerat",
      tabPanel("EF",
        fluidRow(
          column(12, plotOutput("plot_ef", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_ef"))
        )
      ),
      tabPanel("HRE",
        fluidRow(
          column(12, plotOutput("plot_hre", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_hre"))
        )
      ),
      tabPanel("ACWR",
        fluidRow(
          column(12, plotOutput("plot_acwr", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_acwr"))
        )
      ),
      tabPanel("Monotoni",
        fluidRow(
          column(12, plotOutput("plot_monotony", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_monotony"))
        )
      ),
      tabPanel("PMC",
        fluidRow(
          column(12, plotOutput("plot_pmc", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_pmc"))
        )
      ),
      tabPanel("Recovery HR",
        fluidRow(
          column(12, plotOutput("plot_recovery_hr", height = "500px"))
        ),
        fluidRow(
          column(12, DT::dataTableOutput("table_recovery_hr"))
        )
      )
    )
  )
)
