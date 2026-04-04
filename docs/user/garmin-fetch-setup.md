# Garmin Fetch — Setup Guide

## Prerequisites

- Python 3.10 or later
- A Garmin Connect account
- `TRANING_DATA` environment variable pointing to your data directory

## 1. Create the virtual environment

From the project root:

```bash
bash python/setup_venv.sh
```

This creates `python/.venv/` and installs all dependencies.

Alternatively, do it manually:

```bash
cd python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2. Ensure TRANING_DATA is set

The script reads the same `TRANING_DATA` variable as the R package. If you've already set it in `.Renviron`, export it for your shell:

```bash
export TRANING_DATA="$HOME/Documents/traning-data"
```

Or add it to your `.zshrc` / `.bashrc`.

## 3. First-time authentication

Run the script. It tries three login strategies automatically:

1. **Saved tokens** — instant, no network (subsequent runs)
2. **Native login** — email/password via TLS impersonation
3. **Browser login** — opens Chromium if native login is blocked by Cloudflare

```bash
source python/.venv/bin/activate
python python/garmin_fetch.py --dry-run
```

If native login gets a 429, a browser window opens automatically. Log in
normally (including MFA if needed) — the window closes after login.

OAuth tokens are saved to `$TRANING_DATA/.garmin_tokens/` and reused on
subsequent runs. Your email and password are **never stored**.

### Browser login prerequisites

If the script falls back to browser login, you need Playwright installed:

```bash
pip install playwright && playwright install chromium
```

This is a one-time setup. The `requirements.txt` includes playwright, so
`setup_venv.sh` installs the Python package — but the Chromium browser
binary must be installed separately with `playwright install chromium`.

## 4. Verify

The `--dry-run` flag shows what activities would be fetched without downloading:

```
  [dry-run] 2023-11-19 08:30:00 — Morning Run (id: 12790000001)
  [dry-run] 2023-11-20 17:15:00 — Evening Run (id: 12800000002)
  Done — would fetch 47 new activities
```

If this looks correct, you're ready. See [usage guide](garmin-fetch-usage.md) for next steps.

## Troubleshooting

**"TRANING_DATA is not set"**
Export the variable in your shell, or add it to `.zshrc`.

**"Token login failed" / re-prompted for password**
Tokens expire after extended periods. Just log in again. Or use `--reauth` to force it.

**"Native login blocked by Cloudflare, switching to browser login"**
Garmin's Cloudflare protection blocked the programmatic login. The script
automatically falls back to browser login. If Playwright is not installed,
follow the instructions in the error message.

**"Rate limited, waiting..."**
The script automatically backs off. Garmin's API has aggressive rate limits. Large backfills may take a while.

**MFA prompt appears unexpectedly**
If you recently enabled two-factor auth on your Garmin account, you'll need to enter the code from your authenticator app.
