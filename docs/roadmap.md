# tRäning — Roadmap

> **Omfattning:** Framtida arbete (pipeline/produkt samt AUR-paketering).
> Levererade ändringar dokumenteras i `docs/changelog.md`.

## Alkohol: uppföljning

Alkoholstödet är levererat (se `docs/changelog.md`). Det som medvetet
lämnades utanför, och det som måste göras för att siffrorna ska bli
tillförlitliga.

- **Driftsteg efter merge.** Tre saker, i den ordningen. Kör
  `Rscript inst/cli.R --import-health --force` på kailash, så att
  `alcohol_consumption` och `basal_energy_burned` kommer in i cachen och
  `alcohol_nights.RData` skrivs för första gången. Kör sedan
  `deploy.sh code`. Starta till sist om vayu: den varma R-servern läser
  `inst/mcp_bridge_shared.R` vid uppstart, så `get_alcohol` finns inte
  förrän den startats om.
- **Uppskattad total dryckesenergi (nivå 2).** Var struken för att
  indata saknades. De finns: DrinkControl skriver `foodType` per
  energipost (`beer, 660ml 5,0%`), alltså typ, volym och halt per glas i
  en oaggregerad export. Kvar av invändningen är bredden på skattningen,
  inte avsaknaden av indata, så en siffra ska redovisas som intervall och
  aldrig som punkt. Kräver en parser för fritextsträngen (decimalkomma,
  gemena kategorinamn) med fallback för okända kategorier, plus
  restenergi per kategori. Se beslut 2 i designdokumentet.
- **Dryckestyp i notis och rapport.** Följdfråga till nivå 2, men
  billigare: `foodType` räcker för att säga *vad* som dracks utan att
  skatta någon energi. Produktbeslut om det tillför något utöver mängden.
- **Loggningstid som tidsmarkör.** `foodType`-fyndet visade att
  tidsstämpeln är loggningstid, inte exporttid. Grosicki et al. (2026)
  gör drickstiden till en av få åtgärdbara variabler, men en kväll som
  loggas vid läggdags får alla glas på samma sekund. Innan något byggs på
  detta måste avståndet mellan loggningstid och drickstid kvantifieras.
- **Dos-responsanalysen.** Specificerad i designdokumentets avsnitt
  "Future: dose-response", ingen kod skriven. Veckodagsmatchad jämförelse,
  inte en enkel regression mot dagsformen, eftersom drickskvällar och allt
  annat som påverkar morgonen efter klumpar ihop sig på fredagar och
  lördagar. Stoppregel: under ungefär 30 registrerade kvällar redovisas
  bara beskrivande siffror och ingen effektskattning, och ingenting som
  låter generellt får vila på den enkla alkoholfria baslinjen.
- **Shiny-panel i tRanat.** Inte byggd. Notisen är den yta som betyder
  något för den här funktionen, och en panel är meningsfull först när det
  finns mer än några veckors historik att visa.
- **R-testsviten skriver i den riktiga datakatalogen.** `devtools::test()`
  skriver om `decoupling.RData` och `zone_distribution.RData` i den cache
  `TRANING_DATA` pekar på, alltså användarens levande katalog vid en
  vanlig körning på kedar. Beteendet är förbefintligt och båda filerna är
  regenererbara, och sviten ger samma utfall mot en kopia som mot den
  riktiga katalogen, så inget test hänger på det verkliga innehållet. Men
  en testsvit ska inte röra produktionsdata. Egen PR: peka testerna på en
  temporär katalog, eller låt de berörda testerna sätta `TRANING_DATA`
  själva. Tills dess: kör sviten med `TRANING_DATA` pekad på en kopia.
- **Avvikande glasenhet i notistexten.** Produktbeslut. Ändras
  inställningen i DrinkControl skriver notisen standardglas härledda ur ett
  värde som inte längre gäller, utan att antyda det. Flaggan finns redan i
  rapportkolumnen `Avvikande enhet` och i importmeddelandet, så frågan är
  om den också ska sägas rakt ut i prosan eller om det vore en rad som
  sällan gäller och alltid oroar.

## Pipeline: HAE-hämtning och övervakning

Uppföljningsspår från vilopuls-incidenten aug 2026
(`docs/dev/incidents/2026-08-07-resting-hr-export-gap.md`),
MCP-backfillen 2026-08-10, och bortfallsincidenten för dygnssammanfattnings-
metriker aug-sep 2026 (`docs/dev/incidents/2026-08-10-daily-summary-metrics-dropout.md`).

- **Per-metrik-staleness-larm i `traning doctor`.** Enskilda metriker kan
  tyst falla ur HAE:s automatiska pushar utan att någon freshness-check
  reagerar. Detta är nu det andra dokumenterade fallet på en månad
  (vilopuls aug 2026, dygnssammanfattningsmetriker aug-sep 2026) och båda
  gick oupptäckta tills något nedströms gick sönder. Okända/utblivna
  metriker filtreras dessutom tyst av `.import_metrics`-vitlistan (loggas
  bara vid `verbose=TRUE`). Prioriterad.
