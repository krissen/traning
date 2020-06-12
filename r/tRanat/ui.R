library(shiny)

# Define UI for application that draws a histogram
shinyUI(fluidPage(
    
    # Application title
    titlePanel("tRäning"),
    
    # Sidebar with a slider input for number of bins
    # sidebarLayout(
    #     sidebarPanel(
    #         sliderInput("bins",
    #                     "Number of bins:",
    #                     min = 1,
    #                     max = 50,
    #                     value = 30)
    #     ),
        
        # Show a plot of the generated distribution
        mainPanel(
            plotOutput("plot.monthly.dist"),
            fluidRow(
                column(12,
                       dataTableOutput('table.monthly')
                )
            ),
            plotOutput("plot.mean.pace"),
            fluidRow(
                column(12,
                       dataTableOutput('table.mean.pace')
                )
            )
        )
    #)
))
