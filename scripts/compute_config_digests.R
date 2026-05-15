#!/usr/bin/env Rscript
#
# Helper to (re)compute the SHA-256 digests pinned in
# R/doctor.R::EXPECTED_CONFIG_DIGESTS. Run after the canonical source
# of either config file changes — manually paste the new values into
# R/doctor.R. The manual step is intentional: it forces an explicit
# acknowledgement that production config has drifted.
#
# Usage:
#   scripts/compute_config_digests.R
#       # uses repo-local pacman-hook + ssh:kailash for caddy override
#
#   scripts/compute_config_digests.R --caddy /path/to/override.conf
#       # uses the given local file for the caddy override

suppressMessages(library(optparse))

cmd_args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", cmd_args[grep("--file=", cmd_args)])
if (length(script_path) == 0) script_path <- "scripts/compute_config_digests.R"
repo_root <- normalizePath(file.path(dirname(script_path), ".."))

opts <- parse_args(OptionParser(option_list = list(
  make_option("--caddy", type = "character", default = NULL,
    help = "Local path to caddy override.conf (default: scp from kailash)"),
  make_option("--remote", type = "character", default = "kailash",
    help = "Remote host for SSH-based caddy fetch (default %default)")
)))

pacman_hook <- file.path(repo_root,
  "python/traning_cli/server/deploy/traning-r-postupgrade.hook")
if (!file.exists(pacman_hook)) {
  stop("Cannot find pacman-hook source: ", pacman_hook)
}
hook_sha <- unname(digest::digest(file = pacman_hook, algo = "sha256"))

if (!is.null(opts$caddy)) {
  caddy_path <- opts$caddy
  if (!file.exists(caddy_path)) stop("Caddy override not found: ", caddy_path)
  caddy_sha <- unname(digest::digest(file = caddy_path, algo = "sha256"))
} else {
  message("Fetching caddy override SHA from ", opts$remote, " via ssh ...")
  # Merge stderr into stdout so ssh/journalctl errors surface in the
  # stop() message rather than disappearing into a generic "no output".
  out <- suppressWarnings(system2("ssh", c(opts$remote,
    "sha256sum /etc/systemd/system/caddy.service.d/override.conf"),
    stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0L) {
    stop("ssh ", opts$remote, " failed (exit ", status, "): ",
         paste(out, collapse = "\n"))
  }
  if (length(out) == 0L) stop("ssh ", opts$remote, " returned no output")
  caddy_sha <- strsplit(trimws(out[1]), "\\s+")[[1]][1]
}

cat("Paste into R/doctor.R::EXPECTED_CONFIG_DIGESTS:\n\n")
cat(sprintf('EXPECTED_CONFIG_DIGESTS <- list(\n  "/etc/pacman.d/hooks/traning-r-postupgrade.hook" = "%s",\n  "/etc/systemd/system/caddy.service.d/override.conf" = "%s"\n)\n',
            hook_sha, caddy_sha))
