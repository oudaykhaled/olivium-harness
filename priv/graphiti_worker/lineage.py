"""Ephemeral observations; only root's immutable manifests confer authority.

A conservative partition manifest is a superset of every prompt-influencing
source. The root must compare actual request values with its derivative-version
inventory before granting each attempt. This module never signs its own grant.
"""
from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Iterator
from uuid import uuid4

from protocol import BoundaryError, Job, canonical, digest


@dataclass
class Call:
    stage_id: str
    prompt_name: str
    logical_call_id: str = field(default_factory=lambda: str(uuid4()))
    ordinal: int = 0
    predecessor: str | None = None
    previous_payload: str | None = None


@dataclass
class Lineage:
    job: Job
    receipts: list[str] = field(default_factory=list)
    observations: list[tuple[str, str, str]] = field(default_factory=list)

    def observe(self, kind: str, identity: str, value: object) -> str:
        if kind not in {"episode", "summary", "attribute", "edge", "prompt"} or not identity:
            raise BoundaryError("closure_incomplete")
        value_hash = digest(canonical(value))
        if len(self.observations) >= 100:
            raise BoundaryError("response_limit")
        # Immutable tuples preserve every observed version; these are not grants.
        self.observations.append((kind, identity, value_hash))
        return value_hash

    def manifest(self) -> tuple[str, str]:
        # This handle is root-created. A locally computed digest cannot replace it.
        if not self.job.closure_ref or not self.job.closure_digest:
            raise BoundaryError("closure_incomplete")
        return self.job.closure_ref, self.job.closure_digest

    def receipt(self, receipt_id: str) -> None:
        if receipt_id in self.receipts:
            raise BoundaryError("reconcile_required")
        self.receipts.append(receipt_id)

    def receipt_digest(self) -> str:
        return digest(canonical(self.receipts))


CURRENT_LINEAGE: ContextVar[Lineage] = ContextVar("graphiti_lineage")
CURRENT_CALL: ContextVar[Call] = ContextVar("graphiti_call")


@contextmanager
def operation(job: Job) -> Iterator[Lineage]:
    lineage = Lineage(job)
    token = CURRENT_LINEAGE.set(lineage)
    try:
        yield lineage
    finally:
        CURRENT_LINEAGE.reset(token)


@contextmanager
def call(stage_id: str, prompt_name: str) -> Iterator[Call]:
    try:
        CURRENT_LINEAGE.get().manifest()
    except LookupError as error:
        raise BoundaryError("closure_incomplete") from error
    token = CURRENT_CALL.set(Call(stage_id, prompt_name))
    try:
        yield CURRENT_CALL.get()
    finally:
        CURRENT_CALL.reset(token)
