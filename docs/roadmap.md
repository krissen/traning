# tRäning — Roadmap

## Beredskap: KPI-kort och graf visar olika värden

Skärmbild 2026-05-17 13:47: KPI-kortet "Beredskap" visar 56, men
"Beredskap"-grafen direkt under visar dagens punkt på ca 75 (högst upp
till höger). 56 är det aktuella värdet — grafen plockar alltså inte
senaste samplet för dagen, eller renderar en äldre datapunkt som
"dagens". Misstänkt orsaker:

- `readiness_score` aggregeras på datum-nivå men plotten plockar ett
  tidigare sample istället för senaste.
- Datatypskrock — sample-tidsstämpel mot dagens datum.
- KPI-kortet läser `readiness_today`, grafen läser en längre tidsserie
  och hamnar fel på sista raden.

Behöver verifiera vilken funktion som producerar plotten (`mod_overview`-
mini eller `page_health` readiness-dashboard) och säkerställa att KPI
och graf delar samma `senaste-värde-för-dagen`-logik.

## AUR-paket vi själva borde sköta

14 r-cran-paket i AUR är out-of-date (CRAN-versioner finns men maintainer
inte uppdaterat). Vi har lokala forks som funkar på kailash, men paketen
är inte AUR-publishade utöver `r-tracker` och `r-bsicons` som vi själva
maintainar. Lista: `r-viridislite`, `r-uuid`, `r-getopt`, `r-data.table`,
`r-backports`, `r-s7`, `r-selectr`, `r-rvest`, `r-optparse`, `r-dbplyr`,
`r-ggstats`, `r-haven`, `r-httr2`, `r-lazyeval`. Värt att co-maintaina de
viktigaste på AUR.
