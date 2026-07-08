"""Central configuration for traning_cli.

Every environment variable previously read ad-hoc via ``os.environ``/
``os.getenv`` across the codebase is declared here, with the exact same
env-var name and default it had before centralization. This module changes
*where* config is read, not *what* it resolves to.

Usage::

    from traning_cli.settings import get_settings

    settings = get_settings()
    data_dir = settings.traning_data  # Path | None

``get_settings()`` is memoized (``lru_cache``) so the environment is only
read once per process. Tests that need a fresh read after monkeypatching
the environment should call ``get_settings.cache_clear()`` first.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


def _read_renviron(path: Path) -> dict[str, str]:
    """Parse a .Renviron file (KEY=VALUE lines, # comments).

    Kept identical to the historical ``garmin/utils.py`` implementation —
    same line-parsing rules, same tolerance for a missing file.
    """
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip()
    return env


def get_project_root() -> Path:
    """Return the traning project root directory.

    settings.py -> traning_cli/ -> python/ -> repo root.
    """
    return Path(__file__).resolve().parent.parent.parent


class Settings(BaseSettings):
    """Single source of truth for env-var-derived configuration.

    Field docs note the historical env var name(s) and default so the
    mapping to the pre-centralization code is traceable at a glance.
    """

    model_config = SettingsConfigDict(
        # Env vars are read explicitly per-field via validation_alias below
        # (the historical names don't share a common prefix), so no
        # env_prefix is set here.
        extra="ignore",
    )

    # -- Data directory -------------------------------------------------
    # TRANING_DATA, env only — no .Renviron fallback here. Several call
    # sites (server/notify.py, server/state.py, mcp/tools.py) historically
    # read only ``os.environ.get("TRANING_DATA")`` with no fallback and no
    # existence check, so this field mirrors that exactly. The .Renviron
    # fallback + directory validation that garmin/utils.py::get_data_dir()
    # applies lives in get_data_dir() below, not in this field, so those
    # other call sites don't gain a fallback they never had.
    traning_data: Path | None = Field(default=None, validation_alias="TRANING_DATA")

    @field_validator("traning_data", mode="before")
    @classmethod
    def _empty_str_is_unset(cls, v: object) -> object:
        # A present-but-empty TRANING_DATA="" matched the old
        # os.environ.get("TRANING_DATA") falsy check (treated as unset).
        # Without this, pydantic would parse "" into Path(".") (truthy),
        # silently making no-fallback sites write into the CWD.
        if isinstance(v, str) and v == "":
            return None
        return v

    # -- Garmin credentials (garmin/auth.py::_get_credentials) ----------
    # Also env-only here; the .Renviron fallback is applied in
    # get_garmin_credentials() below, matching the original's exact order.
    garmin_email: str | None = Field(default=None, validation_alias="GARMIN_EMAIL")
    garmin_password: str | None = Field(default=None, validation_alias="GARMIN_PASSWORD")

    # -- Health Auto Export TCP server (health/utils.py) -----------------
    hae_host: str = Field(default="", validation_alias="HAE_HOST")
    hae_port: int = Field(default=9000, validation_alias="HAE_PORT")

    # -- Receiver client, as used from Vayu/mcp/tools.py::get_pipeline_status
    # host/port default to "" (not their eventual fallback value) so that
    # an env var present-but-empty is indistinguishable from unset — the
    # call site applies `or "127.0.0.1"` / `or "8421"`, exactly matching
    # the historical `os.environ.get(key) or default` there.
    traning_receiver_url: str | None = Field(
        default=None, validation_alias="TRANING_RECEIVER_URL"
    )
    traning_receiver_host: str = Field(
        default="", validation_alias="TRANING_RECEIVER_HOST"
    )
    traning_receiver_port: str = Field(
        default="", validation_alias="TRANING_RECEIVER_PORT"
    )

    # -- API key, shared by server/auth.py and mcp/tools.py --------------
    traning_api_key: str | None = Field(default=None, validation_alias="TRANING_API_KEY")

    # -- Home Assistant notifications (server/notify.py) ------------------
    ha_url: str = Field(default="http://localhost:8123", validation_alias="HA_URL")
    ha_token: str | None = Field(default=None, validation_alias="HA_TOKEN")

    # -- Debounce windows (server/app.py) ---------------------------------
    traning_health_debounce: int = Field(
        default=600, validation_alias="TRANING_HEALTH_DEBOUNCE"
    )
    # Historical default mirrors _DEBOUNCE_SECS (i.e. traning_health_debounce)
    # when TRANING_WORKOUTS_DEBOUNCE is unset — see model_validator below,
    # since the default is dynamic (depends on another field), not static.
    traning_workouts_debounce: int | None = Field(
        default=None, validation_alias="TRANING_WORKOUTS_DEBOUNCE"
    )

    # -- Vayu MCP SSE transport (mcp/server.py::main) ----------------------
    vayu_host: str = Field(default="0.0.0.0", validation_alias="VAYU_HOST")
    vayu_port: int = Field(default=8422, validation_alias="VAYU_PORT")

    @property
    def workouts_debounce_secs(self) -> int:
        """TRANING_WORKOUTS_DEBOUNCE, defaulting to the health debounce.

        Mirrors the historical ``int(os.environ.get("TRANING_WORKOUTS_DEBOUNCE",
        str(_DEBOUNCE_SECS)))`` in server/app.py, where _DEBOUNCE_SECS is
        itself traning_health_debounce.
        """
        if self.traning_workouts_debounce is not None:
            return self.traning_workouts_debounce
        return self.traning_health_debounce

    def get_data_dir(self) -> Path:
        """Return the TRANING_DATA directory, validated to exist.

        Behavior-identical to the historical
        ``garmin/utils.py::get_data_dir()``: env first, then a fallback to
        .Renviron in the project root, then raises OSError if still
        unresolved, or FileNotFoundError if resolved but not a directory.
        """
        raw: str | Path | None = self.traning_data
        if not raw:
            renviron = _read_renviron(get_project_root() / ".Renviron")
            raw = renviron.get("TRANING_DATA")
        if not raw:
            raise OSError(
                "TRANING_DATA is not set. "
                "Add it to .Renviron or export it in your shell."
            )
        p = Path(raw)
        if not p.is_dir():
            raise FileNotFoundError(f"TRANING_DATA directory not found: {p}")
        return p

    def get_garmin_credentials(self) -> tuple[str | None, str | None]:
        """Return (email, password): env first, then .Renviron fallback.

        Behavior-identical to the historical
        ``garmin/auth.py::_get_credentials``'s env/.Renviron merge (the
        interactive prompt fallback stays in garmin/auth.py).
        """
        email = self.garmin_email
        password = self.garmin_password
        if not email or not password:
            renviron = _read_renviron(get_project_root() / ".Renviron")
            if not email:
                email = renviron.get("GARMIN_EMAIL")
            if not password:
                password = renviron.get("GARMIN_PASSWORD")
        return email, password


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide Settings singleton (memoized).

    Reads the environment once per process. Call
    ``get_settings.cache_clear()`` (tests only) to force a re-read after
    monkeypatching the environment.
    """
    return Settings()
