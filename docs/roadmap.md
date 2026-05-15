# tRäning — Roadmap

## Pacman-managed R-bibliotek på kailash — uppstädning

Efter R 4.5→4.6-incidenten 2026-05-14 flyttades 70 R-paket från manuellt
installerade orphans till pacman/AUR-managed system-lib. Två rensningar
återstår:

- **Fas 4a — system-lib orphans.** `/usr/lib/R/library/` har städats från
  157 paket som pacman inte ägde, men ytterligare orphans kan dyka upp om
  framtida `pacman -Syu` lämnar AUR-paket out-of-sync. `scripts/audit_r_libs.sh`
  rapporterar nuläget — se `system-orphan`-listan.
- **Fas 4b — user-lib dubbletter.** `~/R/library/` har 267 paket varav
  ~157 är dubbletter med system-lib (legacy från före pacman-städet).
  De skuggar pacman-versionerna eftersom user-lib är först i `.libPaths()`.
  Bör tas bort så pacman-versionen vinner; de ~110 unika user-lib paketen
  (CRAN-fallback för AUR-out-of-date) ska behållas.

Båda är kosmetiska — pipeline fungerar idag. Värt att städa innan nästa
R-upgrade så vi har en känd baseline.

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

## AUR-paket vi själva borde sköta

14 r-cran-paket i AUR är out-of-date (CRAN-versioner finns men maintainer
inte uppdaterat). Vi har lokala forks som funkar på kailash, men paketen
är inte AUR-publishade utöver `r-tracker` och `r-bsicons` som vi själva
maintainar. Lista: `r-viridislite`, `r-uuid`, `r-getopt`, `r-data.table`,
`r-backports`, `r-s7`, `r-selectr`, `r-rvest`, `r-optparse`, `r-dbplyr`,
`r-ggstats`, `r-haven`, `r-httr2`, `r-lazyeval`. Värt att co-maintaina de
viktigaste på AUR.
