"""CLI entry point for OnFailure= systemd notifications.

Invoked by traning-notify@<unit>.service template. Reads the last
journal lines for the failing unit and forwards them to Home Assistant
via the existing notify() helper.

Usage:
    python -m traning_cli.server.notify_cli failure <unit-name>
"""

import subprocess
import sys

from .notify import notify, log_notification


def _journal_tail(unit: str, since: str = "5min ago", lines: int = 20) -> str:
    """Return the last journal lines for `unit`. Best-effort, never raises.

    journalctl writes permission errors and other failures to stderr
    with empty stdout; surface those instead of a misleading
    "(no recent journal output)" so the HA notification carries
    actionable context.
    """
    try:
        result = subprocess.run(
            ["journalctl", "-u", unit, "--since", since,
             "--no-pager", "-n", str(lines)],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as e:
        return f"(could not read journal: {e})"

    out = result.stdout.strip()
    if out:
        return out
    err = result.stderr.strip()
    if err:
        return f"(journalctl exit {result.returncode}: {err})"
    if result.returncode != 0:
        return f"(journalctl exit {result.returncode}, no output)"
    return "(no recent journal output)"


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) < 2 or args[0] != "failure":
        print("usage: notify_cli failure <unit>", file=sys.stderr)
        return 2

    unit = args[1]
    title = f"tRäning: {unit} failed"
    journal = _journal_tail(unit)
    message = f"systemd reported a failure of {unit}.\n\nLast journal lines:\n{journal}"

    sent = notify(title=title, message=message)
    log_notification(
        trigger=f"systemd-onfailure:{unit}",
        title=title,
        message=message,
        sent=sent,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
