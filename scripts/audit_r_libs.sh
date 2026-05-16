#!/usr/bin/env bash
# audit_r_libs.sh — Audit R library state on Arch hosts.
#
# Reports three categories that became important after the 2026-05-14
# R 4.5→4.6 ABI incident on kailash:
#
#   system-orphan  — package directories in /usr/lib/R/library/ that
#                    pacman does not own. After the cleanup all packages
#                    in system-lib should be pacman-managed; orphans
#                    here usually mean a stray manual install.
#
#   user-duplicate — packages present in BOTH ~/R/library/ and the
#                    system-lib. user-lib comes first in .libPaths() so
#                    these shadow the pacman version. Remove them so
#                    pacman/AUR wins.
#
#   user-unique    — packages only in ~/R/library/. These are the
#                    legitimate CRAN-fallback packages (typically
#                    because no AUR equivalent exists, or the AUR
#                    version is out-of-date). Keep them; they need
#                    manual rebuild on R major bumps.
#
# Usage:
#   bash scripts/audit_r_libs.sh            # human-readable report
#   bash scripts/audit_r_libs.sh --summary  # counts only
#   bash scripts/audit_r_libs.sh --list <category>
#                                           # newline-separated names
#                                           # for the named category
#                                           # (system-orphan|user-duplicate|user-unique)

set -euo pipefail

SYSTEM_LIB="${R_SYSTEM_LIB:-/usr/lib/R/library}"
USER_LIB="${R_USER_LIB:-$HOME/R/library}"

MODE="report"
CATEGORY=""
case "${1:-}" in
  --summary) MODE="summary" ;;
  --list)    MODE="list"; CATEGORY="${2:-}" ;;
  "")        ;;
  *) echo "usage: $0 [--summary | --list <category>]" >&2; exit 2 ;;
esac

if ! command -v pacman >/dev/null 2>&1; then
  echo "audit_r_libs.sh requires pacman (Arch host)." >&2
  exit 3
fi
if [[ ! -d "$SYSTEM_LIB" ]]; then
  echo "system-lib not found: $SYSTEM_LIB" >&2
  exit 3
fi

# --- Gather sets ---

SYSTEM_PKGS=$(find "$SYSTEM_LIB" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)

# Orphans: directories pacman -Qo cannot resolve.
SYSTEM_ORPHANS=$(
  while IFS= read -r pkg; do
    desc="$SYSTEM_LIB/$pkg/DESCRIPTION"
    [[ -f "$desc" ]] || continue
    if ! pacman -Qo "$desc" >/dev/null 2>&1; then
      echo "$pkg"
    fi
  done <<<"$SYSTEM_PKGS"
)

USER_PKGS=""
if [[ -d "$USER_LIB" ]]; then
  USER_PKGS=$(find "$USER_LIB" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
fi

USER_DUPES=""
USER_UNIQUES=""
if [[ -n "$USER_PKGS" ]]; then
  USER_DUPES=$(comm -12 <(echo "$USER_PKGS") <(echo "$SYSTEM_PKGS"))
  USER_UNIQUES=$(comm -23 <(echo "$USER_PKGS") <(echo "$SYSTEM_PKGS"))
fi

# Version compare for duplicates.
_read_ver() {
  local desc="$1"
  [[ -f "$desc" ]] || { echo ""; return; }
  awk '/^Version:/ { print $2; exit }' "$desc"
}
_read_built() {
  local desc="$1"
  [[ -f "$desc" ]] || { echo ""; return; }
  awk '/^Built:/ { sub(/^Built: /, ""); print; exit }' "$desc"
}

# --- Output modes ---

if [[ "$MODE" == "list" ]]; then
  case "$CATEGORY" in
    system-orphan)  echo "$SYSTEM_ORPHANS" ;;
    user-duplicate) echo "$USER_DUPES" ;;
    user-unique)    echo "$USER_UNIQUES" ;;
    *) echo "unknown category: $CATEGORY" >&2; exit 2 ;;
  esac
  exit 0
fi

n_system=$(echo "$SYSTEM_PKGS" | grep -c '^.' || true)
n_user=$(echo "$USER_PKGS" | grep -c '^.' || true)
n_orphan=$(echo "$SYSTEM_ORPHANS" | grep -c '^.' || true)
n_dupe=$(echo "$USER_DUPES" | grep -c '^.' || true)
n_uniq=$(echo "$USER_UNIQUES" | grep -c '^.' || true)

if [[ "$MODE" == "summary" ]]; then
  printf 'system-lib total       %d\n' "$n_system"
  printf 'system-lib orphans     %d\n' "$n_orphan"
  printf 'user-lib total         %d\n' "$n_user"
  printf 'user-lib duplicates    %d\n' "$n_dupe"
  printf 'user-lib uniques       %d\n' "$n_uniq"
  exit 0
fi

# Report mode.
r_version=$(R --version 2>/dev/null | head -1 || echo "R not available")
echo "tRäning R library audit"
echo "  host:        $(hostname)"
echo "  $r_version"
echo "  system-lib:  $SYSTEM_LIB ($n_system packages)"
echo "  user-lib:    $USER_LIB ($n_user packages)"
echo ""

echo "==> system-orphan ($n_orphan)"
echo "    Packages in system-lib that pacman does not own."
echo "    After the 2026-05 cleanup this list should be empty or"
echo "    contain only packages with a documented reason."
if [[ "$n_orphan" -gt 0 ]]; then
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    ver=$(_read_ver "$SYSTEM_LIB/$pkg/DESCRIPTION")
    printf '    %-30s %s\n' "$pkg" "$ver"
  done <<<"$SYSTEM_ORPHANS"
else
  echo "    (none)"
fi
echo ""

echo "==> user-duplicate ($n_dupe)"
echo "    Packages in both user-lib and system-lib. user-lib wins via"
echo "    .libPaths() ordering, so the pacman version is shadowed."
echo "    Remove the user-lib copy unless it is materially newer."
if [[ "$n_dupe" -gt 0 ]]; then
  printf '    %-30s %-15s %-15s %s\n' "package" "user-ver" "system-ver" "verdict"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    uver=$(_read_ver "$USER_LIB/$pkg/DESCRIPTION")
    sver=$(_read_ver "$SYSTEM_LIB/$pkg/DESCRIPTION")
    verdict="remove user-lib"
    if [[ -n "$uver" && -n "$sver" && "$uver" != "$sver" ]]; then
      newer=$(printf '%s\n%s\n' "$uver" "$sver" | sort -V | tail -1)
      if [[ "$newer" == "$uver" ]]; then
        verdict="user newer — review"
      fi
    fi
    printf '    %-30s %-15s %-15s %s\n' "$pkg" "${uver:-?}" "${sver:-?}" "$verdict"
  done <<<"$USER_DUPES"
else
  echo "    (none)"
fi
echo ""

echo "==> user-unique ($n_uniq)"
echo "    Packages only in user-lib. CRAN fallback — keep."
echo "    These need manual rebuild after each R major bump."
if [[ "$n_uniq" -gt 0 ]]; then
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    uver=$(_read_ver "$USER_LIB/$pkg/DESCRIPTION")
    built=$(_read_built "$USER_LIB/$pkg/DESCRIPTION")
    printf '    %-30s %-15s built: %s\n' "$pkg" "${uver:-?}" "${built:-?}"
  done <<<"$USER_UNIQUES"
fi
