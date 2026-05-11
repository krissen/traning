# app.R — tRanat: tr\u00e4ningsanalys-dashboard
#
# Ers\u00e4tter ui.R + server.R med bslib-baserat moduluppbygge.
# global.R laddar fortfarande all data vid appstart.

library(shiny)
library(bslib)
library(bsicons)
library(DT)
library(plotly)
library(ggplot2)

# --- Data (global.R sourced by Shiny, but ensure objects are here) ---
if (!exists("summaries")) source("global.R", local = FALSE)

# --- Source modules and pages ---
source("modules/mod_date_preset.R",   local = TRUE)
source("modules/mod_sport_select.R",  local = TRUE)
source("modules/mod_metric_panel.R",  local = TRUE)
source("modules/mod_overview.R",      local = TRUE)
source("pages/page_overview.R",       local = TRUE)
source("pages/page_training.R",       local = TRUE)
source("pages/page_progress.R",       local = TRUE)
source("pages/page_health.R",         local = TRUE)
source("pages/page_performance.R",    local = TRUE)
source("pages/page_race.R",           local = TRUE)
source("pages/page_sport_mix.R",      local = TRUE)
source("pages/page_import.R",         local = TRUE)

# --- Theme ---
theme <- bs_theme(
  version = 5,
  bg      = "#f5f1ed",
  fg      = "#2c2013",
  primary = "#3e2723",
  secondary = "#6d4c41",
  success = "#5a8a5a",
  warning = "#b8963a",
  danger  = "#a85a4a",
  info    = "#5a7a9a",
  base_font = font_collection(
    "-apple-system", "BlinkMacSystemFont", "Segoe UI", "Roboto", "sans-serif"
  ),
  heading_font = font_collection(
    "Monaco", "Menlo", "Consolas", "Courier New", "monospace"
  ),
  font_scale = 0.92,
  "navbar-bg"          = "#3e2723",
  "navbar-dark-color"  = "#d4cdc3",
  "card-border-color"  = "#d4c8b8",
  "card-bg"            = "#faf8f5"
)

# --- UI ---
ui <- page_navbar(
  title = "tR\u00e4ning",
  theme = theme,
  fillable = FALSE,
  header = tagList(
    tags$head(tags$link(rel = "stylesheet", href = "styles.css")),
    # Mobile detection
    tags$script("
      $(document).on('shiny:connected', function() {
        Shiny.setInputValue('is_mobile', window.innerWidth < 768);
        $(window).on('resize', function() {
          Shiny.setInputValue('is_mobile', window.innerWidth < 768);
        });
      });
    "),
    bslib::layout_columns(
      col_widths = bslib::breakpoints(sm = 12, md = c(8, 4)),
      date_preset_ui("dates"),
      sport_select_ui("sport")
    )
  ),

  nav_panel("\u00d6versikt",
    page_overview_ui("overview")
  ),
  nav_panel("Tr\u00e4ning",
    page_training_ui("training")
  ),
  nav_panel("Utveckling",
    page_progress_ui("progress")
  ),
  nav_panel("Sport-mix",
    page_sport_mix_ui("sport_mix")
  ),
  nav_panel("H\u00e4lsa",
    page_health_ui("health")
  ),
  nav_panel("Prestation",
    page_performance_ui("performance")
  ),
  nav_panel("T\u00e4vling",
    page_race_ui("race")
  ),
  nav_panel("Import",
    page_import_ui("import")
  )
)

# --- Server ---
server <- function(input, output, session) {
  # Global date range + sport
  dates <- date_preset_server("dates")
  sport <- sport_select_server("sport")

  # Mobile detection reactive
  is_mobile <- reactive({
    isTRUE(input$is_mobile)
  })

  # Page servers — sport= is forwarded to every page that has any
  # sport-aware compute_*/report_*/plot_* call. Pages that are
  # genuinely sport-blind (overview, health, race) can ignore it.
  page_overview_server("overview", summaries, health_daily, myruns,
                        decoupling_data, dates, is_mobile)
  page_training_server("training", summaries, dates, is_mobile, sport)
  page_progress_server("progress", summaries, dates, is_mobile, sport)
  page_sport_mix_server("sport_mix", summaries, dates, is_mobile, sport)
  page_health_server("health", summaries, health_daily, dates, is_mobile)
  page_performance_server("performance", summaries, myruns, health_daily,
                           decoupling_data, dates, is_mobile, sport)
  page_race_server("race", summaries, dates, is_mobile)
  page_import_server("import")
}

shinyApp(ui, server)
