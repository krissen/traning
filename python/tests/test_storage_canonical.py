"""Canonical deduplication: what survives a merge and what does not.

The cases here are the ones that were seen in real data, not invented
ones. Sample shapes are copied from an HAE per-sample fetch of
dietary_energy / alcohol_consumption (DrinkControl), 2026-08-21..09-05.
"""

import json

import pytest
from traning_cli.server.storage import (
    canonicalize_paths,
    save_health_push,
)


def _energy(ts, qty, food_type=None, source="DrinkControl"):
    """One dietary_energy sample as HAE writes it."""
    s = {"date": ts, "start": ts, "end": ts, "source": source, "qty": qty}
    if food_type is not None:
        s["foodType"] = food_type
    return s


def _aggregate(ts, qty, source="DrinkControl"):
    """One minute-aggregated sample: no foodType, no start/end."""
    return {"date": ts, "source": source, "qty": qty}


def _payload(metric, units, samples):
    return {"data": {"metrics": [
        {"name": metric, "units": units, "data": samples}
    ]}}


def _canonical(tmp_path, metric, date):
    path = (tmp_path / "kristian" / "health_export" / "canonical"
            / metric / f"{date}.json")
    with open(path) as f:
        return json.load(f)


# -- concurrent samples -------------------------------------------------------

