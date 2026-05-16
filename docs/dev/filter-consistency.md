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

### Halvöppet intervall

`from`/`to` tolkas som ett **halvöppet** intervall `[from, to)` —
`from` är inklusiv, `to` är exklusiv. Konventionen är genomgående i
paketet: se `.filter_date_range()` (`R/plot.R:54`) och
`filter_by_daterange()` (`R/daterange.R:115`). De privata helpers
som driver Översiktens mini-grafer (`.filter_readiness_range`,
`.filter_running_range` i `R/shiny_helpers.R`) följer samma regel.

Konsekvens: presets som sätter `to = Sys.Date()` (t.ex. "7 dagar"
→ `from = today - 7, to = today`) ger exakt 7 kalenderdagar och
**exkluderar** dagens (pågående) datum. Nya filter måste använda
`< to`, aldrig `<= to`, för att undvika off-by-one mot etiketten.

## Tillåtna avvikelser

Varje avvikelse kräver (1) inline-doc-kommentar direkt i koden som
förklarar varför, och (2) en rad i listan nedan.

### 1. Snapshot-vyer (Översikt → värde-boxar)

`app/tRanat/modules/mod_overview.R` (`vb_readiness`, `vb_weekly_km`,
`vb_ctl`, `vb_tsb`, `vb_acwr`) plockar `slice_max(date, n = 1)` ur
respektive `compute_*()`-output och visar dagens snapshot oberoende
av navbar.

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
