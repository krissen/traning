"""tRäning health data receiver (FastAPI)."""

import logging

# Configure app-level logging so it reaches systemd journal (stderr).
# Uvicorn sets up its own loggers but leaves the root logger unconfigured,
# which means log.info() in notify.py / storage.py / app.py goes nowhere.
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(name)s: %(message)s",
)

from .app import create_app

app = create_app()
