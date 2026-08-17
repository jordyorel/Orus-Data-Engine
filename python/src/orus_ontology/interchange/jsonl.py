"""Strict bounded JSONL decoding for the interchange contract."""

import json
from collections.abc import Iterator
from typing import Protocol

from pydantic import ValidationError

from orus_ontology.errors import BridgeError
from orus_ontology.interchange.contract import InterchangeEnvelope
from orus_ontology.materialization.batch import CanonicalRecord


class BinaryLineReader(Protocol):
    def readline(self, limit: int = -1, /) -> bytes: ...


def read_jsonl(
    stream: BinaryLineReader, *, max_line_bytes: int = 16 * 1024 * 1024
) -> Iterator[CanonicalRecord]:
    if max_line_bytes < 1:
        raise ValueError("max_line_bytes must be positive")
    line_number = 0
    while line := stream.readline(max_line_bytes + 1):
        line_number += 1
        if len(line) > max_line_bytes:
            raise BridgeError(
                "interchange line exceeds configured limit", context={"line": line_number}
            )
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
            envelope = InterchangeEnvelope.model_validate(raw)
        except (json.JSONDecodeError, UnicodeDecodeError, ValidationError) as error:
            raise BridgeError(
                "invalid interchange record",
                context={"line": line_number, "detail": str(error)},
            ) from error
        yield envelope.canonical_record()


def encode_jsonl(envelope: InterchangeEnvelope) -> bytes:
    return (envelope.model_dump_json() + "\n").encode()
