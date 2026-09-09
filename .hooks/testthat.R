# Full testthat suite, run by the system R at pre-push (not pre-commit —
# too slow for every commit; see .pre-commit-config.yaml).
#
# KNOWN RISK, not fixed here (Copilot review finding on PR #90,
# suppressed comment on this line): when TRANING_DATA is set (R
# auto-sources .Renviron at startup) to a real data directory, some
# tests that are otherwise skip_if(Sys.getenv("TRANING_DATA") == "")
# run for real and write cache files under $TRANING_DATA/cache (e.g.
# load_zone_distribution(), load_decoupling()) — so `git push` on a
# machine configured for daily use can mutate real cached data.
# A blind fix (redirecting TRANING_DATA to a disposable temp directory
# for the whole run) was tried and reverted: it does not isolate the
# suite, it *changes which tests run* — several integration tests use
# exactly that skip_if() to opt out when there's no real, populated
# data directory to exercise them against, and pointing TRANING_DATA at
# an empty temp dir turns "skipped" into "run, and fail" (verified:
# test-mcp-bridge.R's plot-path test alone). The tests were already
# written to assume TRANING_DATA is either unset or a real, already
# populated development data directory — not a disposable one — so a
# correct fix needs to distinguish those cases, which needs a decision
# beyond a mechanical wrapper. Filed as an issue rather than guessed at
# under review-loop time pressure; see docs/dev/quality-gates.md.
if (!requireNamespace("devtools", quietly = TRUE)) {
  message(
    "testthat hook: the 'devtools' package is required to run the ",
    "test suite — install it: install.packages('devtools')"
  )
  quit(status = 1)
}

# Package must be loaded first so the test helpers and internal (`:::`)
# functions the test suite calls are available.
suppressMessages(library(devtools))

result <- tryCatch(
  {
    devtools::test(stop_on_failure = TRUE)
    TRUE
  },
  error = function(e) {
    message("testthat: ", conditionMessage(e))
    FALSE
  }
)

if (!isTRUE(result)) quit(status = 1)
