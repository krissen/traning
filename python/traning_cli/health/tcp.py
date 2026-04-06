"""Fetch health metrics from HAE TCP server."""

import json
import logging
import socket
from datetime import datetime, timedelta
from pathlib import Path

from .utils import hae_host, hae_port, health_metrics_dir, DEFAULT_TIMEOUT

log = logging.getLogger(__name__)


def check_server(timeout: float = 3.0) -> bool:
    """Check if the HAE TCP server is reachable."""
    host, port = hae_host(), hae_port()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.close()
        return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


def _query_tcp(start: str, end: str, timeout: float = DEFAULT_TIMEOUT) -> dict | None:
    """Send a query to HAE TCP server and return parsed JSON response."""
    host, port = hae_host(), hae_port()
    request = json.dumps({
        "jsonrpc": "2.0",
        "id": "fetch",
        "method": "callTool",
        "params": {
            "name": "health_metrics",
            "metrics": "",
            "arguments": {
                "start": start,
                "end": end,
                "interval": "days",
                "aggregate": True,
            }
        }
    })

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.sendall(request.encode("utf-8"))

        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            except socket.timeout:
                break
        sock.close()

        raw = b"".join(chunks)
        if len(raw) < 10:
            return None

        data = json.loads(raw)
        if "result" in data and "data" in data["result"]:
            return {"data": data["result"]["data"]}
        return None

    except Exception as e:
        log.error("TCP query failed: %s", e)
        return None


def _latest_cached_date(metrics_dir: Path) -> str | None:
    """Find the latest end-date across existing metric files."""
    latest = None
    for f in metrics_dir.glob("*.json"):
        # Filename format: {metric}_{first}_{last}.json
        parts = f.stem.rsplit("_", 2)
        if len(parts) >= 3:
            date_str = parts[-1]
            if latest is None or date_str > latest:
                latest = date_str
    return latest


def fetch_tcp(data_dir: Path | None = None, days_back: int | None = None,
              fetch_all: bool = False, dry_run: bool = False,
              chunk_months: int = 3) -> int:
    """Fetch health metrics from HAE TCP server.

    Returns the number of metric files written.
    """
    metrics_dir = health_metrics_dir(data_dir)

    # Determine start date
    if fetch_all:
        start_date = datetime(2013, 1, 1)
    elif days_back is not None:
        start_date = datetime.now() - timedelta(days=days_back)
    else:
        # Incremental: since last cached date minus 2-day overlap
        cached = _latest_cached_date(metrics_dir)
        if cached:
            start_date = datetime.strptime(cached, "%Y-%m-%d") - timedelta(days=2)
        else:
            # No cache — fetch last 90 days as reasonable default
            start_date = datetime.now() - timedelta(days=90)

    end_date = datetime.now()

    if dry_run:
        log.info("Dry run: would fetch %s .. %s from %s:%d",
                 start_date.strftime("%Y-%m-%d"), end_date.strftime("%Y-%m-%d"),
                 hae_host(), hae_port())
        return 0

    metrics_dir.mkdir(parents=True, exist_ok=True)

    # Fetch in chunks
    all_metrics: dict[str, dict] = {}
    current = start_date

    while current < end_date:
        chunk_end = min(current + timedelta(days=chunk_months * 30), end_date)
        start_str = current.strftime("%Y-%m-%d 00:00:00 +0100")
        end_str = chunk_end.strftime("%Y-%m-%d 23:59:59 +0100")

        log.info("Hämtar %s .. %s ...",
                 current.strftime("%Y-%m-%d"), chunk_end.strftime("%Y-%m-%d"))

        data = _query_tcp(start_str, end_str)

        if data and "data" in data and "metrics" in data["data"]:
            metrics = data["data"]["metrics"]
            total_samples = sum(len(m.get("data", [])) for m in metrics)
            log.info("  %d metrics, %d samples", len(metrics), total_samples)

            for m in metrics:
                name = m["name"]
                if name not in all_metrics:
                    all_metrics[name] = {
                        "name": name,
                        "units": m.get("units", ""),
                        "samples": {},
                    }
                for s in m.get("data", []):
                    key = s.get("date", "")
                    all_metrics[name]["samples"][key] = s
        else:
            log.info("  ingen data")

        current = chunk_end + timedelta(days=1)

    # Save one file per metric
    n_written = 0
    for name, info in sorted(all_metrics.items()):
        samples = sorted(info["samples"].values(), key=lambda s: s.get("date", ""))
        if not samples:
            continue

        dates = [s["date"][:10] for s in samples]
        first, last = min(dates), max(dates)

        output = {
            "data": {
                "metrics": [{
                    "name": name,
                    "units": info["units"],
                    "data": samples,
                }]
            }
        }

        filename = f"{name}_{first}_{last}.json"
        filepath = metrics_dir / filename
        with open(filepath, "w") as f:
            json.dump(output, f, ensure_ascii=False)

        log.info("  %s: %d samples", filename, len(samples))
        n_written += 1

    return n_written
