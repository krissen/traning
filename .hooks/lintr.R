# lintr against the repository's own .lintr, run by the system R.
#
# Replaces the lorenzwalthert/precommit lintr hook: that hook builds a renv
# environment that does not build on this machine (see design.md, "R-hooks
# fail — and it's not prek's fault").
#
# The package is loaded first, and that is not optional. object_usage_linter
# only honours utils::globalVariables() (R/traning-package.R) when the
# package is loaded — without it, every dplyr/ggplot2 NSE column name in R/
# is reported as an undefined global (measured: 1247 findings unloaded vs.
# 148 loaded across the tree).
suppressPackageStartupMessages(library(lintr))

# Loading is required, not best-effort: a silent fallback to linting
# without the package loaded doesn't just miss globalVariables() — it
# turns every dplyr/ggplot2 NSE column name into a spurious "undefined
# global" finding (measured: ~1247 unloaded vs. 0 loaded), which then
# blocks commits for the wrong reason while hiding the actual
# missing-dependency or load error.
if (!file.exists("DESCRIPTION")) {
  message(
    "lintr hook: no DESCRIPTION found in the working directory — ",
    "expected to run from the repository root."
  )
  quit(status = 1)
}
if (!requireNamespace("pkgload", quietly = TRUE)) {
  message(
    "lintr hook: the 'pkgload' package is required to load traning ",
    "before linting (utils::globalVariables() is only honoured once the ",
    "package is loaded) — install it: install.packages('pkgload')"
  )
  quit(status = 1)
}
load_ok <- tryCatch(
  {
    suppressMessages(pkgload::load_all(".", quiet = TRUE))
    TRUE
  },
  error = function(e) {
    message("lintr hook: pkgload::load_all() failed: ", conditionMessage(e))
    FALSE
  }
)
if (!isTRUE(load_ok)) quit(status = 1)

args <- commandArgs(trailingOnly = TRUE)
findings <- 0L
for (f in args) {
  l <- lint(f)
  if (length(l)) {
    print(l)
    findings <- findings + length(l)
  }
}
if (findings > 0L) quit(status = 1)
