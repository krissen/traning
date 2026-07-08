"""Shared helpers for invoking the R CLI's import commands.

Several callers shell out to ``Rscript cli.R --import`` / ``--import-health``:
the FastAPI receiver's Garmin-trigger path and its debounced HAE-workout
flush (``server/app.py``), and the ``traning import``/``sync`` CLI commands
(``main.py``). This module centralizes the subprocess invocation so the
command construction and calling conventions (capture/cwd/timeout) don't
drift between callers, plus the "trailing summary line" parsing shared by
the two capture-output callers.

Locking (``_import_lock`` in ``server/app.py``) intentionally stays with
the callers: whether concurrent imports need to be serialized is a
caller-level concern, not something this helper should assume.
"""

import logging
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)


def run_r_import(
    cli_r: Path,
    args: list[str],
    *,
    cwd: Path | None = None,
    timeout: float | None = None,
    capture_output: bool = True,
) -> subprocess.CompletedProcess:
    """Run ``Rscript <cli_r> <args...>``.

    Thin, shared wrapper around ``subprocess.run`` so the command gets
    built the same way everywhere. ``capture_output=False`` streams
    stdout/stderr straight through (used by the interactive CLI);
    ``capture_output=True`` (default) captures text output for callers
    that parse the result (used by the FastAPI receiver).

    Raises ``subprocess.TimeoutExpired`` on timeout — callers keep their
    own try/except since each has a different logging/error-reporting
    shape.
    """
    cmd = ["Rscript", str(cli_r), *args]
    kwargs: dict = {"cwd": str(cwd) if cwd else None}
    if capture_output:
        kwargs["capture_output"] = True
        kwargs["text"] = True
    if timeout is not None:
        kwargs["timeout"] = timeout
    return subprocess.run(cmd, **kwargs)


def parse_import_summary(stdout: str) -> str:
    """Extract the trailing import-summary line from R import stdout.

    Returns the last non-blank line mentioning "import" or "inget att"
    (Swedish for "nothing to [import]"), or "klart" if no such line is
    found.
    """
    lines = [line.strip() for line in stdout.strip().splitlines() if line.strip()]
    for line in reversed(lines):
        low = line.lower()
        if any(w in low for w in ["import", "inget att"]):
            return line
    return "klart"
