# tRäning — Changelog

## 2026-05-15 — Health-import-manifest återställd på kailash

Kailash-manifestet hade fallit ner till 19 entries efter rebooten
2026-05-14 — alla ~60K HAE-filer hade förlorats ur manifestet och
nästa `traning import health` skulle ha degenererat till en
flera-timmars-full-rebuild (tester visade ca 7 minuter och ingen synlig
progress, killed innan slutfört). Manifesten överwrite-buggen som
ursprungligen tomde den är fixad sedan PR #26
(`(health-export)` commit `330cf57`); det som saknades var en
re-base av manifesten på existerande data.

- **Rebuild på kedar.** Inkrementell `import_health_export()` på kedar
  fångade upp 23 nya rader på 42 sek (kedar hade redan ett komplett
  manifest från 2026-05-14 23:42). 73,372 rader totalt, period
  2012-07-24 → 2026-05-15, 62,458 manifest-entries.
- **scp till kailash.** `health_daily.RData` (323 KB) +
  `health_import_manifest.json` (5.6 MB) shippade. Kailash-manifestet
  växte från 19 → 62,458 entries. Receivern fortsätter att fylla på
  inkrementellt vid nästa push.
- **`.notify_state.json` + `health.db` gitignorade.** Båda är runtime
  state, inte data, och blockerade commit på kailash. `health.db` är
  också tom (0 bytes) sedan 2026-04-25 och kan tas bort separat.

## 2026-05-15 — User-lib dubbletter borttagna på kailash (Fas 4b)

`~/R/library/` på kailash innehöll 263 paket varav 99 hade en exakt
versionsidentisk kopia i `/usr/lib/R/library/` (pacman-managed system-lib).
Eftersom user-lib står först i `.libPaths()` skuggade dubbletterna
pacman-versionen, vilket betyder att framtida `pacman -Syu`-uppdateringar
av AUR-paketen inte skulle få effekt — man skulle fortsatt ladda gamla
user-lib-kopian. Roadmap-Fas 4b efter R 4.5→4.6-omläggningen.

- **Audit-skript.** `scripts/audit_r_libs.sh` rapporterar `system-orphan`
  (paket pacman inte äger), `user-duplicate` (skuggar system-lib) och
  `user-unique` (CRAN-fallback). Kör `--summary` för räkning,
  `--list <kategori>` för parseable utdata. Lämnas i repot för
  regelbunden kontroll innan framtida R-uppgraderingar.
- **Audit på kailash.** 0 system-orphans (Fas 4a redan klar efter
  R 4.6-städet), 99 user-duplicates, 164 user-uniques. Samtliga
  dubbletter hade identisk versionsnummer i båda lib-katalogerna —
  ingen "user newer"-konflikt att hantera manuellt.
- **Backup + radering.** 99 katalogerna paketerades först som
  `~/r-userlib-dupes-backup-2026-05-15.tar.gz` (112 MB) på kailash,
  därefter `rm -rf` på dubbletterna i user-lib. Efter: 164 unika
  paket kvar (CRAN-fallback), 0 dubbletter.
- **Smoke-test grön.** `.libPaths()` oförändrat, core libraries
  (rlang, ggplot2, plotly, dplyr, …) laddar nu från system-lib,
  `devtools::load_all(\"~/dev/traning\")` OK, traning-shiny restartad
  och svarar HTTP 200 med 100 KB HTML utan `Graphics API`-fel i
  journalen.

## 2026-05-15 — R-pipeline omläggning till pacman-managed på kailash

Arch pacman uppgraderade `r` `4.5.3-1 → 4.6.0-1` 2026-05-14 15:56. Det är
en major-ABI-bump där flera C-API-symboler togs bort (`SETLENGTH`,
`Rf_findVarInFrame`); alla R-paket i `~/R/library/` som var kompilerade
mot R 4.5 vägrar därefter laddas mot R 4.6. Första HAE-pushen efter
rebooten failade med `unable to load shared object '.../rlang.so':
undefined symbol: SETLENGTH` och hälsoimporten gick ner.

Felsökningen avslöjade att hela R-paketstacken på kailash hade varit
manuellt installerad (`sudo R -e install.packages` historiskt) till
`/usr/lib/R/library/` — pacman ägde bara `r` själv (base + recommended).
Av 281 paket i system-lib var 250 "orphans" som pacman inte trackade,
vilket innebar att de inte uppdaterades automatiskt vid `pacman -Syu`
och därför hängde sig kvar mot gammal R. Praxis ändrades:

- **R-paket installeras nu via pacman/AUR i första hand.** Av de 137
  paket projektet behöver finns 135 i AUR under namnkonventionen
  `r-<lowercase>`. `yay -S` installerar dem till `/usr/lib/R/library/`
  med pacman-DB-registrering, så nästa `pacman -Syu` håller dem i
  ABI-synk med R-uppgraderingar.
- **`r-tracker` och `r-bsicons` publicerade som nya AUR-paket** (krissen
  som maintainer). Båda saknades helt i AUR; vi behövde dem i pacman-
  trädet för att inte ha en stor exception från policyn. PKGBUILDs i
  `~/dev/aurbuild/`.
- **14 outdated AUR-paket fork-byggda lokalt.** AUR PKGBUILDs för
  `r-viridislite`, `r-uuid`, `r-getopt`, `r-data.table`, `r-backports`,
  `r-s7`, `r-selectr`, `r-rvest`, `r-optparse`, `r-dbplyr`, `r-ggstats`,
  `r-haven`, `r-httr2`, `r-lazyeval` pekar på CRAN-tarballs som flyttats
  till `src/contrib/Archive/`, så `yay` failar på download. Patchade
  versioner byggda lokalt i `~/aurbuild-local/` på kailash, flaggade
  som out-of-date på AUR. `r-getopt`, `r-rvest`, `r-uuid` hade också
  bug-fix för en typo (`${scrdir}` istället för `${srcdir}`) i sina
  PKGBUILDs.
- **System-lib rensad från 157 orphans.** Sedan installerades 70+
  pacman/AUR-byggda paket med `pacman -U`. Manifestet "vad har pacman
  ansvar för" är nu konsistent igen.
- **`install.packages` är dokumenterad fallback för paket AUR inte
  täcker.** ~110 paket lever fortsatt i user-lib (`~/R/library/`)
  eftersom inget AUR-paket finns för dem; de byggs om manuellt vid
  R-major-bump. Den vägen är begränsad och dokumenterad
  (se `feedback_pacman_first_on_arch`-memory).

**Graphics API mismatch (uppföljning).** Efter omläggningen kvarstod
två paket — `plotly` och `ragg` — byggda mot R 4.5 i user-lib. De
producerar grobs/grid-objekt som binder till nuvarande `grid`-API-
version vid creation; vid render mot R 4.6:s grid blev resultatet
`Graphics API version mismatch` på alla Shiny-plottar. Fixen:
installera `r-plotly` + `r-ragg` via yay, ta bort de stale user-lib-
kopiorna, rebuilda 6 paket (RSQLite, devtools, ggmap, pkgdown,
roxygen2, usethis) som saknar AUR-version mot R 4.6 via
`install.packages`. tRanat-dashboarden renderar plottar normalt igen.

**Caddy-startup-race.** Caddys `traning`-block binder explicit till
tailnet-IP:n `100.93.126.68`. Vid kall boot på kailash startar
`caddy.service` innan `tailscaled` hunnit aktivera interfacet, så
`bind: cannot assign requested address` failar hela Caddy — även
`fbkstats.niemi.cc` togs ner. Drop-in
(`/etc/systemd/system/caddy.service.d/override.conf`) med
`After=tailscaled.service` och `Wants=tailscaled.service` löser
ordningen. Versionshanterad i `vastushastra`-repot under
`enheter/kailash/caddy/caddy.service.d/`; installationsanvisningar
i Caddy-README:n där.

**Kailash är IPv4-only.** ISP:n routar inte IPv6 till bostaden; bara
Tailscale ger IPv6 (link-local + tailnet-prefix). Glibcs default-
prioritering föredrar IPv6 vid AAAA-svar, så `git clone` mot AUR
hängde i 10-sekunders-timeouter per paket innan IPv4-fallback. Fixen:
`/etc/gai.conf` med `precedence ::ffff:0:0/96 100` avkommenterad —
standardpraxis för IPv4-only Arch-hostar. Permanent.

## 2026-05-15 — Hälsoimport-manifest-bugg

Inkrementell hälsoimport hade fallit tillbaka till full re-parse av alla
60K+ HAE-filer flera gånger om dagen utan att vi märkt det. Symtomet syntes
först när R 4.5→4.6-uppgraden på kailash exponerade hur långsamma "snabba"
inkrementella körningar egentligen var.

- **Bug fixad: single-file-import skrev över hela manifesten.**
  `import_health_export(path = X)` (anropas av `notify_helper.R` på varje
  HAE-push) startade med en tom manifest istället för att ladda den
  existerande, mergade in `{X: md5}` och skrev tillbaka — alla andra
  entries försvann. Receivern's flush:ar gör detta flera gånger per dag,
  så manifest:en var i praktiken nollställd kontinuerligt. Nästa
  "inkrementell" import såg då alla 60K+ filer som "okända" och
  parserade om hela cachen. Fixen laddar manifest:en en gång i toppen
  av importen och återanvänder den som merge-bas vid save.

