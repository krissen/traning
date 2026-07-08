"""Tests for the centralized Settings object (traning_cli.settings).

Behavior-preservation is the point of this module: every field must read
the exact env var name the pre-centralization code read, with the exact
same default and (where applicable) the exact same .Renviron fallback
order. These tests pin that contract down.
"""


from traning_cli.settings import Settings, get_settings

# ---------------------------------------------------------------------------
# Env var -> field mapping (representative sample + full sweep)
# ---------------------------------------------------------------------------


def test_hae_host_and_port_read_from_env(monkeypatch):
    monkeypatch.setenv("HAE_HOST", "hae.example.com")
    monkeypatch.setenv("HAE_PORT", "9999")
    s = Settings()
    assert s.hae_host == "hae.example.com"
    assert s.hae_port == 9999


def test_hae_port_default_matches_historical_default(monkeypatch):
    monkeypatch.delenv("HAE_PORT", raising=False)
    s = Settings()
    assert s.hae_port == 9000


def test_ha_url_and_token_read_from_env(monkeypatch):
    monkeypatch.setenv("HA_URL", "https://ha.example.com")
    monkeypatch.setenv("HA_TOKEN", "supersecret")
    s = Settings()
    assert s.ha_url == "https://ha.example.com"
    assert s.ha_token == "supersecret"


def test_ha_url_default_matches_historical_default(monkeypatch):
    monkeypatch.delenv("HA_URL", raising=False)
    s = Settings()
    assert s.ha_url == "http://localhost:8123"


def test_traning_api_key_read_from_env(monkeypatch):
    monkeypatch.setenv("TRANING_API_KEY", "abc123")
    s = Settings()
    assert s.traning_api_key == "abc123"


def test_traning_api_key_unset_is_none(monkeypatch):
    monkeypatch.delenv("TRANING_API_KEY", raising=False)
    s = Settings()
    assert s.traning_api_key is None


def test_health_debounce_read_from_env(monkeypatch):
    monkeypatch.setenv("TRANING_HEALTH_DEBOUNCE", "300")
    s = Settings()
    assert s.traning_health_debounce == 300


def test_health_debounce_default_matches_historical_default(monkeypatch):
    monkeypatch.delenv("TRANING_HEALTH_DEBOUNCE", raising=False)
    s = Settings()
    assert s.traning_health_debounce == 600


def test_workouts_debounce_falls_back_to_health_debounce(monkeypatch):
    """Historical: TRANING_WORKOUTS_DEBOUNCE defaults to _DEBOUNCE_SECS
    (the health debounce), not a fixed literal."""
    monkeypatch.delenv("TRANING_WORKOUTS_DEBOUNCE", raising=False)
    monkeypatch.setenv("TRANING_HEALTH_DEBOUNCE", "42")
    s = Settings()
    assert s.workouts_debounce_secs == 42


def test_workouts_debounce_explicit_env_overrides_fallback(monkeypatch):
    monkeypatch.setenv("TRANING_HEALTH_DEBOUNCE", "600")
    monkeypatch.setenv("TRANING_WORKOUTS_DEBOUNCE", "120")
    s = Settings()
    assert s.workouts_debounce_secs == 120


def test_vayu_host_and_port_defaults(monkeypatch):
    monkeypatch.delenv("VAYU_HOST", raising=False)
    monkeypatch.delenv("VAYU_PORT", raising=False)
    s = Settings()
    assert s.vayu_host == "0.0.0.0"
    assert s.vayu_port == 8422


def test_vayu_host_and_port_read_from_env(monkeypatch):
    monkeypatch.setenv("VAYU_HOST", "127.0.0.1")
    monkeypatch.setenv("VAYU_PORT", "9001")
    s = Settings()
    assert s.vayu_host == "127.0.0.1"
    assert s.vayu_port == 9001


def test_receiver_fields_default_to_empty_not_final_fallback(monkeypatch):
    """host/port default to "" so present-but-empty env vars are
    indistinguishable from unset at the call site (mcp/tools.py applies
    `or "127.0.0.1"` / `or "8421"` itself, matching the historical
    ``os.environ.get(key) or default`` there)."""
    monkeypatch.delenv("TRANING_RECEIVER_URL", raising=False)
    monkeypatch.delenv("TRANING_RECEIVER_HOST", raising=False)
    monkeypatch.delenv("TRANING_RECEIVER_PORT", raising=False)
    s = Settings()
    assert s.traning_receiver_url is None
    assert s.traning_receiver_host == ""
    assert s.traning_receiver_port == ""


def test_receiver_fields_read_from_env(monkeypatch):
    monkeypatch.setenv("TRANING_RECEIVER_URL", "http://100.1.2.3:8421")
    monkeypatch.setenv("TRANING_RECEIVER_HOST", "100.1.2.3")
    monkeypatch.setenv("TRANING_RECEIVER_PORT", "8421")
    s = Settings()
    assert s.traning_receiver_url == "http://100.1.2.3:8421"
    assert s.traning_receiver_host == "100.1.2.3"
    assert s.traning_receiver_port == "8421"


# ---------------------------------------------------------------------------
# traning_data: env-only field, no .Renviron fallback baked in
# ---------------------------------------------------------------------------


def test_traning_data_field_is_env_only_no_renviron_fallback(monkeypatch, tmp_path):
    """server/notify.py, server/state.py and mcp/tools.py historically read
    only os.environ.get("TRANING_DATA") with no .Renviron fallback. The
    ``traning_data`` field must replicate that exactly — only
    get_data_dir() (below) applies the fallback."""
    monkeypatch.delenv("TRANING_DATA", raising=False)
    s = Settings()
    assert s.traning_data is None


