"""Deterministic object identity generation from declared identity properties."""

import json
from collections.abc import Mapping
from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import UUID, uuid5

from pydantic import ValidationError

from orus_ontology.assertions.assertion import ValueTarget
from orus_ontology.errors import IdentityError
from orus_ontology.identity.spec import IdentityNormalizer
from orus_ontology.metamodel.object_type import ObjectType
from orus_ontology.metamodel.property_type import PropertyType
from orus_ontology.metamodel.value_type import ValueType


class IdentityGenerator:
    """Build stable UUIDv5 object IDs using an ontology UUID as namespace."""

    @staticmethod
    def generate(
        ontology_id: UUID,
        object_type: ObjectType,
        properties: Mapping[str, object],
    ) -> UUID:
        canonical_key = IdentityGenerator.canonical_key(object_type, properties)
        return uuid5(ontology_id, f"{object_type.type_id}:{canonical_key}")

    @staticmethod
    def canonical_key(
        object_type: ObjectType,
        properties: Mapping[str, object],
    ) -> str:
        components: list[dict[str, object]] = []
        for property_name in object_type.identity_spec.property_names:
            if property_name not in properties:
                raise IdentityError(
                    "identity property is missing",
                    context={"object_type": object_type.name, "property": property_name},
                )
            raw_value = properties[property_name]
            if raw_value is None:
                raise IdentityError(
                    "identity property must not be null",
                    context={"object_type": object_type.name, "property": property_name},
                )
            property_type = object_type.get_property(property_name)
            if property_type is None:
                raise IdentityError(
                    "identity property is not declared on object type",
                    context={"object_type": object_type.name, "property": property_name},
                )
            value = _parse_identity_value(property_type, raw_value)
            canonical = _canonical_value(
                property_type.value_type,
                value,
                object_type.identity_spec.normalizers,
            )
            components.append(
                {
                    "property_id": str(property_type.property_id),
                    "type": property_type.value_type.value,
                    "value": canonical,
                }
            )
        return json.dumps(components, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _parse_identity_value(property_type: PropertyType, value: object) -> object:
    try:
        parsed = ValueTarget(value_type=property_type.value_type, value=value).value
    except ValidationError as error:
        raise IdentityError(
            "identity property has an incompatible value",
            context={"property": property_type.name, "value_type": property_type.value_type.value},
        ) from error
    if (
        property_type.value_type is ValueType.ENUM
        and parsed not in property_type.constraints.enum_values
    ):
        raise IdentityError(
            "identity enum value is outside its declared domain",
            context={"property": property_type.name},
        )
    return parsed


def _canonical_value(
    value_type: ValueType,
    value: object,
    normalizers: tuple[IdentityNormalizer, ...],
) -> object:
    if isinstance(value, str):
        normalized = value
        for normalizer in normalizers:
            if normalizer is IdentityNormalizer.TRIM:
                normalized = normalized.strip()
            elif normalizer is IdentityNormalizer.LOWERCASE:
                normalized = normalized.lower()
            elif normalizer is IdentityNormalizer.UPPERCASE:
                normalized = normalized.upper()
        if not normalized:
            raise IdentityError("identity string must not be empty after normalization")
        return normalized
    if isinstance(value, Decimal):
        normalized_decimal = value.normalize()
        return "0" if normalized_decimal == 0 else format(normalized_decimal, "f")
    if isinstance(value, datetime):
        if value.tzinfo is None or value.utcoffset() is None:
            raise IdentityError("identity datetime must include a timezone")
        return value.astimezone(UTC).isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, UUID):
        return str(value)
    if value_type is ValueType.JSON:
        raise IdentityError("JSON properties cannot participate in object identity")
    return value
