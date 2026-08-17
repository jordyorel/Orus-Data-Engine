"""Request-scoped ontology storage dependencies."""

from collections.abc import Iterator
from typing import Protocol, cast

from fastapi import Request
from orus_ontology.storage.contracts import OntologyStore
from orus_ontology.storage.postgres import PostgresStore

from orus_ontology_api.config import Settings


class StoreFactory(Protocol):
    def __call__(self) -> OntologyStore: ...


def get_store(request: Request) -> Iterator[OntologyStore]:
    factory = cast(StoreFactory, request.app.state.store_factory)
    store = factory()
    try:
        yield store
    finally:
        close = getattr(store, "close", None)
        if callable(close):
            close()


def postgres_factory(settings: Settings) -> StoreFactory:
    def create() -> OntologyStore:
        return PostgresStore(settings.postgres_dsn)

    return create
