# Syntax check for R files, run by the system R.
args <- commandArgs(trailingOnly = TRUE)
bad <- FALSE
for (f in args) {
  tryCatch(
    parse(f),
    error = function(e) {
      cat("PARSE ERROR: ", f, "\n", conditionMessage(e), "\n", sep = "")
      bad <<- TRUE
    }
  )
}
if (bad) quit(status = 1)
