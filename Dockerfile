# Parameterized demo image for CrowdStrike image-assessment gate scenarios.
#
#   docker build --build-arg SCENARIO=<clean|vulnerability> .
#
# The workflow selects SCENARIO from the demoScenario input. The `malware`
# scenario does NOT use this Dockerfile — the workflow pulls a purpose-built
# known-malware image (quay.io/petr_ruzicka/malware-cryptominer-container)
# instead, since real malware samples detect far more reliably than EICAR.
#
# What each scenario bakes in, and the policy rule that blocks it:
#   clean         -> nothing            -> passes the gate, deploys to ACA
#   vulnerability -> aiohttp==3.9.1      -> CVE-2024-23334  (rule: cve_id)
#
# NOTE: image assessment has no secret-detection engine (secrets are an IaC-scan
# feature only), so there is no image-based "secret" scenario here.
FROM python:3.12-slim

ARG SCENARIO=clean

WORKDIR /app
COPY app.py /app/app.py

# aiohttp version depends on the scenario:
#   vulnerability -> 3.9.1 carries CVE-2024-23334 (path traversal), fixed in 3.9.2
#   clean         -> 3.10.11 is patched
RUN set -eux; \
    if [ "$SCENARIO" = "vulnerability" ]; then \
        pip install --no-cache-dir "aiohttp==3.9.1"; \
    else \
        pip install --no-cache-dir "aiohttp==3.10.11"; \
    fi

# Build identity, so the deploy jobs can prove the NEW image is what is serving
# (a 200 alone can come from the previous revision/container). Declared after the
# pip layer so a per-run value doesn't bust the dependency cache. Baked here —
# before falconutil patch-image, which builds FROM this image and keeps its ENV
# and filesystem — so it is part of the scanned, digest-identical artifact.
ARG BUILD_ID=unset
ENV BUILD_ID=${BUILD_ID}
RUN printf '%s\n' "${BUILD_ID}" > /app/BUILD_ID

EXPOSE 80
CMD ["python", "/app/app.py"]
