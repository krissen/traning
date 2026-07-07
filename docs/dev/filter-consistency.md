# Filter-konsistens i tRanat-dashboarden

## Regeln

Det globala datumspannet i navbar (`mod_date_preset` →
`app.R:138`-reactivet `dates()`) är **sanningskällan** för vilket
tidsfönster en dashboard-komponent ska visa. Default är att varje
komponent honorerar `dates()$from` och `dates()$to`. Pages extraherar
gränserna som reactives:

```r
dr_from <- shiny::reactive(dates()$from)
dr_to   <- shiny::reactive(dates()$to)
```

…och skickar in dem i plot-/report-funktioner (`from = dr_from(),
to = dr_to()`). NULL/NULL ("Allt") motsvarar ingen filtrering.

### Övre gräns beror på kolumn-typ

`from` är alltid **inklusiv**. Tolkningen av `to` beror på vilken
kolumn-typ filtret opererar på:

| Kolumn-typ | Övre gräns | Använder |
|------------|------------|----------|
| `Date` (dagligt/månadsvis aggregat) | `<= to` (inklusiv) | readiness, daily RHR/HRV/sleep/VO2max, ACWR, PMC, MS, HR-zoner-månadsvis, PI-zoner |
| `POSIXct` (sessionStart, momentana händelser) | `< to` (halvöppet) | EF, HRE, decoupling, run-mix, recovery-HR, zone-per-pass, cv-data |

**Date-kolumn (`<= to`):** en datum-rad representerar en avslutad
kalenderdag. Readiness, daily RHR osv. är finaliserade per-dag-
snapshots — när en KPI-box visar dagens snapshot via
`slice_max(date)` ska grafen direkt under matcha rightmost-punkten.
Halvöppet `[from, to)` med `to = Sys.Date()` skulle gömma dagens
rad och skapa visuellt missmatch mot KPI:n (incident 2026-05-17).

**POSIXct-kolumn (`< to`):** en datetime-tidsstämpel representerar
en momentan händelse som kan inträffa när som helst på dygnet.
Halvöppet `[from, to)` med `to = Sys.Date()` exkluderar dagens
pågående pass — korrekt, för en löprunda som "händer i dag" är
ofta inte färdig än när rapporten körs.

### Implementation

Alla tre tidigare parallella helpers (`.filter_input` i `R/report.R`,
`.tail_or_daterange` i `R/report.R`, `.filter_date_range` i `R/plot.R`)
är konsoliderade till en enda källa i `R/daterange.R`:

- **`filter_by_daterange(summaries, date_range, date_col = "sessionStart", closed_upper = FALSE)`**
  (`R/daterange.R`, exporterad) — grundfunktionen. `date_range` är en
  `list(from =, to =)`, t.ex. från `build_date_range()`.
  `closed_upper = TRUE` för Date-callers (ACWR, MS, PMC, readiness,
  HR-zoner, PI-zoner). Default `FALSE` för sessionStart-callers (EF,
  HRE, RHR, decoupling, run-mix, basic report_*-funktioner).
- **`.filter_or_tail(data, n, from, to, date_col, closed_upper = FALSE)`**
  (`R/daterange.R`, intern) — samma princip men med fallback till
  `utils::tail(data, n)` när varken `from` eller `to` är satt, plus
  `dplyr::arrange(desc(date_col))` så resultatet alltid är nyast-först.
  Används av report_*-funktionerna för avancerade mätvärden
  (EF/HRE/ACWR/MS/PMC/recovery-HR/zoner/decoupling).

Mini-graferna i Översikten har dedikerade helpers:
`.filter_readiness_range` (date, inklusiv) och `.filter_running_range`
(sessionStart, halvöppet) i `R/shiny_helpers.R`.

Konsekvens för presets: "7 dagar" (`from = today - 7, to = today`)
ger **7 datetime-pass-rader (exkluderar dagens)** för session-filter,
men **8 datum-rader (inkluderar today)** för daily-aggregat-filter.
Asymmetrin är medveten — daily-aggregatets "8:e rad" är dagens
finaliserade snapshot, samma värde som KPI-kortet visar.

## Tillåtna avvikelser

Varje avvikelse kräver (1) inline-doc-kommentar direkt i koden som
förklarar varför, och (2) en rad i listan nedan.

### 1. Snapshot-vyer (Översikt → värde-boxar)

`app/tRanat/modules/mod_overview.R:87-148` (`vb_readiness`,
`vb_weekly_km`, `vb_ctl`, `vb_tsb`, `vb_acwr`) plockar
`slice_max(date, n = 1)` ur respektive `compute_*()`-output och
visar dagens snapshot oberoende av navbar.

**Varför:** dessa fem boxar är "nu-läge"-indikatorer (form, fitness,
beredskap, ACWR). Att låta dem följa ett historiskt datumspann skulle
ge förvirrande resultat — en användare som filtrerar 2 år bakåt vill
ändå se sin aktuella fitness.

### 2. Multi-år-jämförelser (`page_progress.R`)

`page_progress.R:58-64` förbigår `dates`-argumentet med avsikt.

**Varför:** "Utveckling"-sidan visar historiska jämförelser
(t.ex. "April över åren") som är meningsfulla först över hela
datasetet. Sidans egna "Datumperiod"-kort har lokal `dateRangeInput`
för ad-hoc-lookups.

### 3. Karakterisering över alla år (`page_runprofile.R`)

`page_runprofile.R:43-47` förbigår `dates`-argumentet med avsikt.

**Varför:** "Löpprofil"-sidans plotter visar årsvis karakterisering,
säsongsmönster över alla år och epok-jämförelse. Att tvinga in dem
i ett 12-månadersspann skulle kollapsa dem till ett enda år och
tappa hela poängen.

### 4. Plotter med internt warmup-krav

Plotter som behöver mer data än användarens spann för att räkna ut
stabila värden (typiskt PMC/CTL som behöver ~90d uppvärmning) ska
internt ladda extra historik men respektera `from`/`to` på x-axeln.
Det räknas inte som en avvikelse — användarens spann återspeglas
fortfarande visuellt.

## Hur man flaggar en ny avvikelse

1. Lägg en doc-kommentar precis ovanför koden som motiverar avvikelsen.
   Använd samma stil som `page_progress.R:58-64`.
2. Lägg till en post i listan ovan med fil:rad-referens och en mening
   om varför.

Avvikelser utan både kommentar och listpost ska behandlas som buggar.
