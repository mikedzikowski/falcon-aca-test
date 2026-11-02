# Falcon Container Demo — CI/CD image-assessment gate (ACA + ACI + App Service)

A GitHub Actions pipeline that builds a workload image, patches it with the
**CrowdStrike Falcon Container sensor** (`falconutil patch-image`), **gates** it against
a Falcon **image-assessment policy**, and deploys the passing image to **Azure Container
Apps**, **Azure Container Instances** and/or **Azure App Service**. Bad images never
reach the deployable repo.

## 🔩 What the pipeline does

```
build/pull workload image (local)        # clean | vulnerability | malware | supplychain
   └─ falconutil patch-image (platform-agnostic)            -> STAGING repo (unique tag)
        └─ CrowdStrike image scan (fcs-action, registry assessment)
             └─ gate = policy verdict + detection guard + scenario check
                  ├─ DENY -> delete staging image, fail build   (nothing promoted)
                  └─ PASS -> promote to deployable repo (same digest), delete staging
                              └─ deploy to ACA / ACI / App Service, each verified by build id
IaC scan (fcs-action) runs shift-left and non-blocking for visibility.
```

- **Staging → promote.** The patched image is published to a quarantine repo for the
  registry-based Falcon assessment (malware detection only runs on registry assessment,
  never on a local scan). It is promoted only if the gate passes, and the promoted
  digest is checked against the scanned digest.
- **Unique tags.** Every run tags `<sha8>-<run id>-<attempt>`. A tag is never re-pointed
  after it has been deployed.
- **Verified deploys.** The app reports the build id baked in at `docker build` time on
  `/health`. Every deploy job requires that exact id, so an old revision or container
  answering 200 does not count as success. ACA additionally requires a revision created
  by this run (`--revision-suffix`) to be Healthy with 100% traffic.

## 🎬 Demo scenarios (`demoScenario` in the Run workflow dropdown)

| Scenario | What it bakes in | Expected gate result |
|----------|------------------|----------------------|
| `clean` | healthy app (aiohttp 3.10.11) | ✅ passes → promoted → deployed (an ALERT rule match still passes, with a warning) |
| `vulnerability` | `aiohttp==3.9.1` (CVE-2024-23334) | 🔴 blocked by the policy's `cve_id` condition |
| `malware` | `quay.io/petr_ruzicka/malware-cryptominer-container:3` | 🔴 blocked by `detection_type` (Malware) |
| `supplychain` | `Dockerfile.supplychain` — npm manifests of compromised versions (`@ctrl/tinycolor@4.1.1`, `chalk@5.6.1`, `debug@4.4.2`, …) | 🔴 blocked by `detection_type` (Malicious / CompromisedPackage) |

### How the gate decides

| FCS CLI exit | Meaning | Gate |
|---|---|---|
| `0` | NO ACTION | pass |
| `1` | policy **Prevent** (block) rule matched | **deny** |
| `2` | policy **Alert** rule matched (non-blocking) | pass with `::warning::` |
| `201`–`207`, empty, other | tool / auth / scan error | **hard fail** (never a pass) |

The exit code must agree with `PolicyResponse` in the scan JSON, or the gate fails closed.
Two pipeline-side checks back the policy up:

- **Detection guard** — an image with `Malware`, `Malicious` or `CompromisedPackage`
  detections is never promoted, even if the policy did not match them. (On 2026-10-30
  the feed stopped emitting `CompromisedPackage` for the supply-chain fixture and only
  emits `Malicious/KnownCompromisedNPMPackage`.) When the guard fires, the summary says so:
  it means the **policy** needs fixing.
- **Scenario check** — `vulnerability` / `malware` / `supplychain` are bad on purpose. If
  one of them passes the policy, the run fails instead of deploying it.

Other inputs: `deployTarget` (`none` / `aca` / `aci` / `appservice` / `all`), `runFCSScan`
(an unscanned image is never promoted), `falconRegion`, `failOnPolicyViolation`. Push and
schedule runs use `clean` → `aca` and always fail on a denial.

> **Secrets** are intentionally not a scenario: Falcon image assessment has no
> secret-detection engine (secrets are an IaC-scan feature only).

## ✅ Prerequisite: the Falcon image-assessment policy

