# page_overview.R — Översikt: thin pass-through to mod_overview
#
# Kept as a page_*.R wrapper (matching the other tabs' file layout /
# app.R's page_overview_server("overview", ...) call site) but no
# longer nests a second module namespace — mod_overview_ui/_server
# already apply their own NS(id) / moduleServer(id, ...), so this file
# forwards id/data/dates/is_mobile directly instead of re-wrapping in
# an extra "dashboard" sub-id.

page_overview_ui <- function(id) {
  mod_overview_ui(id)
}

page_overview_server <- function(id, data, dates, is_mobile, data_version) {
  force(data)
  mod_overview_server(id, data, dates, is_mobile, data_version = data_version)
}
