# page_runprofile.R — Löpprofil: yearly characterization (pace, season, eras)

page_runprofile_ui <- function(id) {
  ns <- shiny::NS(id)
  # with_table = FALSE on all cards: the servers below intentionally
  # do not pass report_fn (these are plot-first views without a
  # canonical tabular form), and the shared module's "Data" accordion
  # would otherwise render as a permanently-empty section.
  shiny::tagList(
    # Pace distribution (ridges) — ggridges not supported by plotly,
    # render as static.
    tags$div(class = "section-spacer",
      metric_panel_ui(ns("pace_ridges"), "Tempo per år (täthet)",
        use_plotly = FALSE, plot_height = "600px", with_table = FALSE)
    ),
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("tertile_share"),
        "Tempo-fördelning per år", with_table = FALSE),
      metric_panel_ui(ns("longest_runs"), "Längsta pass per år",
        with_table = FALSE)
    ),
    bslib::layout_column_wrap(width = 1/2, class = "section-spacer",
      metric_panel_ui(ns("season_pace"), "Säsongsmönster i tempo",
        with_table = FALSE),
      metric_panel_ui(ns("heatmap_km"), "Veckokilometer per år",
        with_table = FALSE)
    ),
    # Distance × pace eras — plotly interactive bin density per era.
    # max-width caps the panel on wide screens (theme(aspect.ratio) is
    # silently dropped by plotly::ggplotly, so the cap has to live in
    # the container rather than the ggplot theme). Only horizontal
    # margins are auto here; the vertical margin from .section-spacer
    # (margin-top: 1rem in www/styles.css) is preserved.
    tags$div(class = "section-spacer",
      style = "max-width: 1200px; margin-left: auto; margin-right: auto;",
      metric_panel_ui(ns("dist_pace_era"),
        "Distans × tempo per epok",
        use_plotly = TRUE, plot_height = "800px", with_table = FALSE)
    )
  )
}

page_runprofile_server <- function(id, data, dates, is_mobile, sport) {
  # `dates` is intentionally unused — these plots span the full history
  # by design (yearly characterization, season-across-all-years, era
  # comparison). Forwarding the global date preset would collapse them
  # to a single year and lose their point.
  force(data)
  summaries <- data@summaries
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
      use_plotly = TRUE,
      is_mobile = is_mobile
    )
  })
}
