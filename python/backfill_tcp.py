#!/usr/bin/env python3
"""Backfill all health metrics from HAE TCP server to local JSON files."""

import json
import socket
import sys
import os
from datetime import datetime, timedelta
from pathlib import Path

HOST = "192.168.0.146"
PORT = 9000
TIMEOUT = 30

DATA_DIR = Path(os.environ.get(
    "TRANING_DATA",
    os.path.expanduser("~/Documents/traning-data")
)) / "kristian" / "health_export" / "metrics"


def query_tcp(start: str, end: str, aggregate: bool = True,
              interval: str = "days") -> dict | None:
    """Send a query to HAE TCP server and return parsed JSON response."""
    request = json.dumps({
        "jsonrpc": "2.0",
        "id": "backfill",
        "method": "callTool",
        "params": {
            "name": "health_metrics",
            "metrics": "",
            "arguments": {
                "start": start,
                "end": end,
                "interval": interval,
                "aggregate": aggregate,
            }
        }
    })

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT)
        sock.connect((HOST, PORT))
        sock.sendall(request.encode("utf-8"))

        # Read until connection closed
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
        # Unwrap JSON-RPC result to match HAE file export format
        if "result" in data and "data" in data["result"]:
            return {"data": data["result"]["data"]}
        return None

    except Exception as e:
        print(f"  ERROR: {e}")
        return None


def backfill(start_year: int = 2013, end_date: str = "2026-04-05",
             chunk_months: int = 3):
    """Download all metrics in chunks and save as JSON files."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    current = datetime(start_year, 1, 1)
    end = datetime.strptime(end_date, "%Y-%m-%d")

    all_metrics = {}  # metric_name -> {date -> sample}

    while current < end:
        chunk_end = min(
            current + timedelta(days=chunk_months * 30),
            end
        )

        start_str = current.strftime("%Y-%m-%d 00:00:00 +0100")
        end_str = chunk_end.strftime("%Y-%m-%d 23:59:59 +0100")

        print(f"Hämtar {current.strftime('%Y-%m-%d')} .. "
              f"{chunk_end.strftime('%Y-%m-%d')} ... ", end="", flush=True)

        data = query_tcp(start_str, end_str)

        if data and "data" in data and "metrics" in data["data"]:
            metrics = data["data"]["metrics"]
            total_samples = sum(len(m.get("data", [])) for m in metrics)
            print(f"{len(metrics)} metrics, {total_samples} samples")

            for m in metrics:
                name = m["name"]
                if name not in all_metrics:
                    all_metrics[name] = {
                        "name": name,
                        "units": m.get("units", ""),
                        "samples": {}
                    }
                for s in m.get("data", []):
                    # Dedup by date
                    key = s.get("date", "")
                    all_metrics[name]["samples"][key] = s
        else:
            print("ingen data")

        current = chunk_end + timedelta(days=1)

    # Save one file per metric
    print(f"\nSparar {len(all_metrics)} metrics...")
    for name, info in sorted(all_metrics.items()):
        samples = sorted(info["samples"].values(),
                         key=lambda s: s.get("date", ""))
        if not samples:
            continue

        dates = [s["date"][:10] for s in samples]
        first, last = min(dates), max(dates)

        output = {
            "data": {
                "metrics": [{
                    "name": name,
                    "units": info["units"],
                    "data": samples
                }]
            }
        }

        filename = f"{name}_{first}_{last}.json"
        filepath = DATA_DIR / filename
        with open(filepath, "w") as f:
            json.dump(output, f, ensure_ascii=False)

        print(f"  {filename}: {len(samples)} samples")

    print("\nKlart!")


if __name__ == "__main__":
    backfill()
