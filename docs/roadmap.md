# tRäning — Roadmap

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
