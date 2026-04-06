"""API key authentication middleware."""

import os

from fastapi import HTTPException, Security
from fastapi.security import APIKeyHeader

_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def get_api_key() -> str:
    """Return the configured API key, or raise if not set."""
    key = os.environ.get("TRANING_API_KEY")
    if not key:
        raise RuntimeError("TRANING_API_KEY environment variable not set")
    return key


async def require_api_key(api_key: str = Security(_header)) -> str:
    """FastAPI dependency that validates the X-API-Key header."""
    expected = get_api_key()
    if not api_key or api_key != expected:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")
    return api_key
