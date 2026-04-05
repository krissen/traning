"""Unified CLI for tRäning — running data analysis."""

import logging
import subprocess
import sys
from pathlib import Path

import click

TRANING_ROOT = Path(__file__).resolve().parent.parent.parent
CLI_R = TRANING_ROOT / "inst" / "cli.R"
APP_DIR = TRANING_ROOT / "app" / "tRanat"

log = logging.getLogger(__name__)


def _exec(cmd):
    """Run subprocess, passing through stdio. Exit with child's return code."""
    result = subprocess.run(cmd)
    sys.exit(result.returncode)


def _run(cmd):
    """Run subprocess, passing through stdio. Return the return code."""
    result = subprocess.run(cmd)
    return result.returncode


def _get_version():
    """Read version from R DESCRIPTION file."""
    desc = TRANING_ROOT / "DESCRIPTION"
    if not desc.is_file():
        return "unknown"
    for line in desc.read_text().splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    return "unknown"


# -- top-level group -------------------------------------------------------

@click.group(context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(version=_get_version(), prog_name="traning")
def cli():
    """tRäning — running data analysis tool."""


# -- fetch (pure Python) ---------------------------------------------------

@cli.command()
@click.option("--limit", type=int, default=50,
              help="Max number of new activities to fetch (default: 50)")
@click.option("--all", "fetch_all", is_flag=True,
              help="Fetch all missing activities (ignores --limit)")
@click.option("--dry-run", is_flag=True,
              help="Show what would be fetched without downloading")
@click.option("--reauth", is_flag=True,
              help="Force re-authentication (ignore saved tokens)")
@click.option("--login-method", type=click.Choice(["browser", "native"]),
              default="browser", help="Login method (default: browser)")
@click.option("-v", "--verbose", is_flag=True, help="Enable debug logging")
def fetch(limit, fetch_all, dry_run, reauth, login_method, verbose):
    """Fetch new activities from Garmin Connect."""
    from .garmin import authenticate, fetch_new_activities, get_data_dir, token_dir, setup_logging

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (EnvironmentError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    try:
        tokens = token_dir(data_dir)
        client = authenticate(tokens, force_reauth=reauth, method=login_method)
    except Exception as e:
        raise click.ClickException(f"Authentication failed: {e}")

    try:
        n = fetch_new_activities(
            client, data_dir,
            limit=limit, fetch_all=fetch_all, dry_run=dry_run,
        )
        action = "would fetch" if dry_run else "fetched"
        click.echo(f"Done — {action} {n} new activities")
        if n > 0 and not dry_run:
            _commit_data(data_dir, n)
    except Exception as e:
        raise click.ClickException(f"Fetch failed: {e}")


def _commit_data(data_dir, n: int) -> None:
    """Git add + commit new files in the data repo."""
    try:
        subprocess.run(
            ["git", "add", "kristian/filer/gconnect/", "kristian/filer/tcx/"],
            cwd=data_dir, check=True, capture_output=True,
        )
        subprocess.run(
            ["git", "commit", "-m", f"(import) Fetch {n} new activities from Garmin Connect"],
            cwd=data_dir, check=True, capture_output=True,
        )
        log.info("Committed %d new activities to data repo", n)
    except subprocess.CalledProcessError as e:
        log.warning("Git commit failed: %s", e.stderr.decode().strip())


# -- import (R delegation) -------------------------------------------------

@cli.command(name="import")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def import_cmd(verbose):
    """Import new TCX workouts into RData cache."""
    cmd = ["Rscript", str(CLI_R), "--import"]
    if verbose:
        cmd.append("--verbose")
    _exec(cmd)


# -- update (fetch + import) -----------------------------------------------

@cli.command()
@click.option("--all", "fetch_all", is_flag=True,
              help="Fetch all missing activities")
@click.option("--dry-run", is_flag=True,
              help="Preview fetch without downloading (skips import)")
@click.option("--reauth", is_flag=True,
              help="Force re-authentication")
@click.option("--login-method", type=click.Choice(["browser", "native"]),
              default="browser", help="Login method")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def update(fetch_all, dry_run, reauth, login_method, verbose):
    """Fetch new activities, then import into R cache."""
    from .garmin import authenticate, fetch_new_activities, get_data_dir, token_dir, setup_logging

    setup_logging(verbose=verbose)

    # Step 1: Fetch
    try:
        data_dir = get_data_dir()
    except (EnvironmentError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    try:
        tokens = token_dir(data_dir)
        client = authenticate(tokens, force_reauth=reauth, method=login_method)
    except Exception as e:
        raise click.ClickException(f"Authentication failed: {e}")

    try:
        n = fetch_new_activities(
            client, data_dir,
            limit=50, fetch_all=fetch_all, dry_run=dry_run,
        )
        action = "would fetch" if dry_run else "fetched"
        click.echo(f"Fetch: {action} {n} new activities")
        if n > 0 and not dry_run:
            _commit_data(data_dir, n)
    except Exception as e:
        raise click.ClickException(f"Fetch failed: {e}")

    # Step 2: Import (skip if dry-run or nothing new)
    if dry_run:
        click.echo("Dry-run mode — skipping import")
        return
    if n == 0:
        click.echo("No new activities — skipping import")
        return

    click.echo("Importing into R cache ...")
    cmd = ["Rscript", str(CLI_R), "--import"]
    if verbose:
        cmd.append("--verbose")
    rc = _run(cmd)
    if rc != 0:
        raise click.ClickException(f"R import failed (exit code {rc})")


# -- report group -----------------------------------------------------------

@cli.group()
def report():
    """Run training reports."""


@report.command()
def month():
    """Current month vs same month previous years."""
    _exec(["Rscript", str(CLI_R), "--month-running"])


@report.command()
def year():
    """Current year vs previous years (same day-of-year)."""
    _exec(["Rscript", str(CLI_R), "--year-running"])


@report.command()
def pace():
    """Pace summary per year."""
    _exec(["Rscript", str(CLI_R), "--total-pace"])


@report.command()
def top():
    """Year totals."""
    _exec(["Rscript", str(CLI_R), "--year-top"])


@report.command(name="month-top")
def month_top():
    """Top 10 months by distance."""
    _exec(["Rscript", str(CLI_R), "--month-top"])


@report.command(name="month-this")
def month_this():
    """Individual runs this month."""
    _exec(["Rscript", str(CLI_R), "--month-this"])


@report.command(name="month-last")
def month_last():
    """Last month across years."""
    _exec(["Rscript", str(CLI_R), "--month-last"])


# -- plot commands (top-level) -----------------------------------------------

@cli.command()
def ef():
    """Plot Efficiency Factor trend."""
    _exec(["Rscript", str(CLI_R), "--ef"])


@cli.command()
def acwr():
    """Plot Acute:Chronic Workload Ratio."""
    _exec(["Rscript", str(CLI_R), "--acwr"])


@cli.command()
def monotony():
    """Plot Training Monotony and Strain."""
    _exec(["Rscript", str(CLI_R), "--monotony"])


# -- datesum ----------------------------------------------------------------

@cli.command()
@click.argument("range")
def datesum(range):
    """Summary for a date range (YYYY-MM-DD--YYYY-MM-DD)."""
    _exec(["Rscript", str(CLI_R), "--datesum", range])


# -- shiny ------------------------------------------------------------------

@cli.command()
@click.option("--port", type=int, default=3838, help="Port (default: 3838)")
def shiny(port):
    """Start the tRanat Shiny app."""
    r_expr = f'shiny::runApp("{APP_DIR}", port={port}, launch.browser=TRUE)'
    _exec(["Rscript", "-e", r_expr])
