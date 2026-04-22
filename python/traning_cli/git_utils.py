"""Shared utilities for git operations in the data repo.

Multiple tRäning processes can commit to the data repo concurrently:
FastAPI request handlers (`/v1/health`, `/v1/workouts`), Garmin fetch
subprocesses triggered by the Strava webhook, and systemd-timer Garmin
fetches. git's own `.git/index.lock` doesn't always protect against
interleaved `git add`/`git commit` pairs from unrelated processes —
especially when a process dies mid-operation — which has produced
corrupt tree objects (duplicateEntries, treeNotSorted) on kailash.

`git_lock()` serializes these operations using `fcntl.flock`, which is
cross-process via the kernel. The lock file lives inside `.git/` so it
is naturally excluded from commits.
"""

import contextlib
import fcntl
from pathlib import Path

_LOCK_FILENAME = ".git/tRaning-git.lock"


@contextlib.contextmanager
def git_lock(data_dir: Path):
    """Exclusive, cross-process lock on git operations in *data_dir*."""
    lock_path = data_dir / _LOCK_FILENAME
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
