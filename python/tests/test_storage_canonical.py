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


# -- aggregate vs per-sample --------------------------------------------------

def test_detailed_samples_supersede_minute_aggregate(tmp_path):
    """The 2026-09-05 case: pushed aggregate at :00, fetched detail at :35."""
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
    assert len(doc["samples"]) == 2
    assert all("foodType" in s for s in doc["samples"])
    assert sum(s["qty"] for s in doc["samples"]) == pytest.approx(1768.32, abs=0.01)


def test_aggregate_arriving_after_detail_is_not_kept(tmp_path):
    """Order of arrival must not change the outcome."""
    save_health_push(
        _payload("alcohol_consumption", "count",
                 [_aggregate("2026-09-05 18:44:35 +0200", 5.999999761581421)]),
        tmp_path)
    save_health_push(
        _payload("alcohol_consumption", "count",
                 [_aggregate("2026-09-05 18:44:00 +0200", 5.999999761581421)]),
        tmp_path)

    doc = _canonical(tmp_path, "alcohol_consumption", "2026-09-05")
    assert [s["date"] for s in doc["samples"]] == ["2026-09-05 18:44:35 +0200"]
    assert doc["daily_total"] == pytest.approx(6.0)


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


def test_real_sample_at_whole_minute_is_kept(tmp_path):
    """A drink logged at exactly :00 has no peers to be shadowed by."""
    save_health_push(
        _payload("alcohol_consumption", "count",
                 [_aggregate("2026-09-02 20:00:00 +0200", 4.3),
                  _aggregate("2026-09-02 19:18:22 +0200", 1.7)]),
        tmp_path)

    doc = _canonical(tmp_path, "alcohol_consumption", "2026-09-02")
    assert len(doc["samples"]) == 2
    assert doc["daily_total"] == pytest.approx(6.0)


def test_minute_stamped_sum_metric_is_untouched(tmp_path):
    """step_count samples are all minute-stamped; the rule must not fire."""
    save_health_push(
        _payload("step_count", "count", [
            {"date": "2026-09-05 13:00:00 +0200", "source": "iPhone", "qty": 300},
            {"date": "2026-09-05 14:00:00 +0200", "source": "iPhone", "qty": 200},
            {"date": "2026-09-05 15:00:00 +0200", "source": "iPhone", "qty": 500},
        ]),
        tmp_path)

    doc = _canonical(tmp_path, "step_count", "2026-09-05")
    assert len(doc["samples"]) == 3
    assert doc["daily_total"] == pytest.approx(1000)


def test_mismatched_total_is_not_treated_as_aggregate(tmp_path):
    """Without exact sum equality the :00 sample stays put."""
    save_health_push(
        _payload("dietary_energy", "kJ", [
            _aggregate("2026-09-05 18:44:00 +0200", 999.0),
            _energy("2026-09-05 18:44:35 +0200", 381.4, "beer, 330ml 5,0%"),
        ]),
        tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-09-05")
    assert len(doc["samples"]) == 2


def test_aggregate_from_other_source_is_kept(tmp_path):
    """Buckets are per source; a coincidence across apps is not a shadow."""
    save_health_push(
        _payload("dietary_energy", "kJ", [
            _aggregate("2026-09-05 18:44:00 +0200", 381.4, source="Lifesum"),
            _energy("2026-09-05 18:44:35 +0200", 381.4, "beer, 330ml 5,0%"),
        ]),
        tmp_path)

    doc = _canonical(tmp_path, "dietary_energy", "2026-09-05")
    assert len(doc["samples"]) == 2
