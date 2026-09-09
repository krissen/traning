# Quality gates

This repo is gated by [`prek`](https://github.com/j178/prek) (a faster,
Rust reimplementation of `pre-commit`), configured in
`.pre-commit-config.yaml` and run automatically by the machine-global git
hook dispatcher (`~/.config/git/hooks/_dispatch`) — nothing to install
per clone beyond what the dispatcher already expects (`prek`, `gitleaks`,
`shellcheck`, `shfmt`; R hooks use whatever `Rscript`/`styler`/`lintr` are
already on `PATH`).

## Turning it on

Two things, both in the repo root:

```sh
git config prek.enabled true
```

The dispatcher runs `prek run` at commit time only when this is `true`
**and** `.pre-commit-config.yaml` exists (it already does here). This
setting is repo-local git config, not a tracked file — a fresh clone on
another machine needs to run it again.

## Escape hatches

| situation | command |
|---|---|
| skip prek for one commit, keep the AI-attribution check | `SKIP_PREK=1 git commit ...` |
| skip everything, including attribution | `git commit --no-verify` (last resort) |
| turn the gate off for this repo | `git config prek.enabled false` |

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
  global. `.lintr` excludes `app/tRanat/` (a Shiny script directory, not
  part of the package — lintr can't resolve its cross-module sourcing)
  and pins `cyclocomp_linter` at 125, just above the current worst
  offender; that threshold ratchets down as functions get broken up,
  it isn't a statement that 125 is fine.

CI (`.github/workflows/ci.yml`) runs the same `prek` configuration via
`pipx run --spec prek==0.5.2 prek run --all-files`, skipping the three R
hooks (`SKIP=parsable-R,style-files,lintr` — the runner has no R
toolchain), plus a full-tree `gitleaks dir .` and `pytest`. **`testthat`
is not run in CI yet** — see the ORDER 1 rollout report for the
CRAN-dependency-count estimate that decision rests on.

## `make check`

Runs locally before commit/PR: `prek run --all-files`, a full-tree
`gitleaks dir .`, `ruff check .` **without** `--fix` (prek's own
`--fix` hook would otherwise silently clean up and pass a newly
created, still-untracked file with nothing staged to compare against),
`pytest`, and `testthat`. Full output goes to `.check.log` (gitignored,
see `.gitignore`); a green run prints one line, a red one prints the
log.

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
