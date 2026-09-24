"""Device log: dated record of which watch/OS version produced the data.

Firmware and watch changes can shift how metrics (HR, cadence, ...) are
computed. ``devices.csv`` in the data repo tracks *when* a device or OS
version changed, so later analysis can correlate a metric shift with a
known device change instead of guessing.

See ``log.py`` for the CSV schema and read/write API, and ``fit_scan.py``
for deriving device-change candidates from historical Garmin FIT files.
"""
