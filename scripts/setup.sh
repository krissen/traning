#!/bin/sh
# make setup -- one-command contributor bootstrap for the local quality gate.
#
# Adapted from narada-mcp's scripts/setup.sh (see docs/dev/quality-gates.md
# for the full rationale); differences from that reference are called out
# below where they matter.
#
# Resolving the pinned prek version always goes through `pipx run --spec
# prek==X.Y.Z` (or the uv equivalent), never a `prek` already on PATH --
# that removes the "wrong version" class of bug regardless of what else is
# installed or where it sits on PATH.
#
# Actually WIRING the hooks is different: `prek install` embeds the
# absolute path it was invoked from into the generated hook script, so
# pointing it at an ephemeral `pipx run`/`uv tool run` cache entry bakes a
# path into .git/hooks/pre-commit that can silently stop existing later
# (pipx documents its run-cache as pruned after as little as 14 days).
# Once pruned, every commit fails with a missing-executable error until
# `make setup` is re-run. So the pinned version is installed *persistently*
# (`pipx install --force` / `uv tool install --force`, not `run`) before
# `prek install` runs, so the embedded path survives.
#
# That persistent install happens UNCONDITIONALLY, before the
# core.hooksPath check below, even though hook wiring itself is skipped on
# a hooks_path clone: `make check` (Makefile) resolves prek from this
# persistent path or from PATH, never from the ephemeral function below,
# so a hooks_path machine with uv/pipx but no already-global `prek` still
# needs the persistent binary for `make check` to work.
#
# gitleaks has no such wrapper (a Go binary, not a Python package) and is
# still expected to be a real installed binary on PATH.
#
# core.hooksPath handling: a custom hooks path means this clone's own
# .git/hooks won't run -- on Kristian's own machines this routes through
# the maintainer-machine global dispatcher (~/.config/git/hooks/_dispatch,
# see docs/dev/quality-gates.md), which runs prek itself once
# `git config prek.enabled true` is set. Only the hook-WIRING step
# (`prek install`) is skipped in that case; the persistent install and the
# prek/gitleaks checks above all still run, and `make check` still works.
#
# Unlike narada-mcp, .pre-commit-config.yaml here pins testthat to
# `stages: [pre-push]` (the rest stay `stages: [pre-commit]`, see that
# file's header comment) -- so this script installs BOTH hook types,
# `prek install` and `prek install --hook-type pre-push`, instead of
# skipping the pre-push shim as a no-op.
#
# Idempotent: safe to re-run any time (e.g. after .github/workflows/ci.yml
# bumps the pinned prek version) -- `--force` re-pins the persistent
# install to whatever version is current.
set -eu
cd "$(dirname "$0")/.."

echo "make setup: bootstrapping the local quality gate"

# Single source of truth for the pinned version: the same
# `pipx run --spec prek==X.Y.Z` CI uses in .github/workflows/ci.yml.
prek_version=$(grep -o 'prek==[0-9][0-9.]*' .github/workflows/ci.yml | head -n1 | cut -d= -f3)
if [ -z "$prek_version" ]; then
  echo "could not read the pinned prek version from .github/workflows/ci.yml"
  exit 1
fi

if command -v pipx >/dev/null 2>&1; then
  # --backend pip: pipx's own uv-detection can pick an incompatible uv
  # already on PATH (from an unrelated toolchain) and refuse to run.
  # Older pipx (reported: 1.4.3) predates the --backend flag entirely
  # and errors out on it ("unrecognized arguments"), so only pass it
  # when this pipx's own --help advertises it.
  if pipx run --help 2>&1 | grep -q -- '--backend'; then
    pipx_backend_flag="--backend pip"
  else
    pipx_backend_flag=""
  fi
  # shellcheck disable=SC2086 # intentional word-splitting: empty when unsupported
  prek() { pipx run $pipx_backend_flag --spec "prek==$prek_version" prek "$@"; }
  backend="pipx"
elif command -v uv >/dev/null 2>&1; then
  prek() { uv tool run --from "prek==$prek_version" prek "$@"; }
  backend="uv"
else
  echo "missing: pipx or uv, needed to run the pinned prek==$prek_version"
  echo "without depending on whatever else might be on PATH. Install one:"
  echo "  https://pipx.pypa.io/stable/installation/"
  echo "  https://docs.astral.sh/uv/getting-started/installation/"
  exit 1
fi

echo "resolving prek==$prek_version ..."
prek --version

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "missing: gitleaks. Install it, e.g.:"
  echo "  brew install gitleaks"
  echo "or download a release: https://github.com/gitleaks/gitleaks/releases"
  exit 1
fi
# A legacy gitleaks (pre-v8 `detect`/`protect` CLI, no `dir` subcommand)
# would report success here and then fail later, at `gitleaks dir .` in
# `make check`, with an unknown-command error -- check for `dir`
# explicitly rather than just presence on PATH.
if ! gitleaks --help 2>&1 | grep -q '^ *dir '; then
  echo "installed gitleaks is too old (no 'dir' subcommand -- needs v8+):"
  echo "  $(gitleaks version 2>&1 | head -n1)"
  echo "Upgrade it, e.g.:"
  echo "  brew upgrade gitleaks"
  echo "or download a current release: https://github.com/gitleaks/gitleaks/releases"
  exit 1
fi
echo "gitleaks already installed ($(gitleaks version 2>&1 | head -n1))"

