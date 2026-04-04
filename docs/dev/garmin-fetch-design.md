# Garmin Fetch — Design Document

## Architecture

```
garmin_fetch.py     CLI entry point (argparse, exit codes)
    ├── garmin_auth.py       Authentication (Garmin class, token persistence)
    ├── garmin_download.py   Activity listing, download, symlink creation
    └── garmin_utils.py      Naming conventions, paths, logging
```

Four modules, single responsibility each. No package structure (`__init__.py`) — this is a utility script, not a library.

## Dependencies

- `garminconnect` — Garmin Connect API client (wraps `garth` internally)
- `garth` — OAuth authentication with token persistence (transitive dep)
- `requests` — HTTP client (transitive dep, listed explicitly)

## File naming convention

Matches the existing convention established by previous Garmin Connect bulk exports:

| File | Pattern | Example |
|------|---------|---------|
| Summary JSON | `{ISO8601}_{activityId}_summary.json` | `2023-11-18T19:48:49+00:00_12784482085_summary.json` |
| Details JSON | `{ISO8601}_{activityId}_details.json` | `2023-11-18T19:48:49+00:00_12784482085_details.json` |
| TCX | `{ISO8601}_{activityId}.tcx` | `2023-11-18T19:48:49+00:00_12784482085.tcx` |
| Symlink | `YYYYMMDD-HHMMSS.tcx` | `20231118-194849.tcx` |

The timestamp comes from the activity's `startTimeGMT` field. The API returns it as `"2023-11-18 19:48:49"` — we convert to ISO 8601 by replacing the space with `T` and appending `+00:00`.

## Symlink strategy

Symlinks in `tcx/` use relative paths: `../gconnect/{filename}.tcx`. This makes them portable within the data repo. The R import pipeline (`get_my_files()`) follows symlinks transparently when globbing for `*.tcx`.

## Incremental fetching

The script determines what has been fetched by scanning `gconnect/*_summary.json` filenames and extracting activity IDs. No database is needed.

Activities are fetched from the API in reverse chronological order. The script stops when it encounters 10 consecutive already-known activity IDs (indicating we've caught up). The `--all` flag disables this early-stop.

## Rate limiting

Garmin Connect has undocumented rate limits. The script:
- Waits 1 second between API calls
- On HTTP 429, uses exponential backoff: 2s, 4s, 8s, 16s, 32s, max 60s
- Retries up to 5 times per request

## Token management

Tokens are stored in `$TRANING_DATA/.garmin_tokens/` (outside the code repo). The code repo is public; the data repo is private.

Token lifecycle:
1. First run: interactive login → tokens saved by `garminconnect`
2. Subsequent runs: tokens loaded automatically
3. Token expiry: detected on first API call → prompts for re-login
4. `--reauth` flag: skips token load, forces interactive login

## Error handling

| Error | Behaviour |
|-------|-----------|
| Auth failure | Exit code 1, clear message |
| Network/API error | Exit code 2, logged with traceback |
| Missing TRANING_DATA | Exit code 3, clear message |
| Single activity fails | Log warning, continue to next |
| Rate limit (429) | Exponential backoff, retry up to 5× |

Partial downloads (e.g. TCX succeeded but details failed) leave whatever was saved. Re-running the script won't re-download activities whose summary JSON already exists.

## Integration with R

No R code changes. The output matches what `get_my_files()` and `get_new_workouts()` expect:
1. Python writes TCX to `gconnect/` + symlink in `tcx/`
2. R's `get_my_files()` globs `*.tcx` in `tcx/` (follows symlinks)
3. R's `get_new_workouts()` checks `summaries$file` to skip known files

## Extending

To add new export formats (GPX, FIT): add download calls in `_download_activity()` using `client.download_activity(id, dl_fmt=ActivityDownloadFormat.GPX)`.

To add new data types (sleep, body composition): add new functions in `garmin_download.py` using the appropriate `client.get_*()` methods.
