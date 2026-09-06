"""Unified CLI for tRäning — running data analysis."""

import functools
import logging
import subprocess
import sys
from importlib import metadata
from pathlib import Path

import click

from .git_utils import git_commit_paths
from .r_import import run_r_import

TRANING_ROOT = Path(__file__).resolve().parent.parent.parent
CLI_R = TRANING_ROOT / "inst" / "cli.R"
APP_DIR = TRANING_ROOT / "app" / "tRanat"

log = logging.getLogger(__name__)


def _exec(cmd):
    """Run subprocess, passing through stdio. Exit with child's return code."""
    result = subprocess.run(cmd)
    sys.exit(result.returncode)


def _has_remote(data_dir: Path) -> bool:
    """Check if the data repo has a git remote configured."""
    result = subprocess.run(
        ["git", "remote"],
        cwd=data_dir, capture_output=True, text=True,
    )
    return bool(result.stdout.strip())


def _maybe_pull(data_dir: Path) -> None:
    """Pull from remote if one is configured. Silent on failure."""
    if not _has_remote(data_dir):
        return
    result = subprocess.run(
        ["git", "pull", "--ff-only"],
        cwd=data_dir, capture_output=True,
    )
    if result.returncode == 0:
        log.info("Pulled latest data from remote")
    else:
        log.warning("git pull failed: %s", result.stderr.decode().strip())


def _get_version():
    """Read the installed package version (single source of truth: pyproject.toml).

    Falls back to scraping the R DESCRIPTION file only if the package isn't
    installed (e.g. running from source without `pip install -e .`), so the
    CLI still works during first-time setup.
    """
    try:
        return metadata.version("traning-cli")
    except metadata.PackageNotFoundError:
        pass
    desc = TRANING_ROOT / "DESCRIPTION"
    if not desc.is_file():
        return "unknown"
    for line in desc.read_text().splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    return "unknown"


def report_options(f):
    """Shared options for all report commands: --plot, --after, --before, --span,
    --output, --limit."""
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
    @click.option("--sport", default=None,
                  help=("Sport bucket to filter on. When omitted the R "
                        "CLI's own default is used (currently 'running' — "
                        "back-compat). Examples: 'cycling', 'walking', "
                        "'strength', 'all' (no filter), 'endurance' "
                        "(running+cycling+walking+swimming). Swedish "
                        "aliases ('löpning', 'cykling', 'gång') accepted. "
                        "Pass an empty string ('') to match nothing."))
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        return f(*args, **kwargs)
    return wrapper


def _r_report(flag, show_plot=False, after=None, before=None, span=None,
              limit=None, output=None, fmt=None, no_open=False,
              sport=None):
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
    # Forward sport= even when empty ("") — the R helper treats an empty
    # bucket as "match nothing" rather than as "no filter", so dropping
    # the flag would silently fall back to R's default sport instead of
    # honouring the explicit empty pass-through.
    if sport is not None:
        cmd.append(f"--sport={sport}")
    _exec(cmd)


# -- top-level group -------------------------------------------------------

