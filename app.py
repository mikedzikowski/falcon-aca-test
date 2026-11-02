"""Minimal aiohttp web server for the Falcon ACA demo.

Serves a single page on :80 so the patched image is a real, deployable
workload. The point of interest for the demo is the *dependency* (aiohttp),
whose pinned version is what the vulnerability scenario manipulates.

/health and /version report the build id baked in at `docker build` time so CI
can prove the NEW image is serving, not a previous revision/container.
"""
import os
from pathlib import Path

from aiohttp import web

_BUILD_ID_FILE = Path("/app/BUILD_ID")


def _build_id() -> str:
    # The file is written by `docker build` BEFORE falconutil patch-image, so it is
    # inside the scanned digest and cannot be overridden by a platform env var.
    # ENV BUILD_ID is the fallback.
    try:
        value = _BUILD_ID_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    return value or os.environ.get("BUILD_ID", "") or "unknown"


BUILD_ID = _build_id()


async def handle(request):
    return web.Response(
        text=f"Falcon ACA demo — patched workload running. build={BUILD_ID}\n",
        content_type="text/plain",
    )


async def health(request):
    return web.json_response(
        {"status": "ok", "build_id": BUILD_ID},
        headers={"Cache-Control": "no-store"},
    )


app = web.Application()
app.add_routes([
    web.get("/", handle),
    web.get("/health", health),
    web.get("/version", health),
])

if __name__ == "__main__":
    # access_log=None: the default access log records client IPs, which would end up
    # in the (public) CI logs when the deploy jobs dump container output.
    web.run_app(app, host="0.0.0.0", port=80, access_log=None)