- **Bug fixad: metric-filter-tomt fall hoppade manifest-uppdatering.**
  Om alla ändrade filer filtrerades bort av `.import_metrics`-filter
  (de tillhör metrics vi inte importerar), gick funktionen via
  early-return utan att uppdatera manifest:en — så filerna hamnade i
  "okänd" på varje körning för alltid. Helper:n
  `.compute_manifest_to_save()` centraliserar nu save-policyn och kallas
  från varje exit-path; bygger entries från hela kandidat-setet
  (`files`), inte bara post-filter-listan.

- **Atomic manifest-skrivning.** `.save_manifest()` skrev tidigare direkt
  med `jsonlite::write_json`; en krasch mitt i en 10MB-skrivning kunde
  lämna en halv JSON på disk. Nu serialiseras till `.tmp` och rename:as
  atomiskt (POSIX-invariant; pipelinen är Linux/macOS-only).

- **Härdning mot korrupt manifest.** `.load_manifest()` validerar nu att
  parsed-JSON är en named list — skalär, unnamed array eller list med
  tomma keys degraderas till tom manifest med varning, istället för att
  passera vidare och krascha på `manifest[[key]]`-merge senare.
  `.filter_changed_files()` accepterar `NA_character_` i `$md5` som
  "ny fil" istället för att förgifta result-vektorn via `tools::md5sum(f)
  != NA → NA`.

- **Test-isolation.** Det existerande `test_force.json`-testet skrev tidigare
  till utvecklarens produktions-manifest eftersom det inte isolerade
  `$TRANING_DATA` — vilket är exakt så `"test_force.json"` ursprungligen
  smög in i produktionsmanifesten. `withr::local_envvar()` nu i testet,
  plus regressionstester som låser merge-not-overwrite-beteendet,
  filter-tomt-uppdateringen, corrupt-manifest-recovery och atomic-write-
  semantiken.

PR #26 — landade efter tre Codex/Copilot-ronder.

## 2026-05-14 — Roadmap-städning: filter-bug, defaults, två nya kort

Sju roadmap-punkter avklarade i ett svep, plus en ny dashboard-feature.
PR #24 — slutgiltigt landade efter sju Copilot/Codex-rondsfix.

- **Bug fixad: globalt "Allt"-filter visar nu hela historiken.** Tidigare
  silent-truncade `fetch.plot.acwr/monotony/pmc/readiness_score` och
  `plot_sport_calendar` till 365/90/366 dagar när Shiny skickade
  `from = NULL` (det "Allt"-presetet faktiskt levererar). De fem
  funktionerna refaktoriserades till den befintliga
  `.filter_date_range()`-helpern som tolkar `NULL` som "ingen gräns".
  `days`-parametern droppad från acwr/monotony/pmc-signaturerna (inga
  anropare skickade den explicit). CLI:s `--help` uppdaterad.
  `.compute_span_days()` tar nu en valfri `data_dates`-hint så
  `.adaptive_date_scale()` får rätt break-tätthet på multi-års-spans
  (annars råkade scale_x_date på 2-decennium-data med 1-månads-breaks
  som varnade om numerisk konvertering). `plot_sport_calendar` med
  `from = NULL` deriverar nu start från det sport-filtrerade subsetet
  så `sport = "ballsport"` på en 2004-dataset inte renderar 15 års
  tomt fält innan första bollsporten.
- **EF + aerob decoupling: veckokilometer-panelen tom**. Plottarna
  använder POSIXct på x-axeln, där `geom_col(width = 1)` betyder
  **en sekund** — bars blev sub-pixel-tunna över multi-års-spans och
  panelen såg tom ut. Bytt till `width = 86400` (1 dag i sekunder).
  ACWR/PMC var oberörda eftersom de använder Date-axel där `width = 1`
  redan är 1 dag.
- **Aerob decoupling: outliers** (–74.6 % och –53.1 % från 2011, båda
  med `NA avg_hr`) kommer från sessioner där per-second-HR-datat var
  trasigt men trackeR-objektet höll bogus-värden som överlevde
  validity-gaten. `compute_decoupling()` har nu ett fysiologiskt
  sanity-tak (`cap_pct = 25`, default ±25 %) som **markerar** sessioner
  utanför intervallet i en ny `capped`-kolumn istället för att tyst
  droppa dem. Den 28-dagars rullande genomsnittet exkluderar capped-
  rader så ett enstaka -75 %-artefakt inte drar ner trendlinjen i en
  månad. `fetch.plot.decoupling()` renderar capped-rader som röda
  trianglar clampade till ±cap_pct så y-skalan inte sprängs men
  användaren ser *vilka* datum som flaggades. Cache-fältet ingår i
  parameterhashen så äldre cacher auto-invalideras; cap_pct är en
  parameter på både compute- och plot-nivå (vidarebefordras
  konsistent).
- **Sport-mix förvalt mått: TRIMP** (tidigare distans). Reorder så
  TRIMP listas först i radioButtons.
- **Kronisk belastning förvalda sporter:** cykling, gång, löpning,
  paddel, styrka (tidigare `head(choices, 4)` som plockade fyra första
  sporterna i bucket-ordning). Implementerad som `intersect(preferred,
  choices)` så vi inte försöker pre-välja en sport som saknas i datat.
- **Ny widget: Trivia-accordion på Översikt** (`compute_fun_facts()`
  i ny `R/fun_facts.R`). Sex did-you-know-fakta: topp 5 sporter, första
  registrerade pass, längsta uppehåll mellan löpturer, antal hela
  kalendermånader utan ett enda pass, längsta löpningen, snabbaste
  löpturen >5 km. Kollapsad som default. Hanterar NA-sport på första
  passet med generisk "Aktivitet"-etikett (annars producerade
  `sport_label(NA)` literala "NANA" via paste0(NA, NA)).
- **Ny plot: Δ Mediantempo per vecka** på Träning-fliken
  (`fetch.plot.pace_week_delta()`). Per ISO-vecka: skillnad i
  mediantempo mot föregående vecka. Stapel under noll = veckan blev
  snabbare. Använder globalt tidsfilter och `.run_profile_*`-helpers
  med `pace_filter = FALSE` så cykling, gång och paddelsporter
  (utanför löpnings 2.5–10 min/km-band) också producerar data.
- **Fyra nya testfiler:** `test-plot-allt-filter.R` (regressionsskydd
  för Allt-buggen), `test-fun-facts.R` (inkl. NA-sport-edge case),
  `test-pace-week-delta.R`, plus utvidgade `test-decoupling.R`-tester
  för `capped`-kolumnen och rolling-mean-exklusion.

## 2026-05-14 — Löpprofil-fliken: åtta nya karaktärs-plottar

Åtta plottar från `tmp/run_type_plots/`-sandlådan flyttades in i paketet
som riktiga `fetch.plot.*`-funktioner och exponeras nu via Shiny, MCP
(Vayu) och `inst/mcp_bridge.R`. Två befintliga plottar ersattes där den
nya gav bättre svar på samma fråga.

- **Ny flik "Löpprofil"** mellan Prestation och Tävling. Sex kort:
  tempo per år som ridges (volym-färg), tempo-fördelning i lugn/medel/
  snabb, längsta pass per år (topp-5 staplat), säsongsmönster i tempo,
  veckokilometer per år som heatmap, distans × tempo per epok.
- **Utveckling-fliken polerad.** "Tempo"-kortet visar nu medianpace per
  år med 25–75 %-band och sex objektiva milstolpar (ersätter den enkla
  scatter+loess som låg där). "Löpande år"-kortet visar nu kumulativ
  km vecka-för-vecka med innevarande år framhävt (ersätter
  stapeldiagrammet med en enda stapel per år). Löpande år-tabellen i
  accordion är oförändrad (`report_yearstatus`); Tempo-tabellen byter
  schema från `fetch.my.mean.pace` (år / totDuration / meanPace /
  minPace) till `report_yearstop` (År / Km/dag / Km, tot / Km, max /
  Tempo, medel / Turer) — bredare data med samma medelpace-kolumn.
- **MCP**: nytt verktyg `get_run_character(chart=..., after, before,
  sport)` med åtta chart-värden — `pace_year`, `pace_ridges`,
  `tertile_share`, `longest_runs`, `season_pace`, `heatmap_km`,
  `cumulative_km`, `distance_pace_era`. Plot-only (Image-retur).
- **Borttagningar**: `fetch.my.mean.pace`, `fetch.plot.mean.pace`,
  `plot_yearstatus`. CLI:s `--year-running --plot` använder nu
  `fetch.plot.cumulative_km`; `--total-pace --plot` använder
  `fetch.plot.pace_year`; `--total-pace`-tabellen är nu
  `report_yearstop`.
- **DESCRIPTION**: nya Imports — `ggridges`, `ggrepel`, `hexbin`,
  `scales`, `viridisLite`.

## 2026-05-13 — Pipeline notification fixes + Telegram mirror

