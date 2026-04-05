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
    """Shared options for all report commands: --plot, --after, --before, --span, --output, --limit."""
    @click.option("--plot", "show_plot", is_flag=True, help="Show plot instead of table")
    @click.option("--after", default=None,
                  help="Start of date range (YYYY, YYYY-MM, YYYY-MM-DD, -Nw/-Nm/-Ny/-Nd)")
    @click.option("--before", default=None,
                  help="End of date range (same formats as --after)")
    @click.option("--span", default=None,
                  help="Duration from --after (e.g. 3m, 1y). Requires --after")
    @click.option("--output", default=None,
                  help="Save output to file (format from extension or --format)")
    @click.option("--format", "fmt", default=None,
                  help="Output format. Plots: pdf, png. Tables: csv, json, jsonl, xlsx")
    @click.option("--no-open", is_flag=True, help="Don't open output file after saving")
    @click.option("--limit", type=int, default=None, help="Limit table rows")
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        return f(*args, **kwargs)
    return wrapper


def _r_report(flag, show_plot=False, after=None, before=None, span=None,
              limit=None, output=None, fmt=None, no_open=False):
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
    if limit is not None:
        cmd.append(f"--limit={limit}")
    if output:
        cmd.append(f"--output={output}")
    if fmt:
        cmd.append(f"--format={fmt}")
    if no_open:
        cmd.append("--no-open")
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
def month(show_plot, after, before, span, output, fmt, no_open, limit):
    """Current month vs same month previous years."""
    _r_report("--month-running", show_plot, after, before, span, limit, output, fmt, no_open)


@report.command()
@report_options
def year(show_plot, after, before, span, output, fmt, no_open, limit):
    """Current year vs previous years (same day-of-year)."""
    _r_report("--year-running", show_plot, after, before, span, limit, output, fmt, no_open)


@report.command()
@report_options
def pace(show_plot, after, before, span, output, fmt, no_open, limit):
    """Pace summary per year."""
    _r_report("--total-pace", show_plot, after, before, span, limit, output, fmt, no_open)


@report.command()
@report_options
def top(show_plot, after, before, span, output, fmt, no_open, limit):
    """Year totals."""
    _r_report("--year-top", show_plot, after, before, span, limit, output, fmt, no_open)


@report.command(name="month-top")
@report_options
def month_top(show_plot, after, before, span, output, fmt, no_open, limit):
    """Top 10 months by distance."""
    _r_report("--month-top", show_plot, after, before, span, limit, output, fmt, no_open)


@report.command(name="month-this")
@report_options
def month_this(show_plot, after, before, span, output, fmt, no_open, limit):
    """Individual runs this month."""
    _r_report("--month-this", show_plot, after, before, span, limit, output, fmt, no_open)


@report.command(name="month-last")
@report_options
def month_last(show_plot, after, before, span, output, fmt, no_open, limit):
    """Last month across years."""
    _r_report("--month-last", show_plot, after, before, span, limit, output, fmt, no_open)


# -- plot commands (top-level) -----------------------------------------------

@cli.command()
@report_options
def ef(show_plot, after, before, span, output, fmt, no_open, limit):
    """Efficiency Factor trend."""
    _r_report("--ef", show_plot, after, before, span, limit, output, fmt, no_open)


@cli.command()
@report_options
def hre(show_plot, after, before, span, output, fmt, no_open, limit):
    """Heart Rate Efficiency (beats/km, Votyakov)."""
    _r_report("--hre", show_plot, after, before, span, limit, output, fmt, no_open)


@cli.command()
@report_options
def acwr(show_plot, after, before, span, output, fmt, no_open, limit):
    """Acute:Chronic Workload Ratio."""
    _r_report("--acwr", show_plot, after, before, span, limit, output, fmt, no_open)


@cli.command()
@report_options
def monotony(show_plot, after, before, span, output, fmt, no_open, limit):
    """Training Monotony and Strain."""
    _r_report("--monotony", show_plot, after, before, span, limit, output, fmt, no_open)


@cli.command()
@report_options
def pmc(show_plot, after, before, span, output, fmt, no_open, limit):
    """Performance Management Chart (TRIMP/CTL/ATL/TSB)."""
    _r_report("--pmc", show_plot, after, before, span, limit, output, fmt, no_open)


@cli.command(name="recovery-hr")
@report_options
def recovery_hr(show_plot, after, before, span, output, fmt, no_open, limit):
    """Recovery Heart Rate trend."""
    _r_report("--recovery-hr", show_plot, after, before, span, limit, output, fmt, no_open)


# -- datesum ----------------------------------------------------------------

@cli.command()
@click.argument("range", required=False, default=None)
@report_options
def datesum(range, show_plot, after, before, span, output, fmt, no_open, limit):
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
    if limit is not None:
        cmd.append(f"--limit={limit}")
    if output:
        cmd.append(f"--output={output}")
    if fmt:
        cmd.append(f"--format={fmt}")
    if no_open:
        cmd.append("--no-open")
    _exec(cmd)


# -- shiny ------------------------------------------------------------------

@cli.command()
@click.option("--port", type=int, default=3838, help="Port (default: 3838)")
def shiny(port):
    """Start the tRanat Shiny app."""
    r_expr = f'shiny::runApp("{APP_DIR}", port={port}, launch.browser=TRUE)'
    _exec(["Rscript", "-e", r_expr])
