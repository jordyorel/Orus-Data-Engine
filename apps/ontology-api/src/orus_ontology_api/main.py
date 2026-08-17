"""Production entry point."""

import uvicorn

from orus_ontology_api.application import create_app
from orus_ontology_api.config import Settings

app = create_app()


def run() -> None:
    settings = Settings.from_environment()
    uvicorn.run(
        "orus_ontology_api.main:app",
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
    )
