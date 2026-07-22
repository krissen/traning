# mod_sport_select.R — global sport bucket selector.
#
# Mirrors the curated buckets exposed by R/sport_filter.R so the
# selector and the underlying data path stay in sync.

# Swedish display labels for the curated bucket *values* exported by
# traning::sport_bucket_names(). Any new bucket added to .SPORT_BUCKETS
# in R/sport_filter.R that we haven't given a Swedish name yet falls
# back to a capitalised version of the bucket name itself.
.bucket_labels_sv <- list(
  ballsport   = "Bollsport",
  gym         = "Gymträning",
  wintersport = "Vintersport",
  all         = "Alla sporter"
)

# Short forms used in the endurance parenthetical. A member without a
# short form falls back to its Swedish label, so extending
# .SPORT_BUCKETS$endurance widens the label instead of quietly making
# it lie (which is what "löp+cyk+gång+sim" did once paddling and
# rowing joined the bucket).
.sport_short_sv <- list(
  running       = "löp",
  cycling       = "cyk",
  walking       = "gång",
  swimming      = "sim",
  paddelsporter = "paddel",
  rodd          = "rodd"
)

.endurance_label <- function() {
  members <- traning::sport_bucket_members("endurance")
  short <- vapply(members, function(m) {
    s <- .sport_short_sv[[m]]
    if (is.null(s)) tolower(traning::sport_label(m)) else s
  }, character(1))
  paste0("Konditionspass (", paste(short, collapse = "+"), ")")
}

# Build the "Sammansatta" choices from the package's bucket helper so
# the selector stays in sync with .SPORT_BUCKETS automatically.
.composite_choices <- function() {
  vals <- traning::sport_bucket_names()
  labels <- vapply(vals, function(v) {
    if (identical(v, "endurance")) return(.endurance_label())
    lab <- .bucket_labels_sv[[v]]
    if (is.null(lab)) tools::toTitleCase(v) else lab
  }, character(1))
  out <- vals
  names(out) <- labels
  out
}

sport_select_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::selectInput(
    ns("sport"),
    label = "Sport",  # visible label needed for screen readers
    choices = list(
      "Direkta sporter" = c(
        "Löpning"        = "running",
        "Cykling"        = "cycling",
        "Gång"           = "walking",
        "Simning"        = "swimming",
        "Styrketräning"  = "strength",
        "Bordtennis"     = "bordtennis",
        "Badminton"      = "badminton",
        "Övrigt"         = "ovrigt"
      ),
      "Sammansatta" = .composite_choices()
    ),
    selected = "running",
    width    = "100%"
  )
}

sport_select_server <- function(id) {
  shiny::moduleServer(id, function(input, output, session) {
    shiny::reactive({
      val <- input$sport
      # nzchar(NA) returns NA, which makes `if (...)` raise; guard
      # explicitly. Also coerce non-character values defensively so a
      # stray numeric/logical input can't reach downstream sport= args.
      if (is.null(val) || !is.character(val) || is.na(val) ||
          !nzchar(val)) {
        "running"
      } else {
        val
      }
    })
  })
}
