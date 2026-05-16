# tRäning — Roadmap

## Shiny-konsistens efter import

Observerat 2026-05-15 ca 21:00: dagens andra löppass importerades och
aviseringen om importen kom fram, men `tRanat`-dashboarden visade
fortfarande bara dagens första pass när den öppnades senare på kvällen.
Dagsformen stod också kvar på morgonens tidigaste värde (~90) trots
att den hade reviderats lägre under dagen. Båda är samma symptom:
**Shiny ser inte den senaste cachen**.

Hypotes: import-pipelinen avslutar sin "klar"-signal vid avisering
skickad, men Shiny-processen läser RData-cachen vid app-start (eller
sällan därefter), så fram tills nästa restart visar dashboarden stale
data. Aviseringen är då ärligt felaktig — den lovar att senaste
informationen finns på sidan, men gör det inte.

**Föreslagna åtgärder:**

- Identifiera om Shiny-servern faktiskt re-läser RData efter import
  eller om den cachar i minnet. `reactiveFileReader` / `invalidateLater`
  i `app/tRanat/server.R` finns redan på vissa filer — verifiera
  täckningen mot ALLA filer importen kan röra (summaries, myruns,
  health_daily, day_summaries, readiness-cache, …).
- Lägg in en explicit "post-import flush"-steg som rörselar shinyns
  reactiveFileReader (t.ex. genom att touch:a cache-fil eller skicka
  en notify till loopback). Alternativt restart:a `traning-shiny`
  efter större importer — men det är tungt och stör pågående
  sessioner.
- Acceptanskriterium: efter en lyckad `traning import health` eller
  `traning fetch garmin` ska en omladdad dashboard på samma host visa
  den nya datan inom 30 sekunder utan service-restart.

## Dashboard — observerade rendering-buggar

Hittade vid manuell genomgång efter R 4.6-uppgraden men oberoende av
den (gäller även i tidigare versioner).

- **Säsongsmönster i tempo — bakgrundsbild visas inte.** Plotten
  förväntar sig en season-band-bakgrund (vinter/vår/sommar/höst) men
  den renderas tom. Kontrollera om bakgrunds-geom:en faktiskt läggs
  till och, om så, varför den inte syns (möjligen z-ordning, alpha,
  scale-domain).
- **Veckokilometer per år — månadsheaders avklippta.** X-axis-faceten
  klipper bort/överlappar månadsetiketterna. Justera `theme(strip.text)`
  / `panel.spacing` eller axis-margin.
- **Distans×tempo per epok — saknar hover.** *Inte ett krav; valfri.*
  Plotten är statisk där andra liknande är interaktiva (plotly).
  Hover/tooltip ger ingen info. Om det är enkelt att slå på `ggplotly()`
  eller ett `plotly`-event-handler hade det varit en trevlighet. Stor
  refaktorering är inte motiverad. (Bilden blir också ganska utsmetad
  på bred skärm — kan vara värt en aspect-ratio-cap, men sekundärt.)

## Enhetligt visuellt tema (figurer + tabeller)

Plotterna har idag mix av brun temafärg och default ggplot-blått; det finns
inget centralt `theme_traning()` eller delad palett mellan R och CSS. Behöver
en sanningskälla för färger, ett tema-objekt som alla plotter använder, och
en konvention för dokumenterade avvikelser. Tabeller dubbelkollas separat —
borde redan följa CSS-temat. Detaljer: `docs/dev/visual-theme-design.md`.

## AUR-paket vi själva borde sköta

14 r-cran-paket i AUR är out-of-date (CRAN-versioner finns men maintainer
inte uppdaterat). Vi har lokala forks som funkar på kailash, men paketen
är inte AUR-publishade utöver `r-tracker` och `r-bsicons` som vi själva
maintainar. Lista: `r-viridislite`, `r-uuid`, `r-getopt`, `r-data.table`,
`r-backports`, `r-s7`, `r-selectr`, `r-rvest`, `r-optparse`, `r-dbplyr`,
`r-ggstats`, `r-haven`, `r-httr2`, `r-lazyeval`. Värt att co-maintaina de
viktigaste på AUR.
