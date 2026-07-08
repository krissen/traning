"""Shared TCP client for the Health Auto Export (HAE) JSON-RPC-ish server.

Consolidates the socket connect / recv-loop / JSON-parse logic that used to
be hand-rolled separately in ``health/tcp.py`` (metrics), ``health/
workouts_tcp.py`` (workouts) and the standalone ``backfill_tcp.py`` script.
All three request a ``callTool`` method with a tool ``name`` and
``arguments`` dict, and all three read the socket until it closes (or the
timeout fires), then parse and unwrap the JSON-RPC ``result.data`` envelope.
"""

import json
import socket

from .utils import hae_host, hae_port

DEFAULT_TIMEOUT = 10.0


class HAEError(RuntimeError):
    """A TCP query to HAE failed in a way that may be transient (warm-up,
    truncated response, network blip). Distinguishes from a successful
    query that genuinely returned no data."""


# Backward-compatible aliases for the pre-unification exception names.
HAEQueryError = HAEError
HAEWorkoutsError = HAEError


def query_hae(name: str, arguments: dict, *, request_id: str = "fetch",
              host: str | None = None, port: int | None = None,
              timeout: float = DEFAULT_TIMEOUT) -> dict:
    """Send a ``callTool`` request to the HAE TCP server and return
    ``data["result"]["data"]``.

    Args:
        name: the HAE tool name, e.g. ``"health_metrics"`` or ``"workouts"``.
        arguments: the tool-specific ``arguments`` dict (e.g. ``start``/
            ``end``/``aggregate`` for metrics, ``start``/``end``/
            ``includeMetadata`` for workouts).
        request_id: the JSON-RPC ``id`` field. Cosmetic only.
        host: override HAE host; defaults to ``settings.hae_host``.
        port: override HAE port; defaults to ``settings.hae_port``.
        timeout: socket timeout in seconds.

    Returns:
        The parsed ``result.data`` body (typically ``{"metrics": [...]}``
        or ``{"workouts": [...]}``) — possibly empty if HAE has no data for
        the requested window.

    Raises:
        HAEError: on connection / parse / shape failures, so callers can
            distinguish those from genuinely empty responses and retry.
    """
    request_host = host if host is not None else hae_host()
    request_port = port if port is not None else hae_port()

    params: dict = {"name": name}
    # health_metrics historically also carries a top-level empty "metrics"
    # key in params (unused by HAE, but preserved to keep the request
    # identical to the pre-unification behavior).
    if name == "health_metrics":
        params["metrics"] = ""
    params["arguments"] = arguments

    request = json.dumps({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "callTool",
        "params": params,
    })

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((request_host, request_port))
        sock.sendall(request.encode("utf-8"))

        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            except TimeoutError:
                break
        sock.close()
    except (TimeoutError, ConnectionError, OSError) as e:
        raise HAEError(f"connection error: {e}") from e

    raw = b"".join(chunks)
    if len(raw) < 10:
        raise HAEError(
            f"empty/short response ({len(raw)} bytes) — HAE likely warming up"
        )

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        excerpt = raw[:200].decode("utf-8", errors="replace")
        raise HAEError(
            f"JSON parse failed at byte {e.pos}/{len(raw)}: {e.msg}; "
            f"first 200 bytes: {excerpt!r}"
        ) from e

    # tcp.py historically checked for a top-level "error" key (JSON-RPC
    # convention); workouts_tcp.py checked inside "result" instead. Both
    # checks are kept — a superset, not a behavior change, since a
    # well-formed HAE error response only ever populates one of the two.
    if "error" in data:
        raise HAEError(f"HAE returned error: {data['error']}")
    if "result" not in data:
        raise HAEError(
            f"unexpected response shape: top-level keys {list(data)}"
        )
    result = data["result"]
    if "error" in result:
        raise HAEError(f"HAE error: {result['error']}")
    if "data" not in result:
        raise HAEError(
            f"unexpected response shape: top-level keys {list(data)}"
        )

    return result["data"]


def check_server(timeout: float = 3.0) -> bool:
    """Check if the HAE TCP server is reachable."""
    host, port = hae_host(), hae_port()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.close()
        return True
    except (TimeoutError, ConnectionRefusedError, OSError):
        return False