The policy `mikedz-aca-demo-gate` is scoped to this repo's image repository. It needs a
**block** rule whose conditions (OR'd) are:

- `cve_id` = `CVE-2024-23334` (vulnerability)
- `detection_type` = `malware`, `Malicious`, `CompromisedPackage` (malware + supply chain)

An optional **alert** rule (e.g. `base_os` = `Debian GNU`) is fine — ALERT passes with a
warning. Do **not** block on `detection_severity` High or vulnerability severity: the clean
image has a High `RunningAsRootContainer` misconfiguration and a High vulnerability.
Managed via `/container-security/entities/image-assessment-policies/v1`.

## 🚀 Setup

### Repository secrets (`secrets.*`)

The repo and its Actions logs are **public**, and the runner only masks *secrets*, so
every Azure identifier is a secret, not a variable:

```
FALCON_CLIENT_ID        # CrowdStrike API client id (image + IaC scan, sensor pull)
FALCON_CLIENT_SECRET    # CrowdStrike API client secret
FALCON_CID              # CrowdStrike CID with checksum (falconutil --cid)
AZURE_CLIENT_ID         # user-assigned managed identity client id (OIDC)
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
ACR_NAME                # ACR name (not the login server)
RESOURCE_GROUP
CONTAINER_APP_NAME
ACA_ENV_NAME
APP_SERVICE_NAME
APP_SERVICE_PLAN
ACI_NAME
ACI_DNS_LABEL
```

### Repository variables (`vars.*`)

```
AZURE_LOCATION          # e.g. eastus
```

### Azure setup commands

```bash
# 1) User-assigned managed identity (OIDC login AND the ACR pull for all three targets)
az identity create -n <IDENTITY_NAME> -g <RESOURCE_GROUP>

# 2) Federated credential trusting this repo's main branch
az identity federated-credential create \
  --name github-main-branch --identity-name <IDENTITY_NAME> -g <RESOURCE_GROUP> \
  --issuer https://token.actions.githubusercontent.com \
  --subject repo:<GITHUB_ORG>/<REPO_NAME>:ref:refs/heads/main \
  --audiences api://AzureADTokenExchange

# 3) Roles: AcrPush (includes pull) on the registry + Contributor on the RG
az role assignment create --assignee <IDENTITY_PRINCIPAL_ID> --role AcrPush \
  --scope /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.ContainerRegistry/registries/<ACR_NAME>
az role assignment create --assignee <IDENTITY_PRINCIPAL_ID> --role Contributor \
  --scope /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>

# 4) The registry MUST stay private: patched images carry the CID in their config
az acr update --name <ACR_NAME> --anonymous-pull-enabled false
```

A GitHub **environment** named `production` gates the deploy jobs (add reviewers for
manual approval).

## 🔐 Public-repo hygiene

- **The CID is in every patched image** (`falconutil` writes it into `FALCONCTL_OPTS`),
  so the raw FCS scan JSON — which embeds the image config — contains it too. The
  workflow **never uploads `scan-image.json`**. It uploads an allowlisted extract
  (`scan-report.json`: policy verdict, counts, detections) plus the IaC report and the
  summary.
- Azure identifiers come from **secrets** (masked). Runtime values — FQDNs, managed
  identity resource ids, the sensor AID — are `::add-mask::`'d as soon as they are read.
  Container logs are printed through a filter that redacts IPv4 addresses and 32-hex ids.
- Job summaries show `repo:tag` only: no registry host, URLs or AIDs.
- Masked values cannot cross jobs as outputs, so the deploy jobs receive only the tag
  and rebuild the image ref from secrets.

## 🔐 How auth works (no long-lived Azure secrets)

- **Azure**: OIDC / workload identity federation via `azure/login`.
- **ACR push (CI)**: `az acr login` using the OIDC identity.
- **ACR pull (runtime)**: all three targets pull with the **user-assigned managed
  identity**. ACA uses `--registry-identity`, ACI uses `--acr-identity` + `--assign-identity`,
  and App Service uses `acrUseManagedIdentityCreds` + `acrUserManagedIdentityID`, set
  atomically with the image in `config/web`, with any `DOCKER_REGISTRY_SERVER_*` admin
  fallback removed.
- **CrowdStrike**: `crowdstrike/fcs-action` handles OAuth with
  `FALCON_CLIENT_ID`/`FALCON_CLIENT_SECRET` + region.

## 🧩 Actions used (SHA-pinned)

| Action | Version |
|--------|---------|
| `actions/checkout` | v7.0.1 |
| `docker/setup-buildx-action` | v4.3.0 |
| `azure/login` | v3.0.2 |
| `crowdstrike/fcs-action` (IaC + image scan) | v5.0.3 |
| `actions/upload-artifact` | v7.0.1 |

## 🎯 Live demo script

1. Actions → **Build and Deploy Falcon Container (ACA + ACI + App Service)** → **Run workflow**.
2. `vulnerability` → blocked at the gate; the summary shows `matched_cve_list=["CVE-2024-23334"]`.
3. `malware` → blocked; the summary lists the malware files found in the image.
4. `supplychain` → blocked; the summary lists the compromised npm packages.
5. `clean` with `deployTarget=all` → gate passes, image promoted, deployed to all three
   targets, each verified by build id; the ACI job confirms the sensor AID (masked).
6. In the Falcon console (Cloud Security → Image Assessment) show the policy verdicts.

Different scenarios can run side by side: each has its own build concurrency group and
unique tags. Deploys to the same target are serialized.

## 🔍 Runtime attribution (`CS_*`)

The image is patched once, with no platform flags, and each deploy stamps attribution at
runtime: ACA `CS_CLOUD_SERVICE=ACA` + resource group + subscription; ACI
`CS_CLOUD_SERVICE=ACI` + `CS_AZURE_CONTAINER_GROUP`; App Service `CS_APP_NAME` +
`CS_CONTAINER`, with `CS_CLOUD_SERVICE` deliberately unset (there is no App Service enum).
A wrong-but-well-formed subscription id still registers the sensor, but the workload
shows up unattributed.