- **Upstream-issue till `Lybron/health-auto-export`: automationsurval kan
  nollställas vid uppdatering.** Enligt dygnssammanfattningsincidenten
  (`docs/dev/incidents/2026-08-10-daily-summary-metrics-dropout.md`)
  nollställde/utökade en app-uppdatering troligen automationens egna
  metrikurval (från "alla" till "19 valda") utan att meddela användaren,
  skilt från appens globala exporturval som manuell export läser. Ej
  postad; kräver verifiering av App Store-uppdateringshistorik runt
  2026-08-09 innan issuen skrivs.
- **Bevakningspunkt 2026-08-12: "Idag"-fönstrets täckning.** Automationens
  exportfönster står på "Idag" som workaround för
  `Lybron/health-auto-export#61`. Verifiera att retroaktivt skrivna
  gårdagsmetriker (särskilt sömn) fortfarande anländer; annars backfill och
  omprövat fönsterval.
- **HTTP/MCP-läge i hälsohämtningsklienten.** HAE:s HTTP- och TCP-serverlägen
  är ömsesidigt uteslutande; `hae_client.py`/`fetch_tcp` talar enbart det
  gamla rå-TCP-protokollet och får 0 bytes mot en HTTP/MCP-server.
  MCP-servern (v1.1.0) autentiserar med `Authorization: Bearer <token>` från
  appens Server-skärm och exponerar `get_health_metrics(start, end, metrics,
  interval, aggregate)` m.fl. Fungerande prototyp: `~/hae_mcp_fetch.py` på
  kailash (stdlib-only, hanterar Mcp-Session-Id + SSE-svar).
- **`aggregate=false` som default vid HAE-hämtning.** `fetch_tcp` hårdkodar
  `aggregate=True`, vilket ger källblandade dygnsvärden (Apple Watch ~50 bpm
  medelvärdesbildad med Garmin Connect ~100+ till en enda rad) som
  `.connect_contaminated_metrics` inte kan rensa — filtret kräver separerade
  per-källa-samples. Inkluderar audit av historiskt TCP-hämtade
  vilopulsvärden i canonical.
- **Atomiska canonical-skrivningar.** `canonicalize_metric` i
  `server/storage.py` trunkerar och skriver om filen på plats, medan
  legacy-skrivaren bredvid använder temporär fil plus rename. En avbruten
  skrivning förlorar ett helt dygn och förgiftar varje senare läsning av
  det. Förbefintligt; egen commit mot master.

## AUR-paketering (pausad 2026-05-18)

Av 14 r-cran-paket i ursprungliga listan: 5 hanterade (r-tracker, r-bsicons,
r-viridislite, r-backports, r-lazyeval), 2 skippade (aktiva maintainers),
9 återstår. Infrastruktur klar — pausen är taktisk, inte teknisk.

### Verktyg och tracking

Privat repo: `github.com/krissen/aurbuild` (synkat på kailash i
`~/dev/aurbuild/`).

- `bin/aur-bootstrap <CRAN-name> [--preserve-from PKGBUILD]` — genererar
  PKGBUILD från CRAN DESCRIPTION; `--preserve-from` bevarar Contributor-rader
  vid adoption
- `bin/aur-bump <r-pkg> <ver>` — uppdaterar befintlig PKGBUILD till ny CRAN-version
- `bin/aur-vote-installed [--dry-run]` — batch-vote på installerade r-* AUR-paket
- `tracking/STATUS.md` — auto-genererad snapshot av AUR vs CRAN per paket;
  kör `tracking/verify.sh` för fräsch körning
- `tracking/WORKFLOW.md` — hand-maintained per-paket-strategi, gist-URLs,
  kommentar-mallar
- `tracking/correspondence/` — fri-text-loggar per paket (tom)

`.SRCINFO`-generering kräver `makepkg` → kör allt PKGBUILD-arbete på kailash.

### Återstår — Contact (2 paket)

Drafts + secret gists finns redan; nästa steg är att posta kommentar på
AUR-paketsidan med gist-länken (mall i `tracking/WORKFLOW.md`).

- `r-httr2` (maintainer: AlexBocken) — 1.2.1 → 1.2.2
- `r-ggstats` (maintainer: pekkarr) — 0.12.0 → 0.13.0

### Återstår — Stale med maintainer (7 paket)

Batchade per maintainer för att undvika 3 separata kommentarer till samma
person. För var och en: drafta PKGBUILDs (`aur-bootstrap --preserve-from`)
och skicka mjuk kommentar; eskalera till orphan-request efter 2 veckors
tystnad.

- **alhirzel** (3 paket): `r-uuid`, `r-selectr`, `r-rvest`
- **Alad** (2 paket): `r-dbplyr`, `r-haven`
- **christoslongros**: `r-getopt`
- **pekkarr**: `r-optparse` (samma maintainer som `r-ggstats` ovan — slå ihop kommunikation)

### Skippade (aktiva maintainers)

- `r-data.table` (rafaelff, kontinuerligt uppdaterad)
- `r-s7` (serene-arc)

### Återuppta spåret

1. Kör `tracking/verify.sh` för fresh AUR/CRAN-snapshot
2. Läs `tracking/WORKFLOW.md` för kommentar-mall + strategi
3. För contact-paket: posta kommentar på AUR (manuell user-action)
4. För stale-paket: bootstrap drafts, skapa gists, posta kommentarer
5. När maintainer responderar eller 2 veckors-frist passerar: orphan-request
   eller direktpush (se `aur-bootstrap --preserve-from`-flödet och
   r-viridislite/r-backports/r-lazyeval som referens)
