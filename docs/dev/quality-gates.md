# Quality gates

This repo is gated by [`prek`](https://github.com/j178/prek) (a faster,
Rust reimplementation of `pre-commit`), configured in
`.pre-commit-config.yaml`. R hooks use whatever `Rscript`/`styler`/`lintr`
are already on `PATH`, plus the R packages `pkgload` (required by
`.hooks/lintr.R` to load the package before linting — see below) and
`devtools` (required by `.hooks/testthat.R`); both hooks fail fast with
a clear message, rather than silently misbehaving, if either is
missing: `install.packages(c("pkgload", "devtools"))`. `make setup`
(below) installs `pkgload`, `devtools`, `lintr` and `styler` for you.

## Turning it on

`make setup` (`scripts/setup.sh`) bootstraps everything below in one
step: a pinned, persistently-installed `prek`, a `gitleaks` presence/
version check, `python/.venv` (via `python/setup_venv.sh`), and the four
R packages the local hooks need. Which of the two paths it takes for
wiring the actual git hook depends on `core.hooksPath`:

**(a) Plain clone** (no `core.hooksPath` set) — `make setup` runs
`prek install` **and** `prek install --hook-type pre-push`. Both are
needed: every hook in `.pre-commit-config.yaml` is pinned to
`stages: [pre-commit]` except `testthat`, which is pinned to
`stages: [pre-push]` (see that file's header comment) — the pre-commit
shim alone would select zero hooks for `git push` and testthat would
silently never run.

**(b) Maintainer machine** with a global git hook dispatcher
(`~/.config/git/hooks/_dispatch`, `core.hooksPath` set repo-wide) — this
clone's own `.git/hooks` never runs, so `make setup` skips the wiring
step and instead prints a reminder to opt this repo into the dispatcher:

```sh
git config prek.enabled true
```

The dispatcher runs `prek run` at commit time only when this is `true`
**and** `.pre-commit-config.yaml` exists (it already does here). This
setting is repo-local git config, not a tracked file — a fresh clone on
another machine needs to run it again. The dispatcher drives both
stages itself (`prek run --hook-stage pre-commit` /
`--hook-stage pre-push`), so `testthat` (pre-push) also runs under path
(b) once `prek.enabled` is `true` — no separate wiring step needed.

## Escape hatches

The escape hatch depends on which path above wired the hook — they are
not interchangeable:

| situation | path (a): plain clone, `prek install` | path (b): dispatcher (`core.hooksPath`) |
|---|---|---|
| skip one or more hooks for one commit | `SKIP=<hook-id,...> git commit ...` (or `PREK_SKIP=<hook-id,...>`) | `SKIP_PREK=1 git commit ...` (skips the whole sweep, keeps the AI-attribution check) |
| skip everything, including attribution | `git commit --no-verify` (last resort, both paths) | `git commit --no-verify` (last resort, both paths) |
| turn the gate off for this repo | uninstall the hook (`rm .git/hooks/pre-commit .git/hooks/pre-push`, or reinstall later with `make setup`) | `git config prek.enabled false` |

`SKIP_PREK=1` is read by the dispatcher itself and has no effect on a
plain `prek install` hook (path a) — it only checks `SKIP`/`PREK_SKIP`,
which prek defines natively. Conversely, `SKIP=<hook-id>` also works
under the dispatcher (prek still honours its own env var once invoked),
but `SKIP_PREK=1` does nothing under path (a) since there is no
dispatcher to read it.

## What runs

- **gitleaks** — secret scanning (staged diff only; CI additionally
  sweeps the whole tree with `gitleaks dir .`, since a clean checkout
  has nothing staged).
- **ruff** (`ruff-check --fix`, `ruff-format`) — Python lint/format,
  `[tool.ruff]` in `pyproject.toml`.
- **pre-commit-hooks** — YAML/JSON syntax, added-file size (`--maxkb=1000`),
  end-of-file/trailing-whitespace hygiene.
- **shellcheck** / **shfmt** — the five shell scripts under `scripts/` and
  `python/`.
- **actionlint** — GitHub Actions workflow files.
- **parsable-R**, **styler**, **lintr** — local (`language: system`)
  hooks against the system's own R install, not
  `lorenzwalthert/precommit`: that hook's renv lockfile does not build
  on R ≥ 4.5 on this machine. `lintr` runs `pkgload::load_all()` first
  so `utils::globalVariables()` (`R/traning-package.R`) is honoured —
  without it, every dplyr/ggplot2 column name shows up as an undefined
  global. `app/tRanat/.lintr` scopes `object_usage_linter` off just for
  the Shiny app directory (lintr can't resolve its cross-module,
  runtime-sourced function calls); the root `.lintr` pins
  `cyclocomp_linter` at 125, just above the current worst offender —
  that threshold ratchets down as functions get broken up, it isn't a
  statement that 125 is fine.
- **testthat** — the full R test suite, at **pre-push**, not
  pre-commit (`always_run: true`, no `files:` filter — too slow to run
  on every commit; a `git push` runs it once for the whole batch of
  commits being pushed). **Decision (2026-09-09): no R job in GitHub
  CI** — see below. **Known risk, not yet fixed:** if your `TRANING_DATA`
  points at a real, live data directory (the normal daily-use setup),
  `git push` now runs the full suite against it, and a few tests write
  cache files under `$TRANING_DATA/cache` as a side effect — see
  krissen/traning#91.

CI (`.github/workflows/ci.yml`) runs the same `prek` configuration via
`pipx run --spec prek==0.5.2 prek run --all-files`, skipping the three
non-test R hooks (`SKIP=parsable-R,style-files,lintr` — the runner has
no R toolchain), plus a full-tree `gitleaks dir .` and `pytest`.
**`testthat` does not run in CI.** DESCRIPTION lists ~29 CRAN
dependencies (`ggplot2`, `dplyr`, `shiny`, `plotly`, `DT`, and others);
installing and caching that on GitHub Actions is the same class of cost
the portfolio already moved bifrost's R job to GitLab to avoid (see
design.md). Rather than repeat that decision per repo, testthat runs
locally at `git push` instead (the `testthat` pre-push hook above, and
in `make check`) — a push cannot land without the suite passing on the
pusher's machine, even though GitHub Actions never sees it.

