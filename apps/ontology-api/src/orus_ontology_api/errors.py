"""HTTP error mapping for ontology boundaries."""

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from orus_ontology import OntologyError, QueryError, StorageError


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(StorageError, storage_error)
    app.add_exception_handler(QueryError, query_error)
    app.add_exception_handler(OntologyError, ontology_error)


async def storage_error(_: Request, error: Exception) -> JSONResponse:
    return _response(_ontology_error(error), 503)


async def query_error(_: Request, error: Exception) -> JSONResponse:
    return _response(_ontology_error(error), 400)


async def ontology_error(_: Request, error: Exception) -> JSONResponse:
    return _response(_ontology_error(error), 422)


def _ontology_error(error: Exception) -> OntologyError:
    if not isinstance(error, OntologyError):
        raise TypeError("ontology handler received an incompatible exception")
    return error


def _response(error: OntologyError, status_code: int) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={
            "error": {
                "code": error.code.value,
                "message": error.message,
                "context": dict(error.context),
            }
        },
    )
