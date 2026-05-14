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

## AUR-paket vi själva borde sköta

14 r-cran-paket i AUR är out-of-date (CRAN-versioner finns men maintainer
inte uppdaterat). Vi har lokala forks som funkar på kailash, men paketen
är inte AUR-publishade utöver `r-tracker` och `r-bsicons` som vi själva
maintainar. Lista: `r-viridislite`, `r-uuid`, `r-getopt`, `r-data.table`,
`r-backports`, `r-s7`, `r-selectr`, `r-rvest`, `r-optparse`, `r-dbplyr`,
`r-ggstats`, `r-haven`, `r-httr2`, `r-lazyeval`. Värt att co-maintaina de
viktigaste på AUR.
