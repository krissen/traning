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
import logging
import subprocess
from collections.abc import Iterable
from pathlib import Path

log = logging.getLogger(__name__)

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


def git_commit_paths(data_dir: Path, paths: Iterable[str], message: str) -> bool:
    """Stage *paths* and commit *message* under the cross-process git lock.

    Checks ``git diff --cached --quiet`` after staging so an empty diff
    (nothing new to commit) is treated as a no-op rather than a failing
    ``git commit`` invocation — this was previously only done by the
    health-data receiver's commit path; the Garmin-fetch commit path
    treated "nothing to commit" as a caught-but-logged error instead.

    Returns True if a commit was created, False if there was nothing to
    commit or the git invocation failed (failures are logged here).
    """
    path_list = list(paths)
    try:
        with git_lock(data_dir):
            subprocess.run(
                ["git", "add", *path_list],
                cwd=data_dir, check=True, capture_output=True,
            )
            result = subprocess.run(
                ["git", "diff", "--cached", "--quiet"],
                cwd=data_dir, capture_output=True,
            )
            if result.returncode == 0:
                log.debug("Nothing to commit in %s (paths=%s)", data_dir, path_list)
                return False

            subprocess.run(
                ["git", "commit", "-m", message],
                cwd=data_dir, check=True, capture_output=True,
            )
        return True
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode().strip() if e.stderr else str(e)
        log.warning("Git commit failed: %s", stderr)
        return False
