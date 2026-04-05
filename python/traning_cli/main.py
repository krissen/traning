"""Unified CLI for tRäning — running data analysis."""

import functools
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


def report_options(f):
    """Shared options for all report commands: --plot, --after, --before, --span."""
    @click.option("--plot", "show_plot", is_flag=True, help="Show plot instead of table")
    @click.option("--after", default=None,
                  help="Start of date range (YYYY, YYYY-MM, YYYY-MM-DD, -Nw/-Nm/-Ny/-Nd)")
    @click.option("--before", default=None,
                  help="End of date range (same formats as --after)")
    @click.option("--span", default=None,
                  help="Duration from --after (e.g. 3m, 1y). Requires --after")
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        return f(*args, **kwargs)
    return wrapper


def _r_report(flag, show_plot=False, after=None, before=None, span=None):
    """Build and execute an R report/plot command."""
    cmd = ["Rscript", str(CLI_R), flag]
    if show_plot:
        cmd.append("--plot")
    if after:
        cmd.append(f"--after={after}")
    if before:
        cmd.append(f"--before={before}")
    if span:
        cmd.append(f"--span={span}")
    _exec(cmd)


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
@report_options
def month(show_plot, after, before, span):
    """Current month vs same month previous years."""
    _r_report("--month-running", show_plot, after, before, span)


@report.command()
@report_options
def year(show_plot, after, before, span):
    """Current year vs previous years (same day-of-year)."""
    _r_report("--year-running", show_plot, after, before, span)


@report.command()
@report_options
def pace(show_plot, after, before, span):
    """Pace summary per year."""
    _r_report("--total-pace", show_plot, after, before, span)


@report.command()
@report_options
def top(show_plot, after, before, span):
    """Year totals."""
    _r_report("--year-top", show_plot, after, before, span)


@report.command(name="month-top")
@report_options
def month_top(show_plot, after, before, span):
    """Top 10 months by distance."""
    _r_report("--month-top", show_plot, after, before, span)


@report.command(name="month-this")
@report_options
def month_this(show_plot, after, before, span):
    """Individual runs this month."""
    _r_report("--month-this", show_plot, after, before, span)


@report.command(name="month-last")
@report_options
def month_last(show_plot, after, before, span):
    """Last month across years."""
    _r_report("--month-last", show_plot, after, before, span)


# -- plot commands (top-level) -----------------------------------------------

@cli.command()
@report_options
def ef(show_plot, after, before, span):
    """Plot Efficiency Factor trend."""
    _r_report("--ef", False, after, before, span)


@cli.command()
@report_options
def acwr(show_plot, after, before, span):
    """Plot Acute:Chronic Workload Ratio."""
    _r_report("--acwr", False, after, before, span)


@cli.command()
@report_options
def monotony(show_plot, after, before, span):
    """Plot Training Monotony and Strain."""
    _r_report("--monotony", False, after, before, span)


# -- datesum ----------------------------------------------------------------

@cli.command()
@click.argument("range", required=False, default=None)
@report_options
def datesum(range, show_plot, after, before, span):
    """Summary for a date range.

    RANGE: Legacy format YYYY-MM-DD--YYYY-MM-DD (optional).
    Prefer --after/--before instead.
    """
    cmd = ["Rscript", str(CLI_R)]
    if range:
        cmd.extend(["--datesum", range])
    if show_plot:
        cmd.append("--plot")
    if after:
        cmd.append(f"--after={after}")
    if before:
        cmd.append(f"--before={before}")
    if span:
        cmd.append(f"--span={span}")
    _exec(cmd)


# -- shiny ------------------------------------------------------------------

@cli.command()
@click.option("--port", type=int, default=3838, help="Port (default: 3838)")
def shiny(port):
    """Start the tRanat Shiny app."""
    r_expr = f'shiny::runApp("{APP_DIR}", port={port}, launch.browser=TRUE)'
    _exec(["Rscript", "-e", r_expr])