Three concurrent regressions resolved (PR #18, #20):

- **Strava webhook restored.** HA `rest_command.traning_fetch_garmin`
  pointed at `localhost:8421`, but the receiver was hardened to bind
  only on the Tailscale IP (`100.93.126.68:8421`) in `65f850d`
  (2026-05-11). Three Strava-triggered fetches had failed silently
  with `Connect call failed`. HA URL repointed to Tailscale.
- **Timer-driven Garmin notifications now visible.**
  `scripts/garmin_fetch_import.sh` suppressed notify stderr via
  `2>/dev/null` and never called `log_notification()`, so
  timer-triggered imports were invisible both in the systemd journal
  and in `notifications.jsonl`. Refactored to mirror the
  `notify` + `log_notification` pair from `app.py`, pass payload via
  env vars (safe against quote chars in messages), and surface logger
  output. Triggers `garmin_timer` and `garmin_timer_insight`.
- **Telegram mirror added.** All pipeline notifications now fan out
  to a personal Telegram DM in addition to iOS push. Implementation
  switched once during the work: `platform: group` (legacy fan-out)
  silently dropped the Telegram half because the modern
  `notify.telegram_bot_752463669_<chat>` integration is only
  addressable via `notify.send_message` with `target.entity_id`, not
  as a legacy notify service. Final design is a HA script
  (`script.traning_notify`) that calls both channels explicitly.
  Python receiver POSTs to `script/traning_notify` with `{title,
  message}`.

Removed: stale `automations/traning_garmin_fetch.yaml.bak` on kailash.

Follow-up: issue #19 — morning readiness prose mixes `load_flag`
(yesterday's TRIMP > 2× ATL) with TSB (positive form), producing texts
like "Drar ner: hög belastning (TSB +9.4)". Plus HRV trend addendum
can appear together with "OK: stark HRV" because the two are computed
on independent windows.

## 2026-05-11 — Smart insight context line

Roadmap item "Smart insight notifications" closed (PR #17). The
morning readiness push now appends at most one prioritised trend
sentence from a fixed chain — first match wins, the rest stay
silent:

1. **Streak comeback** — "Första löpningen på N dagar." when today
   is the first run after ≥ 3 calendar days.
2. **ACWR commentary** — "ACWR 0.68 — låg belastning, bra
   återhämtning." / "ACWR 1.62 — hög belastning, skadetröskeln i
   sikte." when the ratio sits outside the normal 0.8–1.3 band.
3. **HRV downtrend** — "HRV sjunkande trend — ta det lugnt idag."
   when the 7-day linear slope is below -0.5 ms/day.

Opt-out via `TRANING_NOTIFY_CONTEXT=false` in `.Renviron`. Helpers
live in `R/insight_context.R`; `health_insight_readiness()` calls
`.insight_context_line()` between the existing weekly recap and
the final paste.

Race-readiness context deliberately deferred — there's no source
of truth for "next race" in the pipeline today.

## 2026-05-11 — Phase 5d: Taper plan & race readiness

Roadmap item "Phase 5d: Taper planning & race analysis" closed
(PR #16). Two new R primitives plus surfaces on every layer:

- `compute_taper_plan(summaries, race_date, distance_km,
  taper_weeks)` returns one ISO-week row from this Monday through
  race week. Volume curve linearly interpolates between baseline
  (4-week median of running km, including no-run weeks) and a
  0.45 race-week floor.
- `compute_race_readiness(summaries, health_daily, target_date,
  taper_weeks)` returns a 0–100 composite (CTL trend / projected
  TSB / HRV stability / resting-HR stability) plus Swedish prose
  and a status label (Klar ≥ 70, Tveksam 40–69, Inte klar < 40).
  Missing components are dropped from the average rather than
  zero-scored, and the prose surfaces which ones weren't measured.

Surfaces:
- MCP: `get_taper_plan()`, `get_race_readiness()` —
  `python/traning_cli/mcp/tools.py`.
- Shiny: `app/tRanat/pages/page_race.R` replaces the Phase-5d
  placeholder with date + distance + taper-week inputs and three
  cards (weekly plan, prose, readiness status header).

Algorithm trade-offs documented in `docs/dev/race-taper-design.md`.

## 2026-05-11 — Shiny backfill upload page

Roadmap item "Shiny import UI" closed (PR #15). New **Import** tab
in tRanat lets the user drop a zip (Withings export today, any
future `identify_archive()` target tomorrow), preview which
metrics + how many new canonical files would be written via
`--dry-run`, and commit with a single click. Uses the existing
`traning backfill` CLI under the hood via a small system2 wrapper
in `R/python_cli.R` — no reticulate, no duplicated archive
parsing.

## 2026-05-11 — Smart sport-mix metric switcher

Roadmap item "Sport-mix per month: kcal/time, not just km" closed
(PR #14) with one substantive deviation: the third axis is
**TRIMP**, not kcal. Effort beats energy as a comparable axis
across endurance + strength sessions, and TRIMP is already what
CTL/ATL build on, so no new data source was needed.

Sport-mix bars are now switchable between **distance** (km,
default), **duration** (active minutes — visible for gym/strength
too) and **TRIMP** (Banister, requires HR + duration > 10 min).
Exposed via `plot_sport_mix(metric=)`, MCP `get_sport_mix(metric=)`,
and a radio-buttons row on the Sport-mix Shiny page.

## 2026-05-11 — Utveckling-fliken visar full historik igen

Roadmap bug "Shiny Utveckling-fliken: full historik visas inte"
closed (PR #13). The page presents historical comparisons (April
over the years, monthly trend vs previous years, etc.) but was
wired to the global 12-month date preset, so the comparisons
silently collapsed to one or two recent years.

`page_progress_server()` now ignores the global `dates` reactive
for its month/year/pace panels — they receive `summaries` and
`sport` only, so the report/plot helpers see `from = NULL, to =
NULL` and `filter_by_daterange()` returns the data unchanged. The
"Datumperiod" card at the bottom keeps its own dateRangeInput for
ad-hoc range queries.

## 2026-05-11 — Daily totals for high-volume health metrics

Roadmap item "Daily pre-aggregation for high-volume metrics"
closed (PR #11) with a hybrid approach: keep raw intra-day
samples on disk, but stamp every canonical file for a sum-metric
with a precomputed `daily_total` so the R reader never has to
parse 1000+ samples just to get the day's total.

`active_energy` and `walking_running_distance` join
`.import_metrics` — they used to be excluded because parsing was
too expensive. Older canonical files lacking `daily_total`
continue to work via the existing parse-then-aggregate path; both
produce the same value.

## 2026-05-11 — Service hardening + Caddy ingress

Off-roadmap but landed alongside the Phase 5d work. Tailscale-only
binds on `traning-receiver` (100.x.x.x:8421) and `traning-vayu`
(100.x.x.x:8422); `traning-shiny` bound to loopback (127.0.0.1:8423)
and exposed publicly only through Caddy at `traning.niemi.cc`. Env
vars in `/etc/traning/env` drive all three units so the same
templates work across hosts. Documented in
`docs/user/pipeline-setup.md`.

## 2026-05-11 — Vayu MCP plot pipeline (file race + image spec)

Two roadmap items closed together:

- "Vayu plot returns 'Plot file not found'" (PR #10). R's
  `tempfile()` lived under the subprocess's per-process tempdir,
  which was wiped on exit before Python could read the PNG.
  Python now owns `<tempdir>/vayu_plots_uid<uid>/` with `0o700`
  perms + symlink-refuse + age-based GC; the path is passed to R
  via `--plot_path`. TOCTOU on the dir is handled with
  `mkdir(exist_ok=False)` + `lstat()` re-validation; the
  resolution is `os.getuid()`-based so the path is locale- and
  USER-env-immune.
- "Vayu plots invisible in OpenClaw webchat" (PR #12,
  1B-followup). `r_plot()` used to return a bespoke
  `{type: "plot", base64, …}` dict that spec-compliant MCP clients
  silently dropped. It now returns a `fastmcp.utilities.types.Image`,
  which FastMCP serialises to the standard
  `{type: "image", data, mimeType}` ImageContent.

## 2026-04-08 — MCP transport: SSH stdio → persistent SSE

Roadmap item "MCP transport: SSH → SSE over Tailscale" closed out
(commit `af3cbac`). Vayu now runs as a persistent SSE server
(`http://kailash:8422/sse`) instead of SSH stdio. `--sse` flag in
`python/traning_cli/mcp/server.py:67` selects the transport; host/port
come from `VAYU_HOST` / `VAYU_PORT` env vars. The systemd unit
`traning-vayu.service` launches `vayu --sse` directly, so each Claude
Code MCP call avoids the SSH handshake + R session startup cost.

Stdio mode remains available locally (default when `--sse` is absent)
but is no longer wired into a systemd unit; the SSE path has been
production-stable since April.

## 2026-05-07 — Per-sport training load (CTL/ATL/TSB)

Roadmap item "Per-sport CTL overlay" closed out as part of the
multi-sport refactor. `compute_pmc()` and `compute_trimp()` in
`R/advanced_metrics.R` accept a `sport=` parameter (single sport or
bucket name), returning CTL/ATL/TSB series isolated to the selected
sport. The MCP tool `get_training_load(sport=<bucket>)`
(`python/traning_cli/mcp/tools.py:126`) exposes the same view; default
remains `running` for backwards compatibility.

The companion plot `plot_sport_ctl_overlay()` is documented separately
under "Multi-sport visualisations" below.

## 2026-05-07 — Multi-sport Shiny dashboard

Final piece of the sport-agnostic refactor. The tRanat dashboard now
has a global sport selector in the header that propagates into every
metric panel, plus a new **Sport-mix** tab that visualises activity
across sports.

- **Global sport selector** (header). Choices group "Direkta sporter"
  (running, cycling, walking, swimming, strength, badminton,
  bordtennis, övrigt) and "Sammansatta" (curated buckets: endurance,
  ballsport, gym, wintersport, all). The selected value is forwarded
  to all metric panels (PMC, ACWR, EF, HRE, decoupling, HR-zones,
  recovery HR, etc.) so the same dashboard now answers questions for
  any sport — not just running.
- **Sport-mix tab.** Three new cards built on `plot_sport_mix()`,
  `plot_sport_ctl_overlay()`, and `plot_sport_calendar()`. The CTL
  overlay's checkbox row is derived from the active bucket so
  selecting `gym`/`ballsport`/`wintersport` exposes the bucket's
  actual member sports; selecting `all` exposes the sports actually
  present in the data (capped at 12 most common).
- **Decoupling pace gate is now sport-aware.** Both
  `compute_decoupling()` and `load_decoupling()` resolve
  `max_pace_min_km` through a shared helper: 5.0 (running easy-pace),
  1.5 (cycling), 6.0 (walking), 15.0 (swimming), and disabled (0) for
  multi-sport selections where a single min/km cutoff doesn't fit.
  Previous default of 5.0 silently filtered out nearly every cycling
  or `all`-bucket session.
- **New public helpers** for UI/integration code:
  `traning::filter_sport()`, `sport_bucket_names()`, `sport_label()`,
  `sport_bucket_members()`. Replaces triple-colon access into
  `.SPORT_BUCKETS`/`.sport_label_sv` from app/MCP code.

## 2026-05-07 — Multi-sport visualisations

Three new plot families in `R/plot_multisport.R`, also exposed via
Vayu (`get_sport_mix`, `get_sport_ctl_overlay`, `get_sport_calendar`)
and the Shiny app:

- **`plot_sport_mix()`** — stacked bar of distance per period (week /
  month / year) × sport. Curated buckets and `all` aggregate
  consistently with the rest of the toolchain.
- **`plot_sport_ctl_overlay()`** — cross-sport CTL trajectories on a
  shared axis so cycling vs running fitness can be compared directly.
- **`plot_sport_calendar()`** — daily activity-calendar heatmap
  coloured by sport. Locale-independent (`%u` ISO weekdays) so
  rendering is identical on macOS dev and the Arch Linux Shiny host.

## 2026-05-07 — `--sport=` flag on CLI

Both the R CLI (`Rscript inst/cli.R`) and the Python CLI (`traning
report …`, `traning datesum`, etc.) accept `--sport=` to scope every
metric report to a single sport, a Swedish alias (`cykling`,
`löpning`, `gång`), or a curated bucket (`endurance`, `ballsport`,
`gym`, `wintersport`, `all`). Default remains `running` for
backwards compatibility — every existing invocation behaves as
before.

## 2026-05-07 — Sport-aware notifications

The daily readiness prose now surfaces actual training activity, not
just the health components. Two new lines may follow the existing
"Drar ner / OK"-block:

- **`Senaste dygnet: …`** — per-sport distance summary for the 24h
  window from the rendered date 00:00 UTC through the following
  midnight. Shown whenever any sport totals ≥ 0.1 km; sports without
  recorded distance (gym/strength) are silently dropped.  Example:
  `Senaste dygnet: löpning 13 km, gång 3.0 km.`
- **`Vecka: …`** (Sun) / **`Förra veckan: …`** (Mon) — ISO-week recap.
  - 1 sport: `Vecka: 32 km löpning. -5 km mot förra veckan.`
  - 2 sports: `Vecka: 45 km (löpning 30, cykling 15). +8 km mot förra veckan.`
  - 3+ sports: `Förra veckan: 102 km över 3 sporter (cykling 54, löpning 32, gång 17). -17 km mot förra veckan.`

Both lines are silent when there's nothing useful to say (no recent
activity, off-day for the weekly recap, all-zero week). Distances
render with one decimal under 10 km and as integers from 10 km up.

Set `TRANING_NOTIFY_SPORT=false` in `.Renviron` to suppress both lines
(default is on). Existing prose (`Dagsform`, `Drar ner`, `OK`) is
unchanged regardless of the setting, so iPhone push and Shiny
rendering remain backwards compatible.

## 2026-04-25 — Notification noise reduction

Trim push notifications to the signals that carry information:
- **Workouts** are saved silently. The receipt push (`Workouts: N
  mottagna`) was pure ack noise; the downstream health delta is the
  actual signal.
- **Garmin chain** collapses into a single combined notification per
  fetch. Was: trigger ack + import line + insight (3 pushes per run);
  now: insight only for single-pass batches, "Import: N pass …"
  prefixed for multi-pass batches.
- **Health pushes** are debounced. Multiple HAE batches arriving within
  `TRANING_HEALTH_DEBOUNCE` seconds (default 600) collapse into one
  import and at most one notification. An empty delta produces no
  notification (the old `"X filer importerade ✅"` fallback is gone).
- **Pass-only metrics** (cardio recovery, ground contact, power, speed,
  stride length, vertical oscillation) are no longer surfaced in the
  daily health delta — they belong to a per-session insight that does
  not yet exist. Labels/units are kept for that future use.
- Error notifications (import MISSLYCKADES, timeouts) are unchanged.

## 2026-04-09 — Delta-based health insights, notification logging

### Delta-based health insights
- Health insight notifications now report **only what changed** in the
  specific push, compared against a 7-day rolling average. Previously
  the same HRV/sleep/resting HR values were repeated every push.
- Three-tier metric classification:
  - **Tier 1 (always report):** VO2max, SpO2, cardio recovery,
    respiratory rate, running biomechanics (stride, ground contact,
    power, vertical oscillation), wrist temperature.
  - **Tier 2 (report if significant):** HRV (>=5 ms vs 7d), resting HR
    (>=4 bpm vs 7d), sleep total (>=30 min vs 7d or <5h30), deep sleep
    (>=18 min vs 7d).
  - **Tier 3 (ignore):** steps, active energy, flights climbed, heart
    rate min/avg/max, nutritional metrics, etc.
- Unknown metrics default to tier 1 (always report).
- Import + insight merged into a single atomic R process — eliminates
  the race where the insight script couldn't see pre-import state.
- Concurrent health pushes serialized via threading lock.

### Never-silent notifications
- The system **always** sends a notification after health import,
  regardless of outcome. Fallback messages for: no meaningful changes,
  import failure, timeout.
- Previously, insight R script failures were silently swallowed.

### Notification log
- All notifications (sent and failed) logged to
  `$TRANING_DATA/logs/notifications.jsonl` (JSONL, one line per event).
- Fields: timestamp, trigger type, title, message, sent status, error.
- Covers all notify points: health push, workout, garmin trigger,
  import, insight.

### Import performance
- Health import now only parses metrics that are actually consumed by
  R functions, reports, and MCP tools (~19 metrics). High-volume but
  unused metrics (active_energy, basal_energy_burned, etc.) are skipped
  — reducing import time from ~60s to ~5s on kailash.
- Canonical files remain on disk; add metric to `.import_metrics` and
  run `--import-health --force` to include.

### Withings backfill, HAE hostname fix

### Backfill from external exports
- New `traning backfill <zipfile>` CLI command: auto-detects archive
  type and writes canonical per-day JSON files for missing dates.
- First supported format: Withings data export (weight, body fat %,
  lean body mass). Extensible dispatcher for future formats.
- Backfilled 597 canonical files from Withings export (2012–2026),
  filling the HAE gap (2025-03 → 2026-04) and adding early data.

### HAE TCP host
- Default `HAE_HOST` changed from hardcoded LAN IP to Tailscale
  hostname, making TCP fetch work regardless of network.

---

## 2026-04-08 — Adaptive plot granularity, notification improvements

### Notification logging
- App-level logging now reaches systemd journal (`logging.basicConfig`
  in server `__init__.py`). Previously only uvicorn access logs were
  visible.
- `notify.py` logs full notification text: title + message on both
  success and failure.

### Notification quality
- **Import message:** now shows count, date range and total km
  ("Import: 1 pass (08 apr), 6.4 km totalt") instead of contextless
  "Distance: 169.83km total; 33.97km on average".
- **Garmin insight:** removed TRIMP (meaningless without context).
  Keeps km, pace, HR, and monthly comparison.
- **Health insight:** only shows metrics present in the import. Missing
  values are omitted entirely instead of showing "?".
- **Timeout:** `--import-health` now unlimited (background task, was
  600s and timed out after deploy). `--import` (garmin) set to 300s.
  Elapsed time logged as watchdog.

### Notification debugging docs
- New section in `docs/dev/pipeline-design.md`: ordered checklist of
  where to look (journal → HA log → HA logbook → data repo → iPhone).
- Updated troubleshooting in `docs/user/pipeline-setup.md` with
  concrete commands for each source.

### Plots adapt to date range
All time-series plots now respond to the span between `from` and `to`:
- **Short spans (< 60 days):** larger points, no loess smoother, no
  rolling average, angled date labels, daily/weekly aggregation
- **Medium spans (2–12 months):** weekly aggregation for zones,
  rolling averages shown, moderate loess span
- **Long spans (> 1 year):** monthly aggregation, sparse tick marks,
  small points with full smoothing

Affected plots: EF, HRE, decoupling, recovery HR, PMC, resting HR,
HRV, sleep stages, zone distribution, polarization index.

Shared helpers in `plot.R`: `.compute_span_days()`,
`.adaptive_date_scale()`, `.adaptive_datetime_scale()`,
`.filter_date_range()`.

### Test fixes
- Wrapped expected-warning calls in `expect_warning()` /
  `suppressWarnings()` (decoupling, MCP bridge)
- Set `HR_MAX` envvar in PMC test to avoid missing-envvar warning
- Test suite: 319 PASS, 0 WARN

---

## 2026-04-07 — Import correctness, notifications, cache portability

### trackeRdataSummary fix (root cause)
- **Root cause found:** `dplyr::mutate()` on a `trackeRdataSummary`
  object triggers the class's broken `[` method, expanding 1 row to 28
  (one per column). Same trackeR version (1.6.1) on both machines — the
  issue is the class, not the version.
- **Fix:** Strip `trackeRdataSummary` class immediately after
  `summary()` in `get_new_workouts()`, before any dplyr operations.
  Combined with the existing strip in `my_dbs_load()`, summaries are
  always plain data.frames.
- **Summaries sorted on save:** `my_dbs_save()` now sorts by
  `sessionStart` before writing. Gconnect files (T-format names) were
  sorted by filename, not chronologically.

### Push notifications (3-step pipeline)
Each data receive now triggers three notifications:
1. **Receive:** "Hälsodata: N metrics mottagna" / "Garmin fetch: ..."
2. **Import:** "Import garmin/hälsa: ..." (success or failure)
3. **Insight:** session summary or health snapshot

Garmin insight example:
  `Löpning 8.1 km, 5:00/km, puls 141, TRIMP 63. Snabbare än månadens snitt (5:07).`

Health insight example:
  `Hälsa 2026-04-07: vila 64 bpm, HRV 107 ms, sömn 6.2 h`

Insight always ends on a positive note: faster → longer → monthly total.

### HA automation
- Strava trigger now filters out `unavailable` and `unknown` states,
  preventing spurious Garmin fetches on sensor reconnect.

### Cache portability (kedar → kailash)
- `summaries.RData` is portable between machines: `get_new_workouts()`
  matches on `basename()`, not full paths. Copying kedar's cache to
  kailash lets it skip all known files and only import new ones.
- Verified: 4491 files matched as "Redan inläst", 1 new file imported
  (seconds instead of hours).

### Other
- `DESCRIPTION`: author email added

---

## 2026-04-06 — Pipeline and deploy fixes

### Import pipeline
- **Auto-import after data receive:** R import now runs automatically
  after every Garmin fetch (webhook + timer) and HAE data push (health +
  workouts). Previously, raw data was fetched but never parsed into
  RData cache on kailash.
- **Batch checkpoints:** `get_new_workouts()` saves cache every 500
  files during import, preventing data loss on crash. Critical for
  first-time imports (~4500 files).
- **Fixed NULL assignment crash:** `myruns[[i]] <- NULL` silently does
  nothing in R (NULL removes list elements), causing subscript-out-of-bounds
  on next access. Now uses intermediate variable.
- **Fixed empty summaries on first import:** `basename(summaries$file)`
  crashed when summaries had no `file` column (fresh install).
- **Stripped `trackeRdataSummary` class on load:** trackeR's `[` method
  expects exactly 6 columns, breaking all dplyr operations. Converted
  to plain `data.frame` at load time.

### Deploy (`deploy.sh`)
- **R dependency install:** `deploy.sh code` now runs
  `scripts/install_r_deps.sh` after Python deps. Script reads
  DESCRIPTION, checks pacman (Arch) first, falls back to CRAN with
  parallel compilation.
- **`.Renviron` generation:** Now includes `R_LIBS_USER=~/R/library`
  (user library for R packages not in system library) and
  `LANG=sv_SE.utf8` (prevents encoding warnings for Swedish column
  names).

### New files
- `scripts/install_r_deps.sh` — R dependency installer with
  pacman-first strategy and `--check` dry-run mode

---

## 2026-04-06 — Phase 5c: Vayu MCP server

### MCP server (`python/traning_cli/mcp/`)
- **Vayu** — FastMCP server exposing tRäning as 15 MCP tools for Claude
- Transport: stdio (Claude Code / Claude Desktop)
- Entry points: `vayu` command and `traning mcp`
- R bridge (`inst/mcp_bridge.R`): function dispatch with whitelisted
  functions, conditional data loading, JSON/PNG output
- Python bridge (`r_bridge.py`): subprocess helpers with input validation
  (control char stripping, date format validation, timeout clamping)
- Standardized response envelope: `{schema_version, summary, details, _meta}`

### Tools (15)
- **Health & Readiness:** `get_readiness`, `get_sleep`, `get_hrv`
- **Training Load:** `get_training_load` (PMC/ACWR/monotony),
  `get_efficiency` (EF/HRE), `get_zones` (Seiler 3-zone + PI)
- **Sessions:** `get_sessions`, `get_monthly_summary`, `get_yearly_summary`
- **Trends:** `get_decoupling`, `get_recovery_hr`, `get_resting_hr`,
  `get_vo2max`
- **Comparison:** `compare_periods` (two date ranges side by side)
- **Reference:** `explain_metric` (definitions, thresholds, references)
- All tools support `after`/`before` date filtering and `plot=True`
  for PNG chart output (base64-encoded)

### Resources
- `vayu://metrics` — available metrics with descriptions
- `vayu://thresholds` — reference thresholds for all metrics

### Prompts (Swedish)
- `daglig_check` — daily readiness + recent sessions + recommendation
- `veckoutvardering` — weekly volume, intensity balance, trends
- `konditionsbedomning` — 3-month fitness assessment (EF, CTL, zones)

### Dependencies
- `fastmcp>=2.0` added to `pyproject.toml`

### Tests
- 317 tests total (was 292), all passing
- New `test-mcp-bridge.R` (25 tests): function whitelist, data/plot
  output modes, date filtering, error handling

---

## 2026-05-11 — Service hardening for kailash ingress

### Deployment defaults (`python/traning_cli/server/deploy/`)
- `traning-shiny.service` now reads `TRANING_SHINY_HOST` /
  `TRANING_SHINY_PORT` from `/etc/traning/env` so the dashboard can stay on
  loopback behind a reverse proxy.
- `traning-receiver.service` now reads `TRANING_RECEIVER_HOST` /
  `TRANING_RECEIVER_PORT` from `/etc/traning/env` instead of binding to
  `0.0.0.0`.
- `traning-vayu.service` now relies on `VAYU_HOST` / `VAYU_PORT` from the env
  file rather than hardcoding a public bind in the unit.
- `traning-env.example` documents the kailash default: Shiny on loopback,
  receiver + Vayu on the Tailscale IP.

### Operations docs
- `docs/user/pipeline-setup.md` now points Health Auto Export and ad-hoc curls
  at kailash's Tailscale IP for the receiver.
- `docs/roadmap.md` gained an ingress-hardening item so the deployment model is
  explicit in the repo, not only in host-local config.

---

## 2026-04-06 — Phase 5b: Automated health and training data pipeline

### FastAPI receiver (`python/traning_cli/server/`)
- `POST /v1/health` — accepts HAE health metrics JSON, saves one file per
  metric to `health_export/metrics/` using same `{metric}_{first}_{last}.json`
  naming as TCP pipeline. Compatible with R-side manifest-based import.
- `POST /v1/workouts` — accepts HAE workout JSON, saves one file per workout
  to `health_export/workouts/` as `{name}-{timestamp}.json`
- `POST /v1/trigger/garmin` — triggers Garmin Connect fetch in background.
  Used by Home Assistant automation (HA runs in Docker, cannot call host binaries)
- `GET /v1/status` — uptime, last received, total pushes
- `GET /health` — healthcheck
- API key authentication on all `/v1/` endpoints (`X-API-Key` header)
- HA push notifications on data receipt via `notify.mobile_app_anandavani`
- Git commits only when data actually changed (`git diff --cached --quiet`):
  repeated HAE pushes with identical data produce no extra commits

### CLI commands (`python/traning_cli/main.py`)
- `traning serve` — start FastAPI receiver (default port 8421)
- `traning pull` — git pull data repo from GitHub remote
- All `sync` commands auto-pull from remote before fetching when configured

### Deployment infrastructure (`python/traning_cli/server/deploy/`)
- `deploy.sh` with subcommands: `code`, `secrets`, `tokens`, `status`, `all`
  - `code` — git pull on kailash + pip install + copy systemd units + restart
  - `secrets` — SCP credentials to /etc/traning/env, generate .Renviron
  - `tokens` — SCP Garmin auth tokens from kedar to kailash
  - `status` — systemctl status + journalctl tail
- Credentials never committed: `traning-env.local` gitignored, deployed via SCP
- Garmin auth done on kedar (browser-based), tokens SCP'd (~1 year validity)

### Systemd services on kailash (Arch Linux)
- `traning-receiver.service` — FastAPI on :8421 (auto-start at boot,
  restart on failure)
- `traning-garmin.timer` — fallback fetch every 2h, 06–22 (primary trigger
  is Strava webhook via HA)
- `traning-push.timer` — daily git push to GitHub at 03:00

### Strava → Home Assistant → Garmin fetch
- `ha_strava` HACS integration installed, connected to Strava account
- `sensor.strava_kristian_niemi_recent_activity` updates on each new activity
- HA automation triggers `rest_command.traning_fetch_garmin` which POSTs
  to `localhost:8421/v1/trigger/garmin` — works because HA container
  uses host networking
- HA sends push notification to anandavani on trigger
- Chain: Garmin watch → Garmin Connect → Strava → ha_strava → HA automation
  → FastAPI → `traning fetch garmin`

### Data sync
- Private GitHub repo (`krissen/traning-data`) for sync between kailash and kedar
- Deploy keys (no passphrase) for passwordless push/pull on kailash:
  `github-data` alias for traning-data, `github-code` for traning repo
- HAE (Health Auto Export) iOS app pushes health data automatically to kailash
- `traning pull` on kedar fetches kailash's data via GitHub

### Dependencies
- `fastapi>=0.100` and `uvicorn[standard]>=0.20` added to `pyproject.toml`

---

## 2026-04-06 — Phase 4g: Aerobic decoupling

### Aerobic decoupling metric (`R/advanced_metrics.R`)
- `compute_decoupling()` — compares pace:HR efficiency between first and
  second half of a run to quantify cardiac drift
- Time-based processing: warmup exclusion, smoothing window and midpoint
  split all use the `time` column, not row indices — critical because
  older Garmin devices (pre-2017) log at 3–7 second intervals
- Steady-state filter (`max_half_speed_diff_pct = 10`): rejects sessions
  where mean speed differs >10% between halves. Without this, pacing
  artefacts (warm-up progression, fartlek, negative splits) produce large
  spurious negative values. Empirically retains ~79% of sessions while
  eliminating virtually all extreme outliers
- Threshold bands: <3% well-coupled, 3–5% acceptable, 5–8% moderate
  drift, >8% significant aerobic limitation
- `load_decoupling()` — incremental RData cache with parameter-aware
  invalidation (duration, pace, warmup, smoothing, steady-state threshold)
- 534 qualifying sessions from 2005–2026

### HR data repair (`R/import.R`)
- `repair_myruns_hr()` — finds sessions where summaries has avgHR > 0
  but myruns per-second HR is all NA/zero, and re-parses the original
  TCX file. Root cause: older trackeR version silently dropped HR data
  during import for certain TCX format variants, despite the raw files
  being intact
- `--repair-hr` CLI flag
- Recovered 358 sessions (2007–2020), bringing per-second HR coverage
  from 3554 to 3904 running sessions

### Plot fix (`R/plot.R`)
- Fixed `xlim` crash when only `--after` or only `--before` is specified
  (was `c(from, NULL)` → length 1; now `c(from %||% NA, to %||% NA)`)
- Affects all plot functions with `from`/`to` parameters

### Visualization (`R/plot.R`)
- `fetch.plot.decoupling()` — two-panel faceted chart:
  upper panel: scatter + loess + 28-day rolling mean + threshold bands;
  lower panel: weekly km bars for volume context

### Report (`R/report.R`)
- `report_decoupling()` with columns: Datum, Km, Tempo, HR,
  Dekopp %, Dekopp 28d, Temp

### CLI
- R CLI: `--decoupling` flag with `--force` for cache bypass
- Python CLI: `traning decoupling [--plot] [--force] [--after/--before]`

### Tests
- 292 tests total (was 259), all passing
- New `test-decoupling.R` (33 tests): known decoupling values, zero/negative
  decoupling, sport/duration/pace filters, steady-state filter, NULL/missing
  data handling, temperature annotation, report formatting, cache roundtrip

---

## 2026-04-06 — Refactor: Unified report function signatures

### Unified `(summaries, n, from, to)` signature (`R/report.R`)
- All 6 basic report functions now accept `n`, `from`, `to` parameters:
  `report_monthtop`, `report_monthstatus`, `report_monthlast`,
  `report_yearstop`, `report_yearstatus`, `report_runs_year_month`
- New `.filter_input()` helper filters raw summaries by `from`/`to`
  on `sessionStart`, reusing `filter_by_daterange()` from `R/daterange.R`
- `report_runs_year_month` no longer uses `do_year`/`do_month` — replaced
  by `from`/`to` with default=current month
- `report_monthlast` `print()` side effect removed

### `--limit` on all commands (`inst/cli.R`)
- All basic report commands now support `--limit` (`report_monthstatus`,
  `report_monthlast`, `report_yearstop`, `report_yearstatus`,
  `report_runs_year_month` — `report_monthtop` already had it)
- `summaries_filtered` pre-filter variable removed — each function
  handles its own filtering via `from`/`to`
- `--total-pace` uses inline `filter_by_daterange()` call

### Plot pass-through (`R/plot_reports.R`)
- All 6 plot functions accept and forward `from`/`to` to their report functions
- `plot_runs_month` no longer uses `do_year`/`do_month`

### Shiny app (`app/tRanat/server.R`)
- 12 call sites (6 report + 6 plot) switched from `summaries_f()` to
  `summaries` + `from`/`to` from global date preset
- `summaries_f()` kept for pace tab only

### Tests
- 259 tests total (was 223), all passing
- New `test-report-basic.R` (38 tests): signature validation, `n` limiting,
  `from`/`to` filtering, descending sort, no side effects

---

## 2026-04-06 — Remove Phase 4h (FIT & Polar import) from roadmap

Data audit confirmed that all 2 093 FIT files (2012–2020) are already
covered by corresponding TCX files (~1:1 per year). The 265 SRD files
(2004–2006) were previously converted to TCX (in `tcx/srd-import/`).
Cache covers 4 619 activities from 2004-12-31 to 2026-04-05 — no gaps.
FIT/SRD import adds no new data; phase removed.

## 2026-04-06 — Phase 4f: HR zone distribution & polarization index

### Zone computation (`R/hr_zones.R`)
- Seiler 3-zone model: Z1 (low, <VT1), Z2 (threshold, VT1–VT2),
  Z3 (high, ≥VT2) with configurable thresholds (default 80%/90% HRmax)
- Two data sources with hybrid fallback:
  - Per-second HR classification from myruns (2932 sessions, 2004–2022)
  - Garmin JSON hrTimeInZone fallback for sessions without per-second
    data (317 sessions, 2023+)
- Treff (2019) Polarization Index: PI = log₁₀((Z1/Z2) × Z3 × 100)
  with edge-case handling (Z2=0 uses Eq. 2, Z3=0 → PI=0)
  - PI > 2.0 = polarized, PI ≤ 2.0 = non-polarized
- Cross-validation function comparing Garmin device zones vs per-second
- Incremental cache (`zone_distribution.RData`): first run ~8s for
  4500 sessions, subsequent runs ~2s; caches both computed and skipped
  sessions; `--force` clears cache

### Time-varying HRmax (`R/physiology.R`)
- `get_hr_max_at(date)` returns per-date HRmax that declines with age
- Priority: BIRTH_YEAR env + Tanaka formula (208 − 0.7 × age), then
  linear fit of yearly 98th percentile from garmin_maxHR, then fallback
- Zone thresholds now per-session: a 2004 run (HRmax 192) gets different
  VT1/VT2 than a 2026 run (HRmax 176)
- `BIRTH_YEAR` added to `.Renviron` / `.Renviron.example`

### Visualizations (`R/plot_zones.R`)
- `fetch.plot.hr_zones()` — stacked bar chart (monthly zone distribution)
  with 80% Z1 target line; auto-scaling x-axis for 1–20+ year spans
- `fetch.plot.polarization()` — PI trend with polarized/non-polarized bands
- `fetch.plot.zone_comparison()` — scatter cross-validation (Garmin vs
  per-second) with identity line and deviation coloring

### CLI
- R CLI: `--hr-zones` flag (table or `--plot`)
- Python CLI: `traning zones [--plot] [--force] [--after/--before]`

### Report sorting
- All `report_*()` tables now sort newest first (descending chronological)
- Applies to all 15 report commands via `.tail_or_daterange()` and
  individual `arrange(desc())` calls

### Tests
- 223 tests total (was 174), all passing
- New `test-hr-zones.R` (49 tests): zone distribution, PI formula with
  Treff 2019 reference values, report formatting, edge cases

---

## 2026-04-06 — Phase 5a+: Health import performance

### Incremental health import (`R/health_export.R`)
- File manifest (`health_import_manifest.json`) tracks mtime and size per
  imported JSON file in `$TRANING_DATA/cache/`
- `import_health_export()` compares files against manifest and only parses
  new or modified files — skips unchanged ones entirely
- Typical incremental import: 2–3 new files instead of 120+
- `--force` flag bypasses manifest and re-imports everything
- Manifest updated atomically after successful cache save

### CLI updates
- R CLI: new `--force` flag on `--import-health`
- Python CLI: `traning import health --force`, `traning sync health --force`

### Tests
- 174 tests total (was 159), all passing
- New manifest tests: new file detection, unchanged skip, modified detection,
  roundtrip save/load, force bypass

---

## 0.4.0 — Apple Watch integration & readiness model

### Apple Watch health data pipeline (`R/health_export.R`)
- New module parses Health Auto Export (HAE) iOS app JSON exports
- Handles 3 data formats: standard qty, heart rate Min/Avg/Max, nested sleep
- Source filtering: removes Garmin Connect contamination from resting HR
  (Connect reports ~100 bpm vs Apple Watch ~50 bpm; HAE averages them)
- Raw sleep segment parser: 96K+ segments across 13 years from 6+ sources
  (Sleep Cycle, Apple Watch, Oura, AutoSleep, etc.), with per-night source
  selection (prefers AW staging), segment deduplication, and overlap-safe
  aggregation
- Daily aggregation for non-aggregated exports (sum for steps/energy,
  mean for physiological metrics, min/max for heart rate)
- Cache I/O: `load_health_data()` / `save_health_data()` → `health_daily.RData`
- Convenience: `pivot_health_wide()`, `get_readiness()` with Ln(RMSSD)

### Data backfill
- TCP backfill script (`python/backfill_tcp.py`) queries HAE TCP server on
  iPhone in 3-month chunks, saves per-metric JSON files
- 117K rows, 91 metrics, 2013–2026 imported:
  - Sleep: 4471 nights (2013+), Resting HR: 2976 days (2017+),
    HRV: 2934 days (2017+), VO2max: 2204 days (2017+),
    Cardio recovery: 858 days (2022+), plus step count, active energy,
    walking metrics, body composition, running mechanics, etc.
- Known gaps: 2023-06 → 2024-03 and 2025-03 → 2025-12 (missing from HealthKit)

### Health visualizations (`R/plot_health.R`)
- `fetch.plot.resting_hr()` — 9-year trend with LOESS + annual means
- `fetch.plot.hrv()` — Ln(RMSSD) with 7-day rolling baseline ± 1 SD band
- `fetch.plot.sleep()` — total sleep LOESS + monthly stage breakdown
  (kärnsömn/REM/djupsömn/vaken) with 7h target line
- `fetch.plot.vo2max()` — Apple Watch VO2max estimate trend

### Readiness model (`R/readiness.R`)
- `compute_readiness()` — daily composite score (0–100) fusing Apple Watch
  health data with Garmin training load
- Four components via piecewise-linear scoring:
  - HRV (35%): Ln(RMSSD) z-score vs 7-day rolling baseline
  - Sleep (30%): total hours + staging quality bonus/penalty
  - Resting HR (20%): deviation from 30-day rolling baseline
  - Training load (15%): previous day's TRIMP ratio to ATL
- NA-aware weight redistribution when components are missing
- Warning flags: HRV suppression (z < -1), sustained RHR elevation
  (>5 bpm for 3+ consecutive days), poor sleep + suppressed HRV,
  acute load spike (>2× ATL)
- Traffic-light status: Grön (≥70), Gul (40–69), Röd (<40)
- Data quality tracking: full/partial/minimal
- `fetch.plot.readiness_score()` — 4-panel patchwork dashboard:
  score with zone bands, HRV with baseline ribbon + flag markers,
  sleep bars with flag coloring, ATL/CTL lines + TRIMP bars
- Based on Seshadri 2019, Plews 2013, Buchheit 2014, Simpson 2017

### Shiny app updates
- New top-level "Readiness" tab with integrated 4-panel dashboard + table
- New "Hälsa" menu with Vilopuls, HRV, Sömn, VO2max tabs
- Health data loaded at startup via `load_health_data()` in global.R
- Readiness dashboard uses renderPlot (patchwork incompatible with plotly)

### CLI updates
- `--readiness` — daily readiness table or 4-panel dashboard (with `--plot`)
- `--import-health` — import Apple Watch health data from HAE JSON files
- Supports `--after`/`--before`/`--limit` for date filtering
- `patchwork` added to Suggests in DESCRIPTION

### Tests
- 159 tests total (was 93), all passing
- New `test-health-export.R` (28 tests): parser formats, source cleaning,
  aggregation, pivot, readiness accessor
- New `test-readiness.R` (66 tests): piecewise scoring, component scores,
  weighted composite, consecutive flag, integration tests

---

## 0.3.0 — Unified output system

### Consistent table/plot toggle for all commands
- All 14 report commands now support both table and plot output via `--plot`
- Advanced metrics (EF, HRE, ACWR, monotony, PMC, recovery HR) previously
  plot-only — now default to table output like all other commands
- New `report_ef()`, `report_hre()`, `report_acwr()`, `report_monotony()`,
  `report_pmc()`, `report_recovery_hr()` functions in `R/report.R`
- `report_monthtop()` now accepts `n` parameter (was hardcoded to 10)
- `--limit` flag to control table row count on any command

### File output with format support
- `--output FILE` saves output to file (both plots and tables)
- `--format` for explicit format: plots (`pdf`, `png`), tables (`csv`,
  `json`, `jsonl`, `xlsx`)
- Default save location: `$TRANING_DATA/output/plots/` and
  `$TRANING_DATA/output/tables/` with timestamped filenames
- `--no-open` suppresses auto-opening of saved files (open is default)
- `save_plot()` and `save_table()` helpers in `R/utils.R`
- JSONL output in preparation for MCP server integration

### Configurable defaults via environment
- `TRANING_OUTPUT_DIR` — base directory for saved output
- `TRANING_PLOT_FORMAT` — default plot format (default: pdf)
- `TRANING_TABLE_FORMAT` — default table format (default: csv)
- `TRANING_OPEN` — auto-open after save (default: true)

### Date filtering fix for time-series metrics
- ACWR, monotony, PMC, EF, HRE, recovery HR now receive full unfiltered
  data for computation; date range applied to the output only
- Previously, `--after`/`--before` pre-filtered input data, corrupting
  rolling-window calculations at boundaries
- Time-series plot functions accept `from`/`to` parameters that override
  the `days=365` default

### Python CLI updates
- All commands forward `--output`, `--format`, `--no-open`, `--limit`
- Advanced metric commands now respect `--plot` toggle (was hardcoded to
  always-plot)

### Shiny app rebuilt from scratch
- `global.R` — data loading at startup with Garmin JSON augmentation
- `ui.R` — `navbarPage` with 5 sections: Månad (4 tabs), År (2 tabs),
  Tempo, Datumperiod (with date picker), Avancerat (6 tabs)
- `server.R` — all 14 report types with both plot and table output
- Each tab shows plot + interactive DT table simultaneously
- Recovery HR gracefully handles missing Garmin data

### Tests
- 65 tests total (was 36), all passing
- New `test-report-advanced.R` covering all 6 advanced report functions,
  `save_plot()`, and `save_table()` (CSV, JSON, JSONL)

---

## 2026-04-05 — Phase 4e: Literature-driven metric expansion

### Data pipeline: Garmin JSON integration (`R/garmin_json.R`)
- New module reads 4398 Garmin JSON file pairs (summary + details)
- Handles both old format (summaryDTO-nested, pre-late-2024) and new format
  (flat top-level keys)
- `import_garmin_json()` — batch-reads all JSON, extracts maxHR,
  hrTimeInZone_1..5, vO2MaxValue, recoveryHeartRate, directWorkoutRpe,
  averageTemperature, minHR
- `augment_summaries()` — joins Garmin JSON fields to summaries via
  timestamp matching (±120 s tolerance)
- Added `jsonlite` to DESCRIPTION Imports

### Physiological configuration (`R/physiology.R`)
- `import_resting_hr()` — parses Apple Watch resting HR CSV
  (2431 daily observations, 2017-09 to 2024-10); filters out Garmin
  "Connect" entries and physiological outliers
- `get_hr_max()` — four-level priority: HR_MAX env → 98th percentile of
  Garmin maxHR → Tanaka formula → 185 bpm fallback
- `get_hr_rest(date)` — time-varying resting HR from Apple Watch data
  (backward-looking 30-day rolling mean); falls back to HR_REST env or
  50 bpm for dates outside AW coverage
- `save_resting_hr()` / `load_resting_hr()` — RData cache

### New metric: HRE — Heart Rate Efficiency (`R/advanced_metrics.R`)
- `compute_hre()` — avgHR × avgPace = beats/km (Votyakov et al. 2025)
- Filter: running, >5 km, HR > 0; 28-day rolling mean
- Votyakov thresholds: <700 well-fitted, 700-750 fitted, >800 poorly-fitted
- `fetch.plot.hre()` — scatter + rolling mean + threshold bands
- CLI: `traning hre`

### New metric: TRIMP / CTL / ATL / TSB — Performance Management Chart
- `compute_trimp()` — Banister bTRIMP per session (Morton 1990 formula)
  with time-varying HRrest from Apple Watch data
- `compute_pmc()` — daily CTL (42-day EWMA), ATL (7-day EWMA),
  TSB = CTL - ATL (Murray 2017 EWMA method)
- `fetch.plot.pmc()` — three-panel chart: fitness/fatigue lines, TSB zone
  bars (with coaching heuristic caveat), daily TRIMP bars
- CLI: `traning pmc --after -1y`

### New metric: Recovery Heart Rate
- `compute_recovery_hr()` — extracts post-workout recovery HR from enriched
  summaries (520 activities, Nov 2023+), 28-day rolling mean
- `fetch.plot.recovery_hr()` — scatter + rolling mean trend
- CLI: `traning recovery-hr`

### ACWR corrections (literature-driven)
- Fixed underloading threshold 0.5 → 0.8 (Hulin 2016)
- Added uncoupled ACWR as dashed grey line on plot (Impellizzeri 2020:
  coupled variant systematically dampens spikes)
- Added `weekly_pct_change` column (Nielsen 2014: >30% = injury risk)

### EF improvements (literature-driven)
- Refactored `fetch.plot.ef()` to dual-panel chart with weekly km bars
  below (volume context, per Votyakov 2025 recommendation)

### CLI updates
- R CLI: new `--hre`, `--pmc`, `--recovery-hr` flags
- Python CLI: new `traning hre`, `traning pmc`, `traning recovery-hr`
  commands

---

## 2026-04-05 — Phase 4d: Evidence-based primer rework

All 6 research themes rewritten with actual literature findings:
1. Continuous Wearable Data (6 papers)
2. Cardiac Drift & Decoupling (5 papers)
3. Pace-HR Efficiency (6 papers)
4. HR Zone Distribution (7 papers)
5. Volume Periodization / ACWR (9 papers)
6. Training Load / TRIMP (12 papers)

Tracking: `research/_analys/PROGRESS.md` (all items complete).

---

## 2026-04-05 — Phase 4c: Flexible date ranges & plot variants

### Date range system (`R/daterange.R`)
- New `--after`, `--before`, `--span` flags on all report and plot commands
- Flexible date expressions: absolute (`2023`, `2023-03`, `2023-03-04`) and
  relative (`-3w`, `-1y`, `-6m`, `-10d`)
- `--span` for windowed queries: `--after -1y --span 3m` = 3-month window
  starting 1 year ago
- Legacy `--datesum YYYY-MM-DD--YYYY-MM-DD` format still works
- Pre-filters summaries upstream — existing report functions unchanged

### Plot variants for all table commands (`R/plot_reports.R`)
- New `--plot` flag switches table output to a chart
- `plot_monthtop()` — horizontal bar chart, colored by year
- `plot_runs_month()` — lollipop chart with pace color scale
- `plot_monthstatus()` — year-comparison bar chart for current month
- `plot_monthlast()` — year-comparison bar chart for last month
- `plot_yearstatus()` — year-to-date bar chart
- `plot_yearstop()` — full-year totals bar chart
- `plot_datesum()` — auto-aggregated bars (daily/weekly/monthly by span)
- Shared `.plot_year_bars()` helper for consistent styling
- `--total-pace --plot` wires to existing `fetch.plot.mean.pace()`

### Python CLI updates (`python/traning_cli/main.py`)
- Shared `report_options` decorator adds `--plot`/`--after`/`--before`/`--span`
  to all report commands
- `_r_report()` helper eliminates per-command boilerplate
- Plot commands (`ef`, `acwr`, `monotony`) also accept date range flags

### Tests
- `tests/testthat/test-daterange.R` — 15 test cases for parsing, range building,
  and filtering

---

## 2026-04-05 — Phase 4b: Unified CLI

- Single `traning` command replacing `Rscript inst/cli.R` and `python garmin_fetch.py`
- Python Click CLI dispatcher (`python/traning_cli/main.py`)
  - `traning fetch` — Garmin Connect fetch (pure Python, calls garmin modules directly)
  - `traning import` — TCX → RData cache (delegates to R)
  - `traning update` — fetch + import in one step
  - `traning report {month,year,pace,top,month-top,month-this,month-last}` — reports
  - `traning ef`, `traning acwr`, `traning monotony` — plot commands
  - `traning datesum RANGE` — date range summary
  - `traning shiny` — launch tRanat Shiny app
- Garmin modules restructured: `python/garmin_*.py` → `python/traning_cli/garmin/`
  - Proper Python package with relative imports
  - Path resolution updated for new directory depth
- `pyproject.toml` with `console_scripts` entry point (`pip install -e .`)
- `setup_venv.sh` updated to install CLI automatically
- Same pattern as bifrost CLI

## 2026-04-04 — Phase 4: Knowledge base & advanced metrics

### Knowledge base
- Literature search across 6 topics: training load (TRIMP), cardiac drift,
  HR zone distribution, pace-HR efficiency, volume periodization, wearable data
- 50 papers ingested in Vyasa, checked out as symlinks in `sources/`
- 6 analysis primers in `research/_analys/` with formulas, thresholds, and
  implementation guidance
- Analysis spec with prioritized implementation order in
  `research/_decisions/analysis-spec.md`
- Garmin Connect JSON field catalogue in `research/_decisions/garmin-json-fields.md`
  — discovered `hrTimeInZone_1..5`, `directWorkoutRpe`, `recoveryHeartRate`,
  `vO2MaxValue`, and `averageTemperature` fields

### Advanced metrics (`R/advanced_metrics.R`)
- `compute_efficiency_factor()` — pace:HR ratio per run + 28-day rolling mean
- `compute_acwr()` — acute:chronic workload ratio (coupled + uncoupled)
- `compute_monotony_strain()` — Foster's training monotony and strain indices
- All three use summaries data only (no per-second data needed)

### Visualizations (`R/plot.R`)
- `fetch.plot.ef()` — EF scatter + loess + rolling mean trend
- `fetch.plot.acwr()` — dual-panel ACWR zones + weekly km bars
- `fetch.plot.monotony()` — dual-panel monotony + strain
- CLI flags: `--ef`, `--acwr`, `--monotony`

### Import fixes (`R/import.R`)
- Fix trackeR 1.6.1 unit converter bug (`.onLoad()` copies all converters)
- Match files by basename to handle relative vs absolute path mismatch
- Improved error handling with actual error messages in Swedish
- Fix `report_mostrecent()` NA total distance (`na.rm = TRUE`)

## 2026-04-04 — Phase 3: Garmin data fetching

- Added Python-based Garmin Connect fetcher (`python/`)
  - `garmin_fetch.py` — CLI with `--limit`, `--all`, `--dry-run`, `--reauth`, `--login-method`
  - `garmin_auth.py` — Auth via pirate-garmin (browser login, DI tokens ~1 year)
  - `garmin_download.py` — Activity download (summary JSON, details JSON, TCX)
  - `garmin_utils.py` — Naming conventions matching existing gconnect/ format
- Authentication: pirate-garmin handles post-Cloudflare Garmin auth (mobile SSO + DI OAuth)
  - `--login-method browser` (default): pirate-garmin browser login
  - `--login-method native`: garminconnect TLS impersonation (fallback)
  - Credentials from `.Renviron` (GARMIN_EMAIL/GARMIN_PASSWORD) or interactive prompt
- `requirements.txt` (garminconnect, pirate-garmin, requests) and `setup_venv.sh`
- Symlinks in `tcx/` created automatically (relative paths, same convention as bulk export)
- Incremental fetching: scans existing files, only downloads new activities
- Auto-commits new activities to data repo after fetch
- Rate limiting with exponential backoff for Garmin API
- Documentation: `docs/user/` (setup + usage), `docs/dev/` (design)
- Added test bootstrap (`tests/testthat.R`) and smoke test for `dec_to_mmss()`

## 2026-04-03 — Phase 2: R package structure

- Restructured project as an R package (`DESCRIPTION`, `NAMESPACE`, `R/`)
- Split `read_my_fit.r` (747 lines) into 5 domain modules:
  - `R/utils.R` — `dec_to_mmss()`
  - `R/metrics.R` — `add_my_columns()`, `fix_zero_moving()`
  - `R/import.R` — data I/O functions (`my_dbs_load`, `get_new_workouts`, etc.)
  - `R/report.R` — all 8 `report_*` functions
  - `R/plot.R` — all 4 plot/data functions
- Created thin CLI wrapper at `inst/cli.R` (replaces `r/read_my_fit.r`)
- Fixed global variable leaks: `get_new_workouts(verbose=)`, `report_mostrecent(n_imported=)`
- Moved `r/` → `scripts/` (standalone scripts) and `r/tRanat/` → `app/tRanat/`
- Removed personal training graphs (PNG) from git tracking
- Consolidated `.Renviron` to project root
- All functions namespace-qualified (`dplyr::filter`, `ggplot2::ggplot`, etc.)

## 2026-04-03 — Phase 1: Externalize data

- Training data now lives in a separate repo (`~/Documents/traning-data/`)
- Data paths configured via `TRANING_DATA` env var in `.Renviron`
  - Updated `r/read_my_fit.r`, `r/gor_sa_har.r`, `r_aw/aw_heartrate.r`
  - Added `.Renviron.example` templates in `r/` and `r_aw/`
- Created public GitHub repo: https://github.com/krissen/traning
