# Parameterized demo image for CrowdStrike image-assessment gate scenarios.
#
#   docker build --build-arg SCENARIO=<clean|vulnerability|secret> .
#
# The workflow selects SCENARIO from the demoScenario input. The `malware`
# scenario does NOT use this Dockerfile — the workflow pulls a purpose-built
# known-malware image (quay.io/petr_ruzicka/malware-cryptominer-container)
# instead, since real malware samples detect far more reliably than EICAR.
#
# What each scenario bakes in, and the policy rule that blocks it:
#   clean         -> nothing            -> passes the gate, deploys to ACA
#   vulnerability -> aiohttp==3.9.1      -> CVE-2024-23334  (rule: cve_id)
#   secret        -> fake AWS/PEM creds  -> secret detection (rule: detection_type=secret)
FROM python:3.12-slim

ARG SCENARIO=clean

WORKDIR /app
COPY app.py /app/app.py

# aiohttp version depends on the scenario:
#   vulnerability -> 3.9.1 carries CVE-2024-23334 (path traversal), fixed in 3.9.2
#   clean/secret  -> 3.10.11 is patched
RUN set -eux; \
    if [ "$SCENARIO" = "vulnerability" ]; then \
        pip install --no-cache-dir "aiohttp==3.9.1"; \
    else \
        pip install --no-cache-dir "aiohttp==3.10.11"; \
    fi

# The secret scenario bakes hardcoded credentials into an image layer.
# These are well-known NON-FUNCTIONAL example values (AWS docs sample key +
# a throwaway RSA key) — safe to publish, but shaped so secret scanners flag them.
RUN set -eux; \
    if [ "$SCENARIO" = "secret" ]; then \
        printf '%s\n' \
          '[default]' \
          'aws_access_key_id = AKIAIOSFODNN7EXAMPLE' \
          'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' \
          > /app/.aws_credentials; \
        printf '%s\n' \
          '-----BEGIN RSA PRIVATE KEY-----' \
          'MIIBOwIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Q' \
          'uKUpRKfFLfRYC9AIKjbJTWit+CqvjV2NlAsCAwEAAQJAIJLixBy2qpFoS4DSmoEm' \
          'o3qGy0t6z09AIJtH+5OeRV1be+N4cDYJKffGzDa88vQ7iZOTuU/pZ+D2grH2q4H' \
          '-----END RSA PRIVATE KEY-----' \
          > /app/id_rsa_demo; \
        chmod 600 /app/.aws_credentials /app/id_rsa_demo; \
    fi

EXPOSE 80
CMD ["python", "/app/app.py"]