@click.group(context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(version=_get_version(), prog_name="traning")
def cli():
    """tRäning — running data analysis tool."""


# -- fetch group -----------------------------------------------------------

@cli.group()
def fetch():
    """Fetch raw data from external sources."""


@fetch.command(name="garmin")
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
def fetch_garmin(limit, fetch_all, dry_run, reauth, login_method, verbose):
    """Fetch new activities from Garmin Connect."""
    from .garmin import authenticate, fetch_new_activities, get_data_dir, setup_logging, token_dir

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
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


@fetch.command(name="health")
@click.option("--server", is_flag=True, help="Only fetch from TCP server")
@click.option("--inbox", is_flag=True, help="Only process inbox files")
@click.option("--days-back", type=int, default=None,
              help="Re-fetch last N days (instead of incremental)")
@click.option("--all", "fetch_all", is_flag=True,
              help="Full re-fetch from 2013 (slow)")
@click.option("--dry-run", is_flag=True, help="Preview without downloading")
@click.option("-v", "--verbose", is_flag=True, help="Enable debug logging")
def fetch_health(server, inbox, days_back, fetch_all, dry_run, verbose):
    """Fetch health data from Health Auto Export."""
    from .garmin.utils import get_data_dir, setup_logging
    from .health import check_server, fetch_inbox, fetch_tcp

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    # Default: try both strategies
    do_server = server or (not server and not inbox)
    do_inbox = inbox or (not server and not inbox)

    total = 0

    if do_server:
        if check_server():
            click.echo("HAE-server nåbar, hämtar ...")
            n = fetch_tcp(data_dir, days_back=days_back,
                          fetch_all=fetch_all, dry_run=dry_run)
            action = "would write" if dry_run else "wrote"
            click.echo(f"TCP: {action} {n} metric files")
            total += n
        else:
            click.echo("HAE-server inte nåbar — hoppar över TCP", err=True)

    if do_inbox:
        n = fetch_inbox(data_dir, dry_run=dry_run)
        action = "would process" if dry_run else "processed"
        click.echo(f"Inbox: {action} {n} files")
        total += n

    if total == 0 and not dry_run:
        click.echo("Ingen ny hälsodata hittades")


@fetch.command(name="workouts")
@click.option("--since", default="2014-01-01",
              help="Start date YYYY-MM-DD (default: 2014-01-01, earliest AW data)")
@click.option("--until", default=None,
              help="End date YYYY-MM-DD (default: today)")
@click.option("--no-metadata", is_flag=True,
              help="Skip avgHR/heartRateData (smaller, faster, no PMC effect)")
@click.option("--aggregation", default="minutes",
              type=click.Choice(["minutes", "seconds"]),
              help="HR sample granularity (default: minutes)")
@click.option("--dry-run", is_flag=True,
              help="Count what would be written without writing")
@click.option("-v", "--verbose", is_flag=True, help="Enable debug logging")
def fetch_workouts(since, until, no_metadata, aggregation, dry_run, verbose):
    """Pull historical workouts from HAE TCP server month by month."""
    from .garmin.utils import get_data_dir, setup_logging
    from .health import check_server
    from .health.workouts_tcp import fetch_workouts_tcp

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    if not check_server():
        raise click.ClickException("HAE-server inte nåbar — starta appen i förgrunden")

    counts = fetch_workouts_tcp(
        start_date=since, end_date=until, data_dir=data_dir,
        dry_run=dry_run,
        include_metadata=not no_metadata,
        metadata_aggregation=aggregation,
    )

    action = "would write" if dry_run else "wrote"
    click.echo(
        f"Workouts: {action} {counts['new']} new, "
        f"{counts['existing']} already on disk, "
        f"{counts['empty_chunks']} empty months, "
        f"{counts['failed_chunks']} failed chunks"
    )


def _commit_data(data_dir, n: int) -> None:
    """Git add + commit new files in the data repo."""
    message = f"(import) Fetch {n} new activities from Garmin Connect"
    committed = git_commit_paths(
        data_dir, ["kristian/filer/gconnect/", "kristian/filer/tcx/"], message,
    )
    if committed:
        log.info("Committed %d new activities to data repo", n)
    else:
        log.debug("No new Garmin activities to commit")


# -- backfill --------------------------------------------------------------

@cli.command()
@click.argument("zipfile", type=click.Path(exists=True))
@click.option("--dry-run", is_flag=True,
              help="Show what would be written without writing")
def backfill(zipfile, dry_run):
    """Backfill canonical health metrics from an export archive.

    Auto-detects the archive type (Withings, etc.) and writes
    canonical per-day JSON files for dates not already present.
    """
    from .health.backfill import backfill_archive

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        counts = backfill_archive(zipfile, dry_run=dry_run)
    except ValueError as e:
        raise click.ClickException(str(e))

    action = "Would write" if dry_run else "Wrote"
    for metric, n in sorted(counts.items()):
        click.echo(f"  {metric}: {action} {n} new files")

    total = sum(counts.values())
    if total == 0:
        click.echo("Inga nya datum att backfilla.")
    elif dry_run:
        click.echo(f"Totalt: {total} nya filer (dry run)")
    else:
        click.echo(f"Klart! {total} nya filer.")


# -- import group ----------------------------------------------------------

@cli.group(name="import")
def import_group():
    """Import fetched data into R analysis cache."""


@import_group.command(name="garmin")
@click.option("--repair", is_flag=True,
              help="Repair NULL myruns entries (re-parse TCX files)")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def import_garmin(repair, verbose):
    """Import TCX workouts into RData cache."""
    args = ["--import"]
    if repair:
        args.append("--repair")
    if verbose:
        args.append("--verbose")
    result = run_r_import(CLI_R, args, capture_output=False)
    sys.exit(result.returncode)


@import_group.command(name="health")
@click.option("--force", is_flag=True,
              help="Re-import all files (bypass manifest)")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def import_health(force, verbose):
    """Import health data (JSON) into RData cache."""
    args = ["--import-health"]
    if force:
        args.append("--force")
    if verbose:
        args.append("--verbose")
    result = run_r_import(CLI_R, args, capture_output=False)
    sys.exit(result.returncode)


@import_group.command(name="canonical")
@click.argument("paths", nargs=-1, required=True,
                type=click.Path(exists=True, path_type=Path))
@click.option("--dry-run", is_flag=True,
              help="Show what would be canonicalized without writing")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def import_canonical(paths, dry_run, verbose):
    """Canonicalize HAE metric JSON files already on disk.

    PATHS may be files or directories of HAE exports (the shape
    `traning fetch health` writes to health_export/metrics/). Each file
    is merged into canonical/ through the same deduplication the live
    receiver uses, so a manual or out-of-band fetch does not need its
    own script.
    """
    from .garmin.utils import get_data_dir, setup_logging
    from .server.storage import canonicalize_paths

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    n_files, n_metrics, changed = canonicalize_paths(
        list(paths), data_dir=data_dir, dry_run=dry_run)

    if n_files == 0:
        click.echo("Inga HAE-metricfiler hittades")
        return
    if dry_run:
        click.echo(f"Dry run: {n_files} filer, {n_metrics} metrics")
        return
    click.echo(f"{n_files} filer, {n_metrics} metrics, "
               f"{len(changed)} canonical-filer uppdaterade")


@import_group.command(name="all")
@click.option("--force", is_flag=True,
              help="Re-import all health files (bypass manifest)")
@click.option("--repair", is_flag=True,
              help="Repair NULL myruns entries (re-parse TCX files)")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def import_all(force, repair, verbose):
    """Import everything (Garmin + Health)."""
    click.echo("=== Garmin-import ===")
    args_garmin = ["--import"]
    if repair:
        args_garmin.append("--repair")
    if verbose:
        args_garmin.append("--verbose")
    rc = run_r_import(CLI_R, args_garmin, capture_output=False).returncode
    if rc != 0:
        click.echo("Garmin-import misslyckades", err=True)

    click.echo("=== Health-import ===")
    args_health = ["--import-health"]
    if force:
        args_health.append("--force")
    if verbose:
        args_health.append("--verbose")
    rc2 = run_r_import(CLI_R, args_health, capture_output=False).returncode
    if rc2 != 0:
        click.echo("Health-import misslyckades", err=True)

    if rc != 0 or rc2 != 0:
        raise click.ClickException("En eller flera importer misslyckades")
    click.echo("Klar!")


# -- sync group ------------------------------------------------------------

@cli.group()
def sync():
    """Fetch and import in one step."""


@sync.command(name="garmin")
@click.option("--all", "fetch_all", is_flag=True,
              help="Fetch all missing activities")
@click.option("--dry-run", is_flag=True,
              help="Preview fetch without downloading (skips import)")
@click.option("--reauth", is_flag=True,
              help="Force re-authentication")
@click.option("--login-method", type=click.Choice(["browser", "native"]),
              default="browser", help="Login method")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def sync_garmin(fetch_all, dry_run, reauth, login_method, verbose):
    """Fetch from Garmin Connect, then import into R cache."""
    from .garmin import authenticate, fetch_new_activities, get_data_dir, setup_logging, token_dir

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    _maybe_pull(data_dir)

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

    if dry_run:
        click.echo("Dry-run — hoppar över import")
        return
    if n == 0:
        click.echo("Inga nya aktiviteter — hoppar över import")
        return

    click.echo("Importerar till R-cache ...")
    args = ["--import"]
    if verbose:
        args.append("--verbose")
    rc = run_r_import(CLI_R, args, capture_output=False).returncode
    if rc != 0:
        raise click.ClickException(f"R-import misslyckades (exit code {rc})")


@sync.command(name="health")
@click.option("--server", is_flag=True, help="Only fetch from TCP server")
@click.option("--inbox", is_flag=True, help="Only process inbox files")
@click.option("--days-back", type=int, default=None,
              help="Re-fetch last N days")
@click.option("--all", "fetch_all", is_flag=True,
              help="Full re-fetch from 2013")
@click.option("--force", is_flag=True,
              help="Force re-import of all files (bypass manifest)")
@click.option("--dry-run", is_flag=True, help="Preview without action")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def sync_health(server, inbox, days_back, fetch_all, force, dry_run, verbose):
    """Fetch health data, then import into R cache."""
    from .garmin.utils import get_data_dir, setup_logging
    from .health import check_server, fetch_inbox, fetch_tcp

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    _maybe_pull(data_dir)

    do_server = server or (not server and not inbox)
    do_inbox = inbox or (not server and not inbox)

    total = 0

    if do_server:
        if check_server():
            click.echo("HAE-server nåbar, hämtar ...")
            n = fetch_tcp(data_dir, days_back=days_back,
                          fetch_all=fetch_all, dry_run=dry_run)
            action = "would write" if dry_run else "wrote"
            click.echo(f"TCP: {action} {n} metric files")
            total += n
        else:
            click.echo("HAE-server inte nåbar — hoppar över TCP", err=True)

    if do_inbox:
        n = fetch_inbox(data_dir, dry_run=dry_run)
        action = "would process" if dry_run else "processed"
        click.echo(f"Inbox: {action} {n} files")
        total += n

    if dry_run:
        click.echo("Dry-run — hoppar över import")
        return
    if total == 0 and not force:
        click.echo("Ingen ny hälsodata — hoppar över import")
        return

    click.echo("Importerar hälsodata till R-cache ...")
    args = ["--import-health"]
    if force:
        args.append("--force")
    if verbose:
        args.append("--verbose")
    rc = run_r_import(CLI_R, args, capture_output=False).returncode
    if rc != 0:
        raise click.ClickException(f"R-import av hälsodata misslyckades (exit code {rc})")


@sync.command(name="all")
@click.option("--dry-run", is_flag=True, help="Preview without action")
@click.option("--reauth", is_flag=True, help="Force Garmin re-authentication")
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def sync_all(dry_run, reauth, verbose):
    """Fetch and import everything (Garmin + Health)."""
    from .garmin import authenticate, fetch_new_activities, get_data_dir, setup_logging, token_dir
    from .health import check_server, fetch_inbox, fetch_tcp

    setup_logging(verbose=verbose)

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    _maybe_pull(data_dir)

    # --- Garmin ---
    click.echo("=== Garmin ===")
    try:
        tokens = token_dir(data_dir)
        client = authenticate(tokens, force_reauth=reauth, method="browser")
        n_garmin = fetch_new_activities(
            client, data_dir, limit=50, fetch_all=False, dry_run=dry_run,
        )
        action = "would fetch" if dry_run else "fetched"
        click.echo(f"Fetch: {action} {n_garmin} new activities")
        if n_garmin > 0 and not dry_run:
            _commit_data(data_dir, n_garmin)
    except Exception as e:
        click.echo(f"Garmin fetch misslyckades: {e}", err=True)
        n_garmin = 0

    if n_garmin > 0 and not dry_run:
        click.echo("Importerar Garmin-data ...")
        args = ["--import"]
        if verbose:
            args.append("--verbose")
        rc = run_r_import(CLI_R, args, capture_output=False).returncode
        if rc != 0:
            click.echo("Garmin R-import misslyckades", err=True)

    # --- Health ---
    click.echo("\n=== Health ===")
    n_health = 0

    if check_server():
        click.echo("HAE-server nåbar, hämtar ...")
        n = fetch_tcp(data_dir, dry_run=dry_run)
        click.echo(f"TCP: {'would write' if dry_run else 'wrote'} {n} metric files")
        n_health += n
    else:
        click.echo("HAE-server inte nåbar — hoppar över TCP", err=True)

    n = fetch_inbox(data_dir, dry_run=dry_run)
    click.echo(f"Inbox: {'would process' if dry_run else 'processed'} {n} files")
    n_health += n

    if n_health > 0 and not dry_run:
        click.echo("Importerar hälsodata ...")
        args = ["--import-health"]
        if verbose:
            args.append("--verbose")
        rc = run_r_import(CLI_R, args, capture_output=False).returncode
        if rc != 0:
            click.echo("Health R-import misslyckades", err=True)

    if dry_run:
        click.echo("\nDry-run — inga ändringar gjordes")
    else:
        click.echo(f"\nKlart — {n_garmin} Garmin-aktiviteter, {n_health} hälsofiler")


# -- report group -----------------------------------------------------------

@cli.group()
def report():
    """Run training reports."""


@report.command()
@report_options
def month(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Current month vs same month previous years."""
    _r_report("--month-running", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@report.command()
@report_options
def year(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Current year vs previous years (same day-of-year)."""
    _r_report("--year-running", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@report.command()
@report_options
def pace(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Pace summary per year."""
    _r_report("--total-pace", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@report.command()
@report_options
def top(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Year totals."""
    _r_report("--year-top", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@report.command(name="month-top")
@report_options
def month_top(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Top 10 months by distance."""
    _r_report("--month-top", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@report.command(name="month-this")
@report_options
def month_this(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Individual runs this month."""
    _r_report("--month-this", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@report.command(name="month-last")
@report_options
def month_last(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Last month across years."""
    _r_report("--month-last", show_plot, after, before, span, limit, output, fmt, no_open, sport)


# -- plot commands (top-level) -----------------------------------------------

@cli.command()
@report_options
def ef(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Efficiency Factor trend."""
    _r_report("--ef", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@cli.command()
@report_options
def hre(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Heart Rate Efficiency (beats/km, Votyakov)."""
    _r_report("--hre", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@cli.command()
@report_options
def acwr(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Acute:Chronic Workload Ratio."""
    _r_report("--acwr", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@cli.command()
@report_options
def monotony(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Training Monotony and Strain."""
    _r_report("--monotony", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@cli.command()
@report_options
def pmc(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Performance Management Chart (TRIMP/CTL/ATL/TSB)."""
    _r_report("--pmc", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@cli.command(name="recovery-hr")
@report_options
def recovery_hr(show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Recovery Heart Rate trend."""
    _r_report("--recovery-hr", show_plot, after, before, span, limit, output, fmt, no_open, sport)


@cli.command(name="zones")
@click.option("--force", is_flag=True, help="Recompute all zones (bypass cache)")
@report_options
def hr_zones(force, show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """HR zone distribution and Polarization Index (Seiler 3-zone)."""
    cmd = ["Rscript", str(CLI_R), "--hr-zones"]
    if force:
        cmd.append("--force")
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
    if sport is not None:
        cmd.append(f"--sport={sport}")
    _exec(cmd)


@cli.command()
@click.option("--force", is_flag=True, help="Recompute all (bypass cache)")
@report_options
def decoupling(force, show_plot, after, before, span, output, fmt, no_open, limit, sport):
    """Aerobic decoupling trend (pace:HR drift)."""
    cmd = ["Rscript", str(CLI_R), "--decoupling"]
    if force:
        cmd.append("--force")
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
    if sport is not None:
        cmd.append(f"--sport={sport}")
    _exec(cmd)


# -- datesum ----------------------------------------------------------------

@cli.command()
@click.argument("range", required=False, default=None)
@report_options
def datesum(range, show_plot, after, before, span, output, fmt, no_open, limit, sport):
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
    if sport is not None:
        cmd.append(f"--sport={sport}")
    _exec(cmd)


# -- shiny ------------------------------------------------------------------

@cli.command()
@click.option("--port", type=int, default=3838, help="Port (default: 3838)")
def shiny(port):
    """Start the tRanat Shiny app."""
    r_expr = f'shiny::runApp("{APP_DIR}", port={port}, launch.browser=TRUE)'
    _exec(["Rscript", "-e", r_expr])


# -- server -----------------------------------------------------------------

@cli.command()
@click.option("--host", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
@click.option("--port", type=int, default=8421, help="Port (default: 8421)")
@click.option("--reload", is_flag=True, help="Auto-reload on code changes (dev)")
def serve(host, port, reload):
    """Start the health data receiver (FastAPI)."""
    import uvicorn
    uvicorn.run("traning_cli.server:app", host=host, port=port, reload=reload)


# -- pull -------------------------------------------------------------------

@cli.command()
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
def pull(verbose):
    """Pull latest data from GitHub remote."""
    from .garmin.utils import get_data_dir

    try:
        data_dir = get_data_dir()
    except (OSError, FileNotFoundError) as e:
        raise click.ClickException(str(e))

    if not _has_remote(data_dir):
        raise click.ClickException("Inget remote konfigurerat för data-repot")

    result = subprocess.run(
        ["git", "pull", "--ff-only"],
        cwd=data_dir, capture_output=not verbose,
    )
    if result.returncode != 0:
        raise click.ClickException("git pull misslyckades")
    click.echo("Data uppdaterad")


# -- insight ---------------------------------------------------------------

@cli.group()
def insight():
    """Qualitative training insights (Swedish prose)."""


@insight.command(name="day")
@click.option("--date", "ref_date", default=None,
              help="Reference date YYYY-MM-DD (default today)")
@click.option("--push", is_flag=True,
              help="Send via Home Assistant push (kailash systemd timer use)")
@click.option("--force", is_flag=True,
              help="Re-send even if day_summary already marked sent today")
def insight_day(ref_date, push, force):
    """End-of-day qualitative summary across Garmin + HAE workouts."""
    cmd = ["Rscript", str(CLI_R), "--day-summary"]
    if ref_date:
        cmd.append(f"--date={ref_date}")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        raise click.ClickException(
            f"day-summary R-anrop misslyckades: {result.stderr.strip()}"
        )
    msg = result.stdout.strip()
    if not msg:
        raise click.ClickException("day-summary returnerade tom prosa")

    if not push:
        click.echo(msg)
        return

    # Push path — used by the 21:30 systemd timer on kailash. Honours
    # day_summary_sent state to avoid duplicate posts on timer retries.
    from .server.notify import log_notification, notify
    from .server.state import (
        load_notify_state,
        mark_day_summary_sent,
        save_notify_state,
    )

    state = load_notify_state()
    if state.get("day_summary_sent") and not force:
        click.echo("day-summary redan postad i dag (state-flagga). --force för att skicka om.")
        return

    sent = notify("tRäning", msg)
    log_notification("day_summary", "tRäning", msg, sent)
    if sent:
        mark_day_summary_sent(state)
        save_notify_state(state)
    click.echo(msg)


# -- dedup ------------------------------------------------------------------

@cli.command()
@click.option("--apply", "apply_changes", is_flag=True,
              help="Actually remove the listed rows (default: report only)")
@click.option("--dry-run", is_flag=True,
              help="Report only. This is the default; the flag is accepted "
                   "for symmetry with the other commands")
def dedup(apply_changes, dry_run):
    """List Apple Watch sessions that duplicate a Garmin recording.

    Reports only. Pass --apply to remove them from the cache.
    """
    # Removal edits the only copy of the cache, so the safe outcome is the
    # one you get by forgetting a flag.
    cmd = ["Rscript", str(CLI_R), "--dedup"]
    if apply_changes and not dry_run:
        cmd.append("--apply")
    _exec(cmd)


# -- doctor -----------------------------------------------------------------

@cli.group(invoke_without_command=True)
@click.pass_context
def doctor(ctx):
    """Health checks for the traning deployment."""
    if ctx.invoked_subcommand is None:
        ctx.invoke(doctor_run)


_DOCTOR_CHECKS = ("all", "packages", "services", "configs", "freshness")


@doctor.command(name="run")
@click.option("--check", "checks", default=("all",), multiple=True,
              type=click.Choice(_DOCTOR_CHECKS),
              help="Subset of checks to run (repeatable, default: all)")
@click.option("--json", "as_json", is_flag=True,
              help="Emit results as JSON instead of human-readable text")
def doctor_run(checks, as_json):
    """Run deployment health checks. Exits 0 if all pass, 1 otherwise."""
    spec = "all" if "all" in checks else ",".join(checks)
    cmd = ["Rscript", str(CLI_R), "--doctor", f"--doctor-check={spec}"]
    if as_json:
        cmd.append("--doctor-json")
    _exec(cmd)


@doctor.command(name="rebuild-stale")
def doctor_rebuild():
    """Rebuild user-lib R packages built against a previous R version."""
    _exec(["Rscript", str(CLI_R), "--rebuild-stale"])


# -- mcp --------------------------------------------------------------------

@cli.command()
def mcp():
    """Start the Vayu MCP server (stdio transport)."""
    from .mcp.server import main as mcp_main
    mcp_main()
