"""FastAPI application factory."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from orus_ontology_api.config import Settings
from orus_ontology_api.dependencies import StoreFactory, postgres_factory
from orus_ontology_api.errors import install_error_handlers
from orus_ontology_api.routes import router


def create_app(
    *,
    settings: Settings | None = None,
    store_factory: StoreFactory | None = None,
) -> FastAPI:
    resolved = settings or Settings.from_environment()
    app = FastAPI(
        title="Orus Ontology API",
        version="0.1.0",
        description="Bounded query API for materialized Orus ontologies.",
    )
    app.state.settings = resolved
    app.state.store_factory = store_factory or postgres_factory(resolved)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(resolved.cors_origins),
        allow_credentials=False,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Content-Type"],
    )
    install_error_handlers(app)
    app.include_router(router)
    return app
