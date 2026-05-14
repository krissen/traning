# page_runprofile.R — Löpprofil: yearly characterization (pace, season, eras)

page_runprofile_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    # Pace distribution (ridges) — ggridges not supported by plotly,
    # render as static.
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("pace_ridges"), "Tempo per år (täthet)",
        use_plotly = FALSE, plot_height = "600px")
    ),
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("tertile_share"),
        "Tempo-fördelning per år"),
      metric_panel_ui(ns("longest_runs"), "Längsta pass per år")
    ),
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("season_pace"), "Säsongsmönster i tempo"),
      metric_panel_ui(ns("heatmap_km"), "Veckokilometer per år")
    ),
    # Distance × pace eras — geom_hex not supported by plotly, render
    # static at full width.
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("dist_pace_era"),
        "Distans × tempo per 5-årsperiod",
        use_plotly = FALSE, plot_height = "800px")
    )
  )
}

page_runprofile_server <- function(id, summaries, dates, is_mobile, sport) {
  # `dates` is intentionally unused — these plots span the full history
  # by design (yearly characterization, season-across-all-years, era
  # comparison). Forwarding the global date preset would collapse them
  # to a single year and lose their point.
  force(summaries)
  shiny::moduleServer(id, function(input, output, session) {
    sp <- shiny::reactive(sport())

    metric_panel_server("pace_ridges",
      plot_fn = shiny::reactive(fetch.plot.pace_year_ridges(summaries,
                                                              sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )

    metric_panel_server("tertile_share",
      plot_fn = shiny::reactive(fetch.plot.pace_tertile_share(summaries,
                                                                sport = sp())),
      is_mobile = is_mobile
    )

    metric_panel_server("longest_runs",
      plot_fn = shiny::reactive(fetch.plot.longest_runs_year(summaries,
                                                              sport = sp())),
      is_mobile = is_mobile
    )

    metric_panel_server("season_pace",
      plot_fn = shiny::reactive(fetch.plot.season_pace(summaries,
                                                        sport = sp())),
      is_mobile = is_mobile
    )

    metric_panel_server("heatmap_km",
      plot_fn = shiny::reactive(fetch.plot.heatmap_km(summaries,
                                                       sport = sp())),
      is_mobile = is_mobile
    )

    metric_panel_server("dist_pace_era",
      plot_fn = shiny::reactive(fetch.plot.distance_pace_era(summaries,
                                                              sport = sp())),
      use_plotly = FALSE,
      is_mobile = is_mobile
    )
  })
}
