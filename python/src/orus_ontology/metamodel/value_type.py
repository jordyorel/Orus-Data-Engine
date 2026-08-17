"""Primitive semantic value types supported by Orus Ontology."""

from enum import StrEnum


class ValueType(StrEnum):
    STRING = "string"
    INTEGER = "integer"
    DECIMAL = "decimal"
    BOOLEAN = "boolean"
    DATE = "date"
    DATETIME = "datetime"
    ENUM = "enum"
    REFERENCE = "reference"
    JSON = "json"
