#!/usr/bin/env bash
# install_r_deps.sh — Install R dependencies for the tRäning package.
#
# On Arch Linux, tries pacman first (binary, fast), then falls back to
# install.packages() for anything pacman doesn't have.
# On other systems, goes straight to install.packages().
#
# Usage:
#   bash scripts/install_r_deps.sh          # install missing only
#   bash scripts/install_r_deps.sh --check  # dry run, list status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# --- Parse dependencies from DESCRIPTION via R ---
DEPS=$(Rscript -e '
desc <- read.dcf("'"$REPO_ROOT/DESCRIPTION"'")
parse <- function(f) {
  raw <- desc[1, f]; if (is.na(raw)) return(character(0))
  sub("\\s*\\(.*\\)", "", trimws(unlist(strsplit(raw, ","))))
}
imports <- parse("Imports")
server_suggests <- c("devtools", "patchwork")
suggests <- intersect(parse("Suggests"), server_suggests)
cat(paste(unique(c(imports, suggests)), collapse = "\n"))
')

# --- Check what is missing ---
MISSING=$(Rscript -e '
deps <- readLines(stdin())
installed <- rownames(installed.packages())
missing <- setdiff(deps, installed)
cat(paste(missing, collapse = "\n"))
' <<< "$DEPS")

INSTALLED_COUNT=$(echo "$DEPS" | wc -l | tr -d ' ')
if [ -z "$MISSING" ]; then
    MISSING_COUNT=0
else
    MISSING_COUNT=$(echo "$MISSING" | wc -l | tr -d ' ')
fi

echo "R dependency status for tRäning"
echo "================================"
echo "  Total:     $INSTALLED_COUNT"
echo "  Missing:   $MISSING_COUNT"
if [ -n "$MISSING" ]; then
    echo "  Packages:  $(echo "$MISSING" | tr '\n' ', ' | sed 's/,$//')"
fi

if $CHECK_ONLY || [ -z "$MISSING" ]; then
    [ -z "$MISSING" ] && echo "All dependencies installed."
    exit 0
fi

# --- Install ---
# Map R package names to Arch pacman names (lowercase, r- prefix)
arch_pkg_name() {
    local pkg="$1"
    # Some R packages have different Arch names
    case "$pkg" in
        Rcpp)       echo "r-rcpp" ;;
        *)          echo "r-$(echo "$pkg" | tr '[:upper:]' '[:lower:]')" ;;
    esac
}

PACMAN_PKGS=""
CRAN_PKGS=""

if command -v pacman &>/dev/null; then
    echo ""
    echo "Arch Linux detected — trying pacman first..."
    for pkg in $MISSING; do
        arch_name=$(arch_pkg_name "$pkg")
        if pacman -Si "$arch_name" &>/dev/null; then
            PACMAN_PKGS="$PACMAN_PKGS $arch_name"
        else
            CRAN_PKGS="$CRAN_PKGS $pkg"
        fi
    done

    if [ -n "$PACMAN_PKGS" ]; then
        echo "  pacman: $PACMAN_PKGS"
        sudo pacman -S --needed --noconfirm $PACMAN_PKGS
    fi
else
    CRAN_PKGS="$MISSING"
fi

# Fall back to CRAN for packages not in pacman
if [ -n "$(echo "$CRAN_PKGS" | tr -d ' ')" ]; then
    echo ""
    echo "Installing from CRAN: $CRAN_PKGS"
    # Ensure user library exists
    Rscript -e '
    lib <- Sys.getenv("R_LIBS_USER", unset = file.path(Sys.getenv("HOME"), "R", "library"))
    if (!dir.exists(lib)) dir.create(lib, recursive = TRUE)
    pkgs <- commandArgs(trailingOnly = TRUE)
    ncpus <- min(parallel::detectCores(), 4)
    install.packages(pkgs, lib = lib, repos = "https://cloud.r-project.org", Ncpus = ncpus)
    ' $CRAN_PKGS
fi

# --- Verify ---
echo ""
STILL_MISSING=$(Rscript -e '
deps <- readLines(stdin())
missing <- setdiff(deps, rownames(installed.packages()))
cat(paste(missing, collapse = "\n"))
' <<< "$(echo "$MISSING")")

if [ -n "$STILL_MISSING" ]; then
    echo "FAILED to install: $STILL_MISSING"
    exit 1
else
    echo "All dependencies installed successfully."
fi
