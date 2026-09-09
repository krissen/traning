# Full testthat suite, run by the system R at pre-push (not pre-commit —
# too slow for every commit; see .pre-commit-config.yaml).
#
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
