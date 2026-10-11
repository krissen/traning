"""Minimal stdlib client for Health Auto Export's in-app MCP server.

Streamable HTTP MCP: initialize -> notifications/initialized -> tools/call.
The server runs one tool call at a time; a call it cannot finish blocks
every later call, so callers should keep windows small and stop at the
first timeout instead of queueing more work behind it.

Environment:
    HAE_TOKEN  bearer token from the app's Server screen (required)
    HAE_URL    endpoint, default http://192.168.0.146:9000/mcp
"""

import json
import os
import urllib.request

PROTOCOL_VERSION = "2025-06-18"
URL = os.environ.get("HAE_URL", "http://192.168.0.146:9000/mcp")

_session: str | None = None
_next_id = 0


def _post(payload: dict, timeout: float) -> dict | None:
    global _session
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    req.add_header("Authorization", f"Bearer {os.environ['HAE_TOKEN']}")
    req.add_header("MCP-Protocol-Version", PROTOCOL_VERSION)
    if _session:
        req.add_header("Mcp-Session-Id", _session)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        _session = resp.headers.get("Mcp-Session-Id") or _session
        raw = resp.read().decode("utf-8", errors="replace")
        ctype = resp.headers.get("Content-Type", "")
    if not raw.strip():
        return None
    if "text/event-stream" in ctype:
        for line in raw.splitlines():
            if line.startswith("data:") and line[5:].strip():
                msg = json.loads(line[5:])
                if "id" in msg:
                    return msg
        return None
    return json.loads(raw)


def _rpc(method: str, params: dict, timeout: float) -> dict:
    global _next_id
    _next_id += 1
    msg = _post({"jsonrpc": "2.0", "id": _next_id, "method": method, "params": params}, timeout)
    if msg is None or "error" in msg:
        raise RuntimeError(f"{method}: {msg}")
    return msg.get("result", {})


def init(timeout: float = 30) -> None:
    _rpc(
        "initialize",
        {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "traning-analysis", "version": "1"},
        },
        timeout,
    )
    _post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, timeout)


def call(name: str, args: dict, timeout: float = 60) -> dict:
    """Call one tool and return its JSON body."""
    r = _rpc("tools/call", {"name": name, "arguments": args}, timeout)
    if r.get("isError"):
        raise RuntimeError(str(r.get("content"))[:400])
    if isinstance(r.get("structuredContent"), dict):
        return r["structuredContent"]
    for block in r.get("content", []):
        if block.get("type") == "text":
            return json.loads(block["text"])
    raise RuntimeError(f"no body in {list(r)}")