def test_traning_data_field_reads_env_when_set(monkeypatch, tmp_path):
    monkeypatch.setenv("TRANING_DATA", str(tmp_path))
    s = Settings()
    assert s.traning_data == tmp_path


# ---------------------------------------------------------------------------
# get_data_dir(): env -> .Renviron fallback -> validation (matches the
# historical garmin/utils.py::get_data_dir exactly)
# ---------------------------------------------------------------------------


def test_get_data_dir_prefers_env_over_renviron(monkeypatch, tmp_path):
    env_dir = tmp_path / "env_data"
    env_dir.mkdir()
    monkeypatch.setenv("TRANING_DATA", str(env_dir))
    s = Settings()
    assert s.get_data_dir() == env_dir


def test_get_data_dir_falls_back_to_renviron(monkeypatch, tmp_path):
    """When TRANING_DATA is unset, get_data_dir() parses .Renviron in the
    project root — same file/order the historical implementation used."""
    monkeypatch.delenv("TRANING_DATA", raising=False)

    renviron_dir = tmp_path / "renviron_data"
    renviron_dir.mkdir()

    from traning_cli import settings as settings_mod

    monkeypatch.setattr(settings_mod, "get_project_root", lambda: tmp_path)
    (tmp_path / ".Renviron").write_text(f"TRANING_DATA={renviron_dir}\n")

    s = Settings()
    assert s.get_data_dir() == renviron_dir


def test_get_data_dir_raises_oserror_when_fully_unresolved(monkeypatch, tmp_path):
    monkeypatch.delenv("TRANING_DATA", raising=False)

    from traning_cli import settings as settings_mod

    monkeypatch.setattr(settings_mod, "get_project_root", lambda: tmp_path)
    # No .Renviron file at all in tmp_path.

    s = Settings()
    try:
        s.get_data_dir()
        raise AssertionError("expected OSError")
    except OSError:
        pass


def test_get_data_dir_raises_filenotfound_when_dir_missing(monkeypatch, tmp_path):
    missing = tmp_path / "does_not_exist"
    monkeypatch.setenv("TRANING_DATA", str(missing))
    s = Settings()
    try:
        s.get_data_dir()
        raise AssertionError("expected FileNotFoundError")
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------------------
# get_garmin_credentials(): env -> .Renviron fallback (per-field)
# ---------------------------------------------------------------------------


def test_get_garmin_credentials_prefers_env(monkeypatch):
    monkeypatch.setenv("GARMIN_EMAIL", "env@example.com")
    monkeypatch.setenv("GARMIN_PASSWORD", "envpass")
    s = Settings()
    assert s.get_garmin_credentials() == ("env@example.com", "envpass")


def test_get_garmin_credentials_falls_back_to_renviron(monkeypatch, tmp_path):
    monkeypatch.delenv("GARMIN_EMAIL", raising=False)
    monkeypatch.delenv("GARMIN_PASSWORD", raising=False)

    from traning_cli import settings as settings_mod

    monkeypatch.setattr(settings_mod, "get_project_root", lambda: tmp_path)
    (tmp_path / ".Renviron").write_text(
        "GARMIN_EMAIL=renviron@example.com\nGARMIN_PASSWORD=renvpass\n"
    )

    s = Settings()
    assert s.get_garmin_credentials() == ("renviron@example.com", "renvpass")


def test_get_garmin_credentials_missing_both_returns_none_none(monkeypatch, tmp_path):
    monkeypatch.delenv("GARMIN_EMAIL", raising=False)
    monkeypatch.delenv("GARMIN_PASSWORD", raising=False)

    from traning_cli import settings as settings_mod

    monkeypatch.setattr(settings_mod, "get_project_root", lambda: tmp_path)
    # No .Renviron in tmp_path.

    s = Settings()
    assert s.get_garmin_credentials() == (None, None)


# ---------------------------------------------------------------------------
# get_settings() singleton / caching
# ---------------------------------------------------------------------------


def test_get_settings_returns_same_instance_until_cache_cleared(monkeypatch):
    get_settings.cache_clear()
    monkeypatch.setenv("HAE_HOST", "first")
    first = get_settings()
    assert first.hae_host == "first"

    monkeypatch.setenv("HAE_HOST", "second")
    second = get_settings()
    assert second is first
    assert second.hae_host == "first"  # stale until cache_clear()

    get_settings.cache_clear()
    third = get_settings()
    assert third is not first
    assert third.hae_host == "second"
    get_settings.cache_clear()


def test_read_renviron_helper_parses_comments_and_blank_lines(tmp_path):
    from traning_cli.settings import _read_renviron

    p = tmp_path / ".Renviron"
    p.write_text(
        "# comment\n"
        "\n"
        "TRANING_DATA=/some/path\n"
        "GARMIN_EMAIL = spaced@example.com \n"
    )
    parsed = _read_renviron(p)
    assert parsed["TRANING_DATA"] == "/some/path"
    assert parsed["GARMIN_EMAIL"] == "spaced@example.com"


def test_read_renviron_missing_file_returns_empty_dict(tmp_path):
    from traning_cli.settings import _read_renviron

    parsed = _read_renviron(tmp_path / "does_not_exist.Renviron")
    assert parsed == {}


def test_traning_data_empty_string_is_unset(monkeypatch):
    # A present-but-empty TRANING_DATA must resolve to None (falsy),
    # matching the pre-centralization os.environ.get behavior — not Path(".").
    from traning_cli.settings import Settings

    monkeypatch.setenv("TRANING_DATA", "")
    assert Settings().traning_data is None
