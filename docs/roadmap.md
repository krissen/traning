# tRäning — Roadmap

> **Omfattning:** Framtida arbete (pipeline/produkt samt AUR-paketering).
> Levererade ändringar dokumenteras i `docs/changelog.md`.

## Pipeline: HAE-hämtning och övervakning

Uppföljningsspår från vilopuls-incidenten aug 2026
(`docs/dev/incidents/2026-08-07-resting-hr-export-gap.md`) och
MCP-backfillen 2026-08-10.

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
- **Per-metrik-staleness-larm i `traning doctor`.** Enskilda metriker kan
  tyst falla ur HAE:s automatiska pushar (vilopuls aug 2026) utan att någon
  freshness-check reagerar; okända/utblivna metriker filtreras dessutom tyst
  av `.import_metrics`-vitlistan (loggas bara vid `verbose=TRUE`).

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
