# styler on the files given, run by the system R.
#
# style_file() rewrites in place, so a reformatted file fails the hook and
# the rewritten version is left in the working tree for the author to stage.
suppressPackageStartupMessages(library(styler))

args <- commandArgs(trailingOnly = TRUE)
res <- styler::style_file(args)
if (any(res$changed)) {
  cat("styler reformatted:\n")
  cat(paste0("  ", res$file[res$changed], collapse = "\n"), "\n")
  quit(status = 1)
}
