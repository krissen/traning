.PHONY: check

# The gate to run locally before commit/PR (mirrors CI's lint job, plus
# both test suites). Full output goes to .check.log (gitignored) so a
# green run prints one line, and a red run prints the relevant part.
#
# `ruff check .` WITHOUT --fix runs as its own step even though prek
# already runs ruff-check: `prek run --files <untracked file>` with a
# --fix hook silently rewrites the file and reports Passed (nothing
# staged to compare against), so a newly created, still-untracked module
# would otherwise be cleared as green by that command alone.
#
# gitleaks runs TWICE for the same reason as in CI (see ci.yml and
# .pre-commit-config.yaml): prek's gitleaks hook runs `gitleaks git
# --staged`, which only sees the pending diff. On a branch where changes
# are already committed, nothing is staged, so that step scans nothing —
# a secret in a committed line would otherwise pass `make check` locally
# and only get caught by CI. The second call (`gitleaks dir .`) sweeps
# the whole working tree.
#
# testthat always runs in full, separately from lintr/styler (which prek
# already covers via --all-files) — it's correctness, not lint debt.

check:
	@: > .check.log
	@status=0; \
	if command -v prek >/dev/null 2>&1; then \
		prek run --all-files >> .check.log 2>&1 || status=1; \
	else \
		echo "prek missing from PATH — cannot run the hook sweep (gitleaks, formatting, YAML/JSON, shellcheck, actionlint, size check, R lint/style all skipped)" >> .check.log; \
		status=1; \
	fi; \
	if command -v gitleaks >/dev/null 2>&1; then \
		gitleaks dir . --no-banner >> .check.log 2>&1 || status=1; \
	else \
		echo "gitleaks missing from PATH — cannot run the full secret sweep" >> .check.log; \
		status=1; \
	fi; \
	python/.venv/bin/ruff check . >> .check.log 2>&1 || status=1; \
	python/.venv/bin/python -m pytest -q python/tests >> .check.log 2>&1 || status=1; \
	if command -v Rscript >/dev/null 2>&1; then \
		Rscript -e 'devtools::test(stop_on_failure = TRUE)' >> .check.log 2>&1 || status=1; \
	else \
		echo "Rscript missing from PATH — cannot run testthat" >> .check.log; \
		status=1; \
	fi; \
	if [ "$$status" -ne 0 ]; then \
		echo "make check: RED — see .check.log"; \
		cat .check.log; \
		exit 1; \
	fi; \
	echo "make check: green"