def test_three_samples_same_second_all_survive(tmp_path):
    """DrinkControl stamps a logging session with one second per drink."""
    ts = "2026-08-21 23:50:53 +0200"
    samples = [
        _energy(ts, 762.8036283266603, "beer, 660ml 5,0%"),
        _energy(ts, 346.7289090500049, "wine, 125ml 12,0%"),
        _energy(ts, 924.6104585777697, "beer, 800ml 5,0%"),
    ]
    save_health_push(_payload("dietary_energy", "kJ", samples), tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-08-21")
    assert len(doc["samples"]) == 3
    assert sum(s["qty"] for s in doc["samples"]) == pytest.approx(2034.14, abs=0.01)


def test_food_type_survives_canonicalization(tmp_path):
    """Type, volume and strength ride along in foodType — do not strip."""
    ts = "2026-08-28 18:44:42 +0200"
    save_health_push(
        _payload("dietary_energy", "kJ",
                 [_energy(ts, 724.6634270186742, "beer, 330ml 9,5%")]),
        tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-08-28")
    assert doc["samples"][0]["foodType"] == "beer, 330ml 9,5%"
    assert doc["samples"][0]["start"] == ts
    assert doc["samples"][0]["end"] == ts


def test_identical_samples_in_one_push_both_survive(tmp_path):
    """Two identical beers logged in the same second (seen 2026-08-28)."""
    ts = "2026-08-28 17:49:12 +0200"
    beer = _energy(ts, 462.30522928888485, "beer, 400ml 5,0%")
    save_health_push(_payload("dietary_energy", "kJ", [beer, dict(beer)]),
                     tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-08-28")
    assert len(doc["samples"]) == 2


# -- idempotence --------------------------------------------------------------

def test_double_push_adds_nothing(tmp_path):
    ts = "2026-08-21 23:50:53 +0200"
    payload = _payload("dietary_energy", "kJ", [
        _energy(ts, 762.8036283266603, "beer, 660ml 5,0%"),
        _energy(ts, 346.7289090500049, "wine, 125ml 12,0%"),
    ])
    save_health_push(payload, tmp_path)
    _, changed = save_health_push(payload, tmp_path)

    assert changed == []
    assert len(_canonical(tmp_path, "dietary_energy", "2026-08-21")["samples"]) == 2


def test_double_push_of_identical_samples_stays_at_two(tmp_path):
    """Multiplicity is preserved, not multiplied."""
    ts = "2026-08-28 17:49:12 +0200"
    beer = _energy(ts, 462.30522928888485, "beer, 400ml 5,0%")
    payload = _payload("dietary_energy", "kJ", [beer, dict(beer)])
    save_health_push(payload, tmp_path)
    save_health_push(payload, tmp_path)

    assert len(_canonical(tmp_path, "dietary_energy", "2026-08-28")["samples"]) == 2


def test_key_order_does_not_create_duplicates(tmp_path):
    """HAE emits the same sample with fields in varying order."""
    ts = "2026-09-04 23:17:05 +0200"
    a = {"date": ts, "start": ts, "end": ts, "source": "DrinkControl",
         "qty": 762.8036283266603, "foodType": "beer, 660ml 5,0%"}
    b = {"foodType": "beer, 660ml 5,0%", "qty": 762.8036283266603,
         "source": "DrinkControl", "end": ts, "start": ts, "date": ts}
    save_health_push(_payload("dietary_energy", "kJ", [a]), tmp_path)
    save_health_push(_payload("dietary_energy", "kJ", [b]), tmp_path)

    assert len(_canonical(tmp_path, "dietary_energy", "2026-09-04")["samples"]) == 1


# -- aggregate beside per-sample detail: reported, never removed -------------

def test_aggregate_and_detail_both_survive(tmp_path):
    """The 2026-09-05 case: pushed aggregate at :00, fetched detail at :35.

    Append-only. The day now reads double and says so in the log; the
    operator resolves it with --replace-source-days.
    """
    save_health_push(
        _payload("dietary_energy", "kJ",
                 [_aggregate("2026-09-05 18:44:00 +0200", 1768.3175020299848)]),
        tmp_path)
    save_health_push(
        _payload("dietary_energy", "kJ", [
            _energy("2026-09-05 18:44:35 +0200", 381.40181416333013,
                    "beer, 330ml 5,0%"),
            _energy("2026-09-05 18:44:35 +0200", 1386.9156878666547,
                    "wine, 500ml 12,0%"),
        ]),
        tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-09-05")
    assert len(doc["samples"]) == 3


def test_suspected_aggregate_warns_once_on_write(tmp_path, caplog):
    save_health_push(
        _payload("dietary_energy", "kJ",
                 [_aggregate("2026-09-05 18:44:00 +0200", 500.0)]),
        tmp_path)

    with caplog.at_level("WARNING"):
        save_health_push(
            _payload("dietary_energy", "kJ",
                     [_energy("2026-09-05 18:44:35 +0200", 500.0,
                              "beer, 440ml 5,0%")]),
            tmp_path)
    warnings = [r.getMessage() for r in caplog.records
                if r.levelname == "WARNING"]
    assert len(warnings) == 1
    for expected in ("dietary_energy", "2026-09-05", "18:44", "DrinkControl"):
        assert expected in warnings[0]

    # Nothing changes on a repeat push, so the warning does not repeat.
    caplog.clear()
    with caplog.at_level("WARNING"):
        save_health_push(
            _payload("dietary_energy", "kJ",
                     [_energy("2026-09-05 18:44:35 +0200", 500.0,
                              "beer, 440ml 5,0%")]),
            tmp_path)
    assert [r for r in caplog.records if r.levelname == "WARNING"] == []


def test_bare_samples_in_one_minute_do_not_warn(tmp_path, caplog):
    """Nothing distinguishes them, so there is nothing to report."""
    with caplog.at_level("WARNING"):
        save_health_push(
            _payload("alcohol_consumption", "count",
                     [_aggregate("2026-09-02 20:00:00 +0200", 1.7),
                      _aggregate("2026-09-02 20:00:31 +0200", 1.7)]),
            tmp_path)

    doc = _canonical(tmp_path, "alcohol_consumption", "2026-09-02")
    assert len(doc["samples"]) == 2
    assert doc["daily_total"] == pytest.approx(3.4)
    assert [r for r in caplog.records if r.levelname == "WARNING"] == []


def test_a_later_push_never_removes_a_persisted_sample(tmp_path):
    """Counts never shrink on the merge path."""
    save_health_push(
        _payload("dietary_energy", "kJ",
                 [_aggregate("2026-09-02 20:00:00 +0200", 500.0)]),
        tmp_path)
    save_health_push(
        _payload("dietary_energy", "kJ",
                 [_aggregate("2026-09-02 20:00:44 +0200", 500.0)]),
        tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-09-02")
    assert len(doc["samples"]) == 2


def test_detailed_sample_at_whole_minute_is_kept(tmp_path):
    """A real drink logged at exactly :00 beside another in the minute."""
    save_health_push(
        _payload("dietary_energy", "kJ",
                 [_energy("2026-09-02 20:00:00 +0200", 500.0, "beer, 440ml 5,0%"),
                  _energy("2026-09-02 20:00:31 +0200", 500.0, "beer, 440ml 5,0%")]),
        tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-09-02")
    assert len(doc["samples"]) == 2


def test_daily_total_matches_surviving_samples(tmp_path):
    save_health_push(
        _payload("alcohol_consumption", "count", [
            _aggregate("2026-08-28 17:49:12 +0200", 3.2),
            _aggregate("2026-08-28 18:10:59 +0200", 1.7),
            _aggregate("2026-08-28 18:44:42 +0200", 2.5),
        ]),
        tmp_path)

    doc = _canonical(tmp_path, "alcohol_consumption", "2026-08-28")
    assert len(doc["samples"]) == 3
    assert doc["daily_total"] == pytest.approx(7.4)


# -- CLI-facing helper --------------------------------------------------------

def test_canonicalize_paths_reads_a_directory(tmp_path):
    src = tmp_path / "incoming"
    src.mkdir()
    (src / "dietary_energy_2026-08-21_2026-08-21.json").write_text(json.dumps(
        _payload("dietary_energy", "kJ", [
            _energy("2026-08-21 23:50:53 +0200", 762.8, "beer, 660ml 5,0%"),
            _energy("2026-08-21 23:50:53 +0200", 346.7, "wine, 125ml 12,0%"),
        ])))
    (src / "not-hae.json").write_text('{"hello": "world"}')

    n_files, n_metrics, changed = canonicalize_paths([src], data_dir=tmp_path)

    assert (n_files, n_metrics, len(changed)) == (1, 1, 1)
    assert len(_canonical(tmp_path, "dietary_energy", "2026-08-21")["samples"]) == 2


def test_canonicalize_paths_dry_run_writes_nothing(tmp_path):
    f = tmp_path / "one.json"
    f.write_text(json.dumps(_payload("dietary_energy", "kJ", [
        _energy("2026-08-21 23:50:53 +0200", 762.8, "beer, 660ml 5,0%")])))

    n_files, n_metrics, changed = canonicalize_paths(
        [f], data_dir=tmp_path, dry_run=True)

    assert (n_files, n_metrics, changed) == (1, 1, [])
    assert not (tmp_path / "kristian" / "health_export" / "canonical").exists()


def test_canonicalize_paths_accepts_bare_metrics_envelope(tmp_path):
    f = tmp_path / "bare.json"
    f.write_text(json.dumps({"metrics": [
        {"name": "alcohol_consumption", "units": "count",
         "data": [_aggregate("2026-08-29 21:06:07 +0200", 8.1)]}
    ]}))

    n_files, _, changed = canonicalize_paths([f], data_dir=tmp_path)

    assert n_files == 1 and len(changed) == 1
    assert _canonical(tmp_path, "alcohol_consumption",
                      "2026-08-29")["daily_total"] == pytest.approx(8.1)


def test_dry_run_counts_only_metrics_that_would_be_written(tmp_path):
    """A nameless or empty group is skipped on the real run."""
    f = tmp_path / "mixed.json"
    f.write_text(json.dumps({"data": {"metrics": [
        {"name": "dietary_energy", "units": "kJ",
         "data": [_energy("2026-08-21 23:50:53 +0200", 762.8, "beer, 660ml")]},
        {"name": "", "units": "count", "data": [_aggregate("2026-08-21 23:50:53 +0200", 1)]},
        {"name": "alcohol_consumption", "units": "count", "data": []},
        "not a dict",
    ]}}))

    n_files, n_metrics, _ = canonicalize_paths(
        [f], data_dir=tmp_path, dry_run=True)

    assert (n_files, n_metrics) == (1, 1)


def test_dry_run_count_matches_the_real_run(tmp_path):
    f = tmp_path / "mixed.json"
    f.write_text(json.dumps({"data": {"metrics": [
        {"name": "dietary_energy", "units": "kJ",
         "data": [_energy("2026-08-21 23:50:53 +0200", 762.8, "beer, 660ml")]},
        {"name": None, "units": "count", "data": [_aggregate("2026-08-21 23:50:53 +0200", 1)]},
    ]}}))

    _, dry_metrics, _ = canonicalize_paths([f], data_dir=tmp_path, dry_run=True)
    _, real_metrics, _ = canonicalize_paths([f], data_dir=tmp_path)

    assert dry_metrics == real_metrics == 1


def test_unwritable_metric_group_does_not_abort_the_push(tmp_path):
    """A truncated group costs itself, not the file it travelled in."""
    save_health_push({"data": {"metrics": [
        "not a dict",
        {"name": "alcohol_consumption", "units": "count",
         "data": [_aggregate("2026-08-29 21:06:07 +0200", 8.1)]},
    ]}}, tmp_path)

    doc = _canonical(tmp_path, "alcohol_consumption", "2026-08-29")
    assert doc["daily_total"] == pytest.approx(8.1)


def test_changed_files_are_not_repeated_across_inputs(tmp_path):
    """Two input files covering the same day touch one canonical file."""
    for i, qty in enumerate([381.40181416333013, 1386.9156878666547]):
        (tmp_path / f"part{i}.json").write_text(json.dumps(
            _payload("dietary_energy", "kJ",
                     [_energy("2026-09-05 18:44:35 +0200", qty, f"beer {i}")])))

    _, _, changed = canonicalize_paths(
        [tmp_path / "part0.json", tmp_path / "part1.json"], data_dir=tmp_path)

    assert len(changed) == len(set(changed)) == 1
    assert len(_canonical(tmp_path, "dietary_energy", "2026-09-05")["samples"]) == 2
