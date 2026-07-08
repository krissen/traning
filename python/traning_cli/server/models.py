"""Pydantic request models for the HAE receiver endpoints.

These intentionally stay loose: HAE metric/workout payloads carry many
optional, provider-varying fields, and the downstream consumers
(``storage.save_health_push`` / ``storage.save_workout_push``) only ever
access a handful of them via ``dict.get(...)``. The models exist to
replace the old hand-rolled ``isinstance``/``len`` checks with FastAPI's
automatic 422 responses — not to narrow what shape of payload is
accepted. If a payload works today, it must still validate.
"""

from pydantic import BaseModel, ConfigDict, Field


class HealthData(BaseModel):
    """The ``data`` object of an HAE health payload: ``{"metrics": [...]}``."""

    model_config = ConfigDict(extra="allow")

    metrics: list[dict] = Field(min_length=1)


class HealthPayload(BaseModel):
    """Top-level HAE health payload: ``{"data": {"metrics": [...]}}``."""

    model_config = ConfigDict(extra="allow")

    data: HealthData


class WorkoutsData(BaseModel):
    """The ``data`` object of an HAE workouts payload: ``{"workouts": [...]}``."""

    model_config = ConfigDict(extra="allow")

    workouts: list[dict] = Field(min_length=1)


class WorkoutsPayload(BaseModel):
    """Top-level HAE workouts payload: ``{"data": {"workouts": [...]}}``."""

    model_config = ConfigDict(extra="allow")

    data: WorkoutsData
