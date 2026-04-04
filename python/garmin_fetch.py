#!/usr/bin/env python3
"""Fetch new training activities from Garmin Connect.

Usage:
    python python/garmin_fetch.py              # Fetch up to 50 new activities
    python python/garmin_fetch.py --all        # Fetch all missing activities
    python python/garmin_fetch.py --limit 200  # Fetch up to 200
    python python/garmin_fetch.py --dry-run    # Show what would be fetched
    python python/garmin_fetch.py --reauth     # Force re-authentication
"""

import argparse
import logging
import sys

from garmin_auth import authenticate
from garmin_download import fetch_new_activities
from garmin_utils import get_data_dir, token_dir, setup_logging

log = logging.getLogger(__name__)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch training activities from Garmin Connect"
    )
    parser.add_argument(
        "--limit", type=int, default=50,
        help="Max number of new activities to fetch (default: 50)",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Fetch all missing activities (ignores --limit)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be fetched without downloading",
    )
    parser.add_argument(
        "--reauth", action="store_true",
        help="Force re-authentication (ignore saved tokens)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Enable debug logging",
    )
    args = parser.parse_args()
    setup_logging(verbose=args.verbose)

    # Resolve data directory
    try:
        data_dir = get_data_dir()
    except (EnvironmentError, FileNotFoundError) as e:
        log.error("%s", e)
        return 3

    # Authenticate
    try:
        tokens = token_dir(data_dir)
        client = authenticate(tokens, force_reauth=args.reauth)
    except Exception:
        log.exception("Authentication failed")
        return 1

    # Fetch
    try:
        n = fetch_new_activities(
            client,
            data_dir,
            limit=args.limit,
            fetch_all=args.all,
            dry_run=args.dry_run,
        )
        action = "would fetch" if args.dry_run else "fetched"
        log.info("Done — %s %d new activities", action, n)
        return 0
    except Exception:
        log.exception("Fetch failed")
        return 2


if __name__ == "__main__":
    sys.exit(main())
