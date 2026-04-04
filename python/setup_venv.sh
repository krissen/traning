#!/usr/bin/env bash
# Create and configure virtual environment for Garmin fetch script.
# Run once from the project root: bash python/setup_venv.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

if [ -d "$VENV_DIR" ]; then
    echo "venv already exists at $VENV_DIR"
    echo "To recreate: rm -rf $VENV_DIR && bash $0"
    exit 0
fi

echo "Creating virtual environment at $VENV_DIR ..."
python3 -m venv "$VENV_DIR"

echo "Installing dependencies ..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"

echo ""
echo "Done. Activate with:"
echo "  source $VENV_DIR/bin/activate"
echo ""
echo "Note: Browser login fallback uses your system Chrome."
echo "No extra browser download needed."
