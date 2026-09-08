"""Minimal aiohttp web server for the Falcon ACA demo.

Serves a single page on :80 so the patched image is a real, deployable
workload. The point of interest for the demo is the *dependency* (aiohttp),
whose pinned version is what the vulnerability scenario manipulates.
"""
from aiohttp import web


async def handle(request):
    return web.Response(
        text="Falcon ACA demo — patched workload running.\n",
        content_type="text/plain",
    )


app = web.Application()
app.add_routes([web.get("/", handle), web.get("/health", handle)])

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=80)
