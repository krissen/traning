# app.R — tRanat: tr\u00e4ningsanalys-dashboard
#
# Ers\u00e4tter ui.R + server.R med bslib-baserat moduluppbygge.
# global.R laddar fortfarande all data vid appstart.

library(shiny)
library(shinyjs)
library(bslib)
library(bsicons)
library(DT)
library(plotly)
library(ggplot2)

# --- Data (global.R sourced by Shiny, but ensure objects are here) ---
# Guarda på funktionen, inte på `summaries` — i interaktiva
# dev-flöden kan `summaries` finnas kvar i workspacet utan att
# load_session_data() laddats, vilket skulle få server() att krascha.
if (!exists("load_session_data")) source("global.R", local = FALSE)

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
source("pages/page_runprofile.R",     local = TRUE)
source("pages/page_race.R",           local = TRUE)
source("pages/page_sport_mix.R",      local = TRUE)
source("pages/page_import.R",         local = TRUE)

# --- Theme ---
# Colours are sourced from traning_palette (R/theme.R) — the single
# canonical palette, also used by traning_css_root() below and by
# ggplot output. Values not present in traning_palette (bg/fg, and
# navbar-dark-color which has no plot equivalent) stay as literals.
theme <- bs_theme(
  version = 5,
  bg      = "#f5f1ed",
  fg      = traning_palette$text_dark,
  primary = traning_palette$primary,
  secondary = traning_palette$secondary,
  success = unname(traning_palette$status["green"]),
  warning = unname(traning_palette$status["yellow"]),
  danger  = unname(traning_palette$status["red"]),
  info    = unname(traning_palette$status["blue"]),
  base_font = font_collection(
    "-apple-system", "BlinkMacSystemFont", "Segoe UI", "Roboto", "sans-serif"
  ),
  heading_font = font_collection(
    "Monaco", "Menlo", "Consolas", "Courier New", "monospace"
  ),
  font_scale = 0.92,
  "navbar-bg"          = traning_palette$primary,
  "navbar-dark-color"  = "#d4cdc3",
  "card-border-color"  = traning_palette$border_warm,
  "card-bg"            = traning_palette$bg_card
)

