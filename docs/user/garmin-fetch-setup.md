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

Run the script. It will prompt for your Garmin Connect email and password:

```bash
python/.venv/bin/python python/garmin_fetch.py --dry-run
```

If your account has MFA/TOTP enabled, you'll also be prompted for the code.

Credentials are used once to obtain OAuth tokens, which are saved to `$TRANING_DATA/.garmin_tokens/`. Your email and password are **never stored**.

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

**"Rate limited, waiting..."**
The script automatically backs off. Garmin's API has aggressive rate limits. Large backfills may take a while.

**MFA prompt appears unexpectedly**
If you recently enabled two-factor auth on your Garmin account, you'll need to enter the code from your authenticator app.