CI's `test` job pins `uv` itself (`astral-sh/setup-uv@v3`'s `version:
"0.12.12"`) and runs `uv sync --locked` — not `--frozen` — so a
dependency change without a matching `uv lock` fails CI instead of
silently installing a stale environment. Because `--locked` is that
strict, `uv.lock` must be regenerated with a `uv` version at least as
new as the one pinned above — an older `uv` (this repo hit it with
0.5.8) writes a lockfile missing the `revision` field a newer `uv`
expects, which fails `--locked` even though no dependency actually
changed.

## `make check`

Runs locally before commit/PR: `prek run --all-files`, a full-tree
`gitleaks dir .`, `ruff check .` **without** `--fix` (prek's own
`--fix` hook would otherwise silently clean up and pass a newly
created, still-untracked file with nothing staged to compare against),
`pytest`, and `testthat` (same as the pre-push hook — running it here
too catches a broken test before you even get to `git push`). Full
output goes to `.check.log` (gitignored, see `.gitignore`); a green run
prints one line, a red one prints the log.

```sh
make check
```

## `.git-blame-ignore-revs`

Mechanical, comment-only diffs (ruff autofix/format, styler, shfmt) are
listed in `.git-blame-ignore-revs` so `git blame` skips past them to the
commit that actually changed the line. Enable it once per clone:

```sh
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

If this branch is squash-merged rather than merged with a merge commit,
the SHAs in that file point at commits that no longer exist on the
default branch and need to be remapped to the squashed equivalents (or
dropped).
