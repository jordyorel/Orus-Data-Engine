import uvicorn

from orus_control_plane_api.application import create_app
from orus_control_plane_api.config import Settings

app = create_app()


def run() -> None:
    settings = Settings.from_environment()
    uvicorn.run("orus_control_plane_api.main:app", host=settings.host, port=settings.port)
