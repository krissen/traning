"""The suite must report on the code beside it, not another checkout."""

from pathlib import Path

import traning_cli

PYTHON_ROOT = Path(__file__).resolve().parent.parent


def test_package_comes_from_this_worktree():
    """Guard for the sys.path insert in conftest.py.

    `traning_cli` is installed editable from the main checkout, so
    without that insert a `pytest` run inside a git worktree passes
    happily while testing a different tree. Should the insert ever stop
    working, this fails loudly instead of the suite going quietly green
    about the wrong code.
    """
    resolved = Path(traning_cli.__file__).resolve().parent.parent
    assert resolved == PYTHON_ROOT, (
        f"traning_cli resolved to {resolved}, expected {PYTHON_ROOT}"
    )
