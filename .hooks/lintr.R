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

if (file.exists("DESCRIPTION") && requireNamespace("pkgload", quietly = TRUE)) {
  try(suppressMessages(pkgload::load_all(".", quiet = TRUE)), silent = TRUE)
}

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