# --- UI ---
ui <- page_navbar(
  id = "main_nav",
  title = "tR\u00e4ning",
  theme = theme,
  fillable = FALSE,
  header = tagList(
    shinyjs::useShinyjs(),
    # traning_css_root() emits the :root { ... } custom-property block
    # generated from traning_palette (R/theme.R) — the single canonical
    # palette. Must come before styles.css so its var(--x) references
    # resolve against these values.
    tags$head(tags$style(HTML(traning_css_root()))),
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
  nav_panel("L\u00f6pprofil",
    page_runprofile_ui("runprofile")
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
  # Cache-watcher-paths. Definieras före per-session-snapshoten så
  # att vi kan capture:a mtime-baseline strax INNAN load_session_data()
  # läser cachen. Det stänger race-fönstret där en import som landar
  # mellan load() och första reactivePoll-check annars skulle bli
  # baseline:n och sessionen aldrig fick reload-notis. (Vi accepterar
  # det mindre fönstret där en import landar mellan baseline-capture
  # och load — den ger en tidig notis snarare än en tappad.)
  # NOTE: cache_dir/mtime-watchning nedan läser mtime på cachefilerna
  # direkt från disk — helt oberoende av `data`-bundlen (PR 8 nedan) —
  # så den logiken är opåverkad av att load_session_data() nu returnerar
  # en traning_data-bundle istället för en list.
  cache_dir    <- file.path(Sys.getenv("TRANING_DATA"), "cache")
  summary_path <- file.path(cache_dir, "summaries.RData")
  health_path  <- file.path(cache_dir, "health_daily.RData")
  read_cache_mtimes <- function() {
    paste(
      if (file.exists(summary_path)) as.numeric(file.info(summary_path)$mtime) else 0,
      if (file.exists(health_path))  as.numeric(file.info(health_path)$mtime)  else 0,
      sep = "|"
    )
  }
  baseline_mtime <- read_cache_mtimes()

  # data_version: the exact mtime snapshot that was current just before
  # load_session_data() populated this session's `data` bundle below —
  # i.e. a stable fingerprint of the on-disk data this session is
  # actually showing. Threaded into bindCache() keys on the expensive
  # compute_*-backed reactives (PMC/ACWR/monotony/decoupling/readiness
  # in mod_overview.R, page_training.R, page_performance.R,
  # page_health.R). bindCache()'s default cache is app-scoped (shared
  # across ALL sessions of this R process), so every cached reactive's
  # key MUST include this value: two sessions that loaded the same
  # on-disk data share entries safely, while a session that starts
  # after a mid-run import (new mtimes → new data_version) always gets
  # a fresh key instead of reading another session's plot computed
  # from older data.
  data_version <- baseline_mtime

  # Per-session-cache-snapshot. global.R definierar load_session_data()
  # och behåller dessutom globala summaries/myruns/... för
  # bakåtkompatibilitet. Per-session-anropet säkerställer att varje
  # ny eller omladdad dashboard ser cachen som finns på disk just nu.
  # `data` är en traning_data-bundle (S7) — page-servrarna nedan
  # konsumerar den direkt via `@`-access istället för att packa upp
  # den till separata summaries/health_daily/... argument.
  data <- load_session_data()

  # Global date range + sport
  dates <- date_preset_server("dates")
  sport <- sport_select_server("sport")

  # Mobile detection reactive
  is_mobile <- reactive({
    isTRUE(input$is_mobile)
  })

  # KPI-kortklick på Översikt navigerar till motsvarande detaljtab och
  # scrollar till plot-kortet (inte själva plotten — vi vill ha rubriken
  # synlig). Kompenserar för sticky navbar och lägger till 5px luft.
  # Delay:n ger bslib tid att rendera måltab:en innan scroll triggar.
  kpi_targets <- list(
    readiness  = list(tab = "Hälsa",      dom = "health-readiness-plot"),
    weekly_km  = list(tab = "Utveckling", dom = "progress-monthstatus-plot"),
    ctl        = list(tab = "Träning",    dom = "training-pmc-plot"),
    tsb        = list(tab = "Träning",    dom = "training-pmc-plot"),
    acwr       = list(tab = "Träning",    dom = "training-acwr-plot")
  )
  observeEvent(input$kpi_click, {
    msg <- input$kpi_click
    tgt <- kpi_targets[[msg$type]]
    if (is.null(tgt)) return()
    bslib::nav_select("main_nav", tgt$tab)
    shinyjs::delay(150, shinyjs::runjs(sprintf(
      "var el=document.getElementById('%s'); if(el){var card=el.closest('.card')||el; var nav=document.querySelector('.navbar'); var navH=nav?nav.offsetHeight:0; var top=card.getBoundingClientRect().top+window.scrollY-navH-5; window.scrollTo({top:top,behavior:'smooth'});}",
      tgt$dom
    )))
  })

  # Cache-watcher: poll mtime på de två headline-cacherna och visa
  # icke-störande notis när de uppdateras. summaries.RData är trailing
  # write i my_dbs_save() (myruns skrivs först), så när dess mtime
  # ändras är båda inkrementerade. health_daily.RData skrivs av
  # health-importflödet och är oberoende. 5 s poll + 2 s debounce
  # absorberar back-to-back-skrivningar och håller latensen under
  # 30 s-budgeten. Observern jämför det debouncade poll-värdet mot
  # baseline_mtime (capture:ad före load) så vi inte missar en write
  # som landade mellan load och första poll. Stabilt id på notisen så
  # återkommande imports uppdaterar samma banner istället för att
  # stapla nya.
  cache_mtime <- shiny::reactivePoll(
    intervalMillis = 5000,
    session = session,
    checkFunc = read_cache_mtimes,
    valueFunc = read_cache_mtimes
  )
  cache_mtime_debounced <- shiny::debounce(cache_mtime, 2000)

  shiny::observe({
    if (!identical(cache_mtime_debounced(), baseline_mtime)) {
      shiny::showNotification(
        "Ny träningsdata importerad. Ladda om sidan för att se den.",
        duration = NULL,
        type = "message",
        id = "tranat_cache_update",
        action = shiny::tags$a(
          href = "javascript:window.location.reload()",
          "Uppdatera nu"
        )
      )
    }
  })

  # Page servers — sport= is forwarded to every page that has any
  # sport-aware compute_*/report_*/plot_* call. Pages that are
  # genuinely sport-blind (overview, health, race) can ignore it.
  # `data` is the traning_data bundle; page servers use `@`-access
  # internally (PR 8 of the S7 migration).
  page_overview_server("overview", data, dates, is_mobile, data_version)
  page_training_server("training", data, dates, is_mobile, sport, data_version)
  page_progress_server("progress", data, dates, is_mobile, sport)
  page_sport_mix_server("sport_mix", data, dates, is_mobile, sport)
  page_health_server("health", data, dates, is_mobile, data_version)
  page_performance_server("performance", data, dates, is_mobile, sport, data_version)
  page_runprofile_server("runprofile", data, dates, is_mobile, sport)
  page_race_server("race", data, dates, is_mobile)
  page_import_server("import")
}

shinyApp(ui, server)