# Install the pinned version persistently -- unconditionally, even on a
# core.hooksPath clone that skips hook wiring below -- because `make
# check` (Makefile) only ever resolves prek from this exact persistent
# path or from a `prek` already on PATH; it never invokes the ephemeral
# `prek()` shell function above.
#
# Installed into a VERSION-SCOPED location, not pipx's/uv's shared "prek"
# app slot: that shared slot is a single global name, so a plain `pipx
# install --force prek==X`/`uv tool install --force prek` for one repo
# would silently overwrite the exact binary path already embedded in
# every other repo's hooks the moment that other repo pins a different
# prek version -- defeating the version pinning for whichever repo was
# set up first. Scoping the install directory by $prek_version means two
# repos pinning the same version safely share one binary, and two repos
# pinning different versions each get their own, never overwriting the
# other. `PIPX_HOME`/`PIPX_BIN_DIR` (pipx) and `UV_TOOL_DIR`/
# `UV_TOOL_BIN_DIR` (uv) redirect the install without touching either
# tool's shared/default namespace at all.
persist_root="$HOME/.local/state/traning-prek/$prek_version"
bin_dir="$persist_root/bin"
echo "installing prek==$prek_version persistently for make check ..."
if [ "$backend" = "pipx" ]; then
  # shellcheck disable=SC2086 # intentional word-splitting: empty when unsupported
  PIPX_HOME="$persist_root/pipx" PIPX_BIN_DIR="$bin_dir" \
    pipx install --force $pipx_backend_flag "prek==$prek_version"
else
  # `--from` is a `uv tool run` option, not a `uv tool install` one --
  # pass the pinned version as the package argument itself, which works
  # because the package name and the command it provides are both `prek`.
  UV_TOOL_DIR="$persist_root/uv-tools" UV_TOOL_BIN_DIR="$bin_dir" \
    uv tool install --force "prek==$prek_version"
fi
prek_bin="$bin_dir/prek"

if [ ! -x "$prek_bin" ]; then
  echo "installed prek==$prek_version but $prek_bin is missing or not"
  echo "executable -- add $bin_dir to PATH, then re-run 'make setup'."
  exit 1
fi

hooks_path=$(git config --get core.hooksPath 2>/dev/null || true)
if [ -n "$hooks_path" ]; then
  echo "core.hooksPath is set to '$hooks_path', so this clone's own"
  echo ".git/hooks won't run -- skipping hook installation ('prek install'"
  echo "would refuse anyway). If that path already runs prek for opted-in"
  echo "repos (the maintainer-machine convention), run:"
  echo "  git config prek.enabled true"
  echo "Otherwise wire prek into whatever '$hooks_path' runs yourself."
  echo "gitleaks and prek==$prek_version ($prek_bin) are both installed;"
  echo "'make check' works regardless."
else
  # From here on, use the resolved persistent binary directly (not the
  # ephemeral `prek` shell function defined above, and not a PATH
  # lookup) so the embedded hook path is the persistent one -- it
  # outlives pipx's/uv's ephemeral run-cache pruning (see the
  # top-of-file comment).
  "$prek_bin" install
  echo "OK: pre-commit hook installed from .pre-commit-config.yaml"
  # testthat is pinned to `stages: [pre-push]` (see
  # .pre-commit-config.yaml) -- a second, separate hook type has to be
  # installed for it to actually run; the pre-commit shim alone selects
  # zero pre-push hooks.
  "$prek_bin" install --hook-type pre-push
  echo "OK: pre-push hook installed (testthat)"
fi

# --- Python: python/.venv, via the existing setup script ---
if [ -x python/setup_venv.sh ] || [ -f python/setup_venv.sh ]; then
  echo ""
  echo "setting up python/.venv ..."
  bash python/setup_venv.sh
else
  echo "python/setup_venv.sh not found -- skipping Python venv setup"
fi

# --- R: packages the local hooks need (see .hooks/*.R, docs/dev/quality-gates.md) ---
# pkgload and devtools are also needed for lintr/testthat to load the
# package before linting/testing (see .hooks/lintr.R, .hooks/testthat.R);
# lintr and styler are the linting/formatting engines themselves. None of
# the four are package dependencies (not in DESCRIPTION Imports/Suggests
# except devtools, which is already there as a Suggests) -- they're
# dev-tool-only, so scripts/install_r_deps.sh (which reads DESCRIPTION)
# does not check them.
r_hook_deps="pkgload devtools lintr styler"
if command -v Rscript >/dev/null 2>&1; then
  echo ""
  echo "checking R packages required by the local hooks ($r_hook_deps) ..."
  missing_r=$(Rscript -e '
		deps <- strsplit(commandArgs(trailingOnly = TRUE), " ")[[1]]
		installed <- rownames(installed.packages())
		cat(paste(setdiff(deps, installed), collapse = " "))
	' "$r_hook_deps")
  if [ -n "$missing_r" ]; then
    echo "installing missing R packages: $missing_r"
    # shellcheck disable=SC2086 # intentional word-splitting: package list
    Rscript -e '
			pkgs <- strsplit(commandArgs(trailingOnly = TRUE), " ")[[1]]
			lib <- Sys.getenv("R_LIBS_USER", unset = file.path(Sys.getenv("HOME"), "R", "library"))
			if (!dir.exists(lib)) dir.create(lib, recursive = TRUE)
			install.packages(pkgs, lib = lib, repos = "https://cloud.r-project.org")
		' $missing_r
  else
    echo "all R hook dependencies already installed"
  fi
else
  echo "Rscript not on PATH -- skipping R hook dependency check (parsable-R,"
  echo "styler, lintr, testthat hooks will fail fast with a clear message"
  echo "until R is installed)"
fi

echo ""
echo "make setup: done. Run 'make check' any time to run the same gate CI"
echo "does, plus the R test suite."
