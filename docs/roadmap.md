# tRäning — Roadmap

## Filter-konsistens: tabeller och figurer ska följa globala datumspannet

Observerat 2026-05-16 på Översikt: "Beredskap" visar 14 dagar, "Veckovolym"
visar 12 veckor, och båda ignorerar dessutom det globala datumspann-filtret
(date-preset i navbar). Default-beteendet bör vara att alla komponenter
följer det globala filtret; avvikelser kräver ett dokumenterat reellt skäl
(t.ex. trend-charts som behöver längre fönster än användarens valda spann
för att vara meningsfulla).

**Att göra:**

- Audit alla `render*`/`plot_*`/`report_*`-anrop i `app/tRanat/pages/` och
  `modules/` mot `dates`-reactivet. Lista varje komponent som ignorerar
  globalt spann (eller har hard-codad period).
- För varje avvikelse: är det ett reellt skäl (t.ex. PMC behöver 90 d
  warmup för CTL-rampning) eller bara default som råkar smyga in? Hard-
  codade default-spann utan motivering rensas till att följa `dates()`.
- Specifikt: är det reellt att Beredskap=14d och Veckovolym=12v?
  Bör de vara samma? Bör de följa globala spannet?
- Konvention: dokumentera tillåtna avvikelse-skäl (t.ex. "kräver minst
  N veckor för stabil trend") i `docs/dev/`.

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
