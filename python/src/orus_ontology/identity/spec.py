"""Identity declaration attached to an object type."""

from enum import StrEnum

from pydantic import field_validator

from orus_ontology._schema import SchemaModel, validate_technical_name


class IdentityNormalizer(StrEnum):
    TRIM = "trim"
    LOWERCASE = "lowercase"
    UPPERCASE = "uppercase"


class IdentitySpec(SchemaModel):
    """Ordered properties and canonicalizers forming a deterministic identity key."""

    property_names: tuple[str, ...]
    normalizers: tuple[IdentityNormalizer, ...] = ()

    @field_validator("property_names")
    @classmethod
    def validate_property_names(cls, names: tuple[str, ...]) -> tuple[str, ...]:
        if not names:
            raise ValueError("identity must contain at least one property")
        for name in names:
            validate_technical_name(name, field_name="identity property")
        if len(names) != len(set(names)):
            raise ValueError("identity property names must be unique")
        return names

    @field_validator("normalizers")
    @classmethod
    def validate_normalizers(
        cls, normalizers: tuple[IdentityNormalizer, ...]
    ) -> tuple[IdentityNormalizer, ...]:
        if len(normalizers) != len(set(normalizers)):
            raise ValueError("identity normalizers must be unique")
        if (
            IdentityNormalizer.LOWERCASE in normalizers
            and IdentityNormalizer.UPPERCASE in normalizers
        ):
            raise ValueError("identity cannot use lowercase and uppercase together")
        return normalizers
