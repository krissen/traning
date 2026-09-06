"""Canonical deduplication: what survives a merge and what does not.

The cases here are the ones that were seen in real data, not invented
ones. Sample shapes are copied from an HAE per-sample fetch of
dietary_energy / alcohol_consumption (DrinkControl), 2026-08-21..09-05.
"""

import json

import pytest
from traning_cli.server.storage import save_health_push


def _energy(ts, qty, food_type=None, source="DrinkControl"):
    """One dietary_energy sample as HAE writes it."""
    s = {"date": ts, "start": ts, "end": ts, "source": source, "qty": qty}
    if food_type is not None:
        s["foodType"] = food_type
    return s


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
