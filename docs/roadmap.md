# tRäning — Roadmap

## Health-import-manifest ofullständigt på kailash

`health_import_manifest.json` på kailash innehåller bara 19 entries
(filerna från 2026-05-14, dagen för rebooten). Resterande ~60K HAE-filer
saknas i manifestet, så `traning import health` skulle se dem alla som
"okända" och göra full re-parse — flera timmars jobb. Den bug:en som
tomde manifesten är fixad (PR #26, `(health-export)` commit `330cf57`),
men manifesten har inte återbyggts efter rebooten.

Mitigation: receiver-vägen (`import_health_export(path = X)` per push)
fortsätter fungera incrementellt och fyller på manifesten en fil i taget.
Konsekvensen är bara att en framtida full-import skulle vara dyr.

**Att göra:** rebuilda manifesten på **kedar** (inte kailash —
`feedback_kailash_heavy_r`), `scp` cache + manifest tillbaka. Inte
brådskande; pipeline självläker över tid via receivern.

## Deploy healthcheck & ABI-resilience

Se separat design-dokument när det landar (väntar på samma PR som
implementationen). Kort sammanfattat:

- `traning doctor` CLI-subkommando som verifierar paths, library-load,
  Python-venv-imports.
- `/etc/pacman.d/hooks/traning-r-postupgrade.hook` som auto-rebuildar
  user-lib paket efter R-upgrade (förebygger en återupplevelse av
  2026-05-14-incidenten).
- `traning-doctor.timer` som kör doctor dagligen 03:30 och notifierar
  vid icke-noll exit.

**Krav på doctor-checks som måste finnas innan PR-en landar** (lärt av
2026-05-14/15-incidenterna):

- **Stale-build-detection.** Iterera `installed.packages()` (både
  user-lib och system-lib) och flagga varje paket vars `Built`-tag inte
  börjar med samma `R X.Y` som `R.version`. När R-major-bumpas och
  något paket är kvar på gamla R-versionen ger Shiny *Graphics API
  version mismatch* på första render — buggen som kostade oss två
  fixeringar i sessionen. Hade fångats direkt vid en doctor-körning.
- **Service-checks.** Verifiera att `traning-receiver`, `traning-shiny`
  och `caddy` är aktiva. Shiny ska dessutom svara HTTP 200 på
  `http://127.0.0.1:8423/`. Caddy är inte traning-ägd men hela
  Tailscale-ingressen beror på den (failade vid boot 2026-05-14 pga
  service-ordningen mot tailscaled).
- **Config-installation-checks.** Att en fil ligger i repot betyder
  inte att den är installerad på kailash. Verifiera att
  `/etc/pacman.d/hooks/traning-r-postupgrade.hook` och
  `/etc/systemd/system/caddy.service.d/override.conf` existerar och
  har förväntat innehåll.

**Tester:** stale-build-detection enhetstestas mot mockad
`installed.packages()`-output. Service-/config-checks testas
integration-style via `bash deploy.sh check` mot kailash; de är
inherent svåra att unitt-testa.

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
