# Falcon Container Apps Demo — CI/CD image-assessment gate

A GitHub Actions pipeline that builds a workload image, patches it with the
**CrowdStrike Falcon Container sensor** (`falconutil patch-image --cloud-service ACA`),
**gates** it against a Falcon **image-assessment policy**, and deploys the passing
image to **Azure Container Apps**. Bad images never reach the deployable repo.

## 🔩 What the pipeline does

```
build/pull workload image (local)              # clean | vulnerability | malware
   └─ falconutil patch-image (Falcon sensor + ACA attribution)  -> STAGING repo
        └─ CrowdStrike image scan (native fcs-action, registry assessment)
             ├─ DENY  -> delete staging image, fail build   (nothing promoted)
             └─ PASS  -> promote to deployable repo, delete staging
                          └─ deploy to Azure Container Apps
IaC scan (fcs-action) runs shift-left and non-blocking for visibility.
```

Key property: the workload image is published to a **staging/quarantine repo** for
the (registry-based) Falcon assessment, and is **promoted to the deployable repo
only if the gate passes**. A denied image is deleted from staging and never promoted.

> Why staging instead of a purely local scan? Falcon **malware** detection only runs
> when the image is assessed through a registry — a local/in-agent scan returns
> vulnerabilities/CIS/misconfig but never malware (verified on fcs-action v2.0.2 and
> v5.0.3). Staging→promote lets us catch malware while keeping the deployable repo clean.

## 🎬 Demo scenarios (selectable in the Run workflow dropdown)

`demoScenario` is a `workflow_dispatch` **choice input**:

| Scenario | What it bakes in | Gate result |
|----------|------------------|-------------|
| `clean` | healthy app (aiohttp 3.10.11) | ✅ passes → promoted → deployed |
| `vulnerability` | `aiohttp==3.9.1` (CVE-2024-23334) | 🔴 blocked by `cve_id` rule |
| `malware` | pulls `quay.io/petr_ruzicka/malware-cryptominer-container` | 🔴 blocked by malware detection |

> **Secrets** are intentionally not a scenario: Falcon **image assessment has no
> secret-detection engine** (secrets are an IaC-scan feature only — confirmed in the
> fcs-action source, `--disable-secrets-scan` is IaC-only). Image-baked secrets can't
> be gated at the image layer.

Other `workflow_dispatch` inputs: `runFCSScan` (bool), `deployToACA` (bool),
`falconRegion` (choice: us-1/us-2/eu-1/us-gov-1/us-gov-2), `failOnPolicyViolation` (bool).

## ✅ Prerequisite: a Falcon image-assessment policy

The image-scan gate's exit code reflects the **Falcon console image-assessment
policy** verdict (not a CLI flag). You need an **enabled** policy, scoped to your ACR,
with a `block` rule. For this demo the policy `mikedz-aca-demo-gate` is scoped to
`registry_url = https://<ACR_NAME>.azurecr.io` and blocks on:

- `cve_id = CVE-2024-23334` (vulnerability scenario)
- `detection_type = malware` (malware scenario)

Scope it to your registry (or repo) and give it a **low precedence number** so it wins
over any catch-all policy. Managed via the Image Assessment Policies API
(`/container-security/entities/image-assessment-policies/v1`, group + rules + precedence).

## 🚀 Setup

### Repository Variables (`vars.*`)
```
AZURE_CLIENT_ID         # user-assigned managed identity client id (OIDC)
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
ACR_NAME                # ACR name (not the login server)
RESOURCE_GROUP
CONTAINER_APP_NAME
ACA_ENV_NAME
AZURE_LOCATION          # e.g. eastus
```

### Repository Secrets (`secrets.*`)
```
FALCON_CLIENT_ID        # CrowdStrike API client id (image + IaC scan auth)
FALCON_CLIENT_SECRET    # CrowdStrike API client secret
FALCON_CID              # CrowdStrike CID *with* checksum, e.g. ABC123...-XX  (falconutil --cid)
```

### Azure setup commands
```bash
# 1) User-assigned managed identity (used for OIDC login AND ACA's ACR pull)
az identity create -n <IDENTITY_NAME> -g <RESOURCE_GROUP> --subscription <AZURE_SUBSCRIPTION_ID>

# 2) Federated credential trusting this repo's main branch
az identity federated-credential create \
  --name github-main-branch --identity-name <IDENTITY_NAME> -g <RESOURCE_GROUP> \
  --issuer https://token.actions.githubusercontent.com \
  --subject repo:<GITHUB_ORG>/<REPO_NAME>:ref:refs/heads/main \
  --audiences api://AzureADTokenExchange

# 3) Roles: AcrPush (includes pull, used by push + by ACA to pull) + Contributor on the RG
az role assignment create --assignee <IDENTITY_PRINCIPAL_ID> --role AcrPush \
  --scope /subscriptions/<SUB>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.ContainerRegistry/registries/<ACR_NAME>
az role assignment create --assignee <IDENTITY_PRINCIPAL_ID> --role Contributor \
  --scope /subscriptions/<SUB>/resourceGroups/<RESOURCE_GROUP>

# 4) Keep ACR admin user disabled (identity-based pull is used instead)
az acr update --name <ACR_NAME> --admin-enabled false
```

Create a GitHub **environment** named `production` (the deploy job gates on it) if you
want manual approval before deploy.

## 🔐 How auth works (no long-lived secrets)

- **Azure**: OIDC / workload identity federation via `azure/login` — no stored Azure creds.
- **ACR push (CI)**: `az acr login` using the OIDC identity — no admin user.
- **ACR pull (ACA runtime)**: the Container App is attached to the **user-assigned
  managed identity** and its registry is set to authenticate with that identity
  (`az containerapp create --user-assigned <id> --registry-identity <id>`).
- **CrowdStrike**: the native `crowdstrike/fcs-action` handles OAuth with
  `FALCON_CLIENT_ID`/`FALCON_CLIENT_SECRET` + region.

## 🧩 Actions used (SHA-pinned)

| Action | Version |
|--------|---------|
| `actions/checkout` | v7.0.1 |
| `docker/setup-buildx-action` | v4.3.0 |
| `azure/login` | v3.0.2 |
| `crowdstrike/fcs-action` (IaC + image scan) | v5.0.3 |
| `actions/upload-artifact` | v7.0.1 |

Deploy is done via `az containerapp` directly (identity-based ACR pull), not an action.

## 🔄 Azure DevOps → GitHub Actions concept map

| Azure DevOps | GitHub Actions | Notes |
|--------------|----------------|-------|
| Variable Groups | `vars.*` + `secrets.*` | non-secret vs secret |
| Service Connection (Azure) | Workload identity federation + `azure/login` | OIDC, no stored secret |
| Service Connection (ACR) | `az acr login` (push) / managed identity (pull) | no admin user |
| `##vso[task.setvariable]` | `echo key=value >> $GITHUB_OUTPUT` | step/job outputs |
| `${{ parameters.x }}` | `${{ inputs.x }}` | dispatch inputs (compile-time) |
| `$(variables.x)` | `${{ vars.x }}` / `${{ env.x }}` | runtime values |
| `condition:` | `if:` | conditional steps/jobs |
| stages | jobs + `needs:` | `build-scan-and-gate` → `deploy` |
| pipeline triggers | `on: workflow_dispatch/push/schedule` | schedule is daily @ 02:17 UTC |

## 🎯 Live demo script

1. Actions → **Build and Deploy Falcon Container Apps** → **Run workflow**.
2. Run `vulnerability` → build fails at the gate; check the job summary + the deployable
   repo stays empty. Show CVE-2024-23334 in the scan report artifact / Falcon console.
3. Run `malware` → blocked by malware detection; staging image deleted, nothing promoted.
4. Run `clean` with `deployToACA=true` → gate passes, image promoted, deployed to ACA;
   the summary prints the app URL.
5. In the Falcon console (Cloud Security → Image Assessment) show the policy verdicts and
   the patched image with its ACA resource attribution.

## 🔍 `falconutil patch-image` — `--subscription` / `--resource-group` / `--cloud-service ACA`

These bake **Azure resource attribution metadata** into the patched image so the running
workload correlates to the correct ACA resource in the Falcon console. They are **not**
used to make live Azure API calls at patch time. If `--subscription` gets a wrong-but-
well-formed GUID (e.g. an ADO service-connection id), the sensor still registers but the
workload shows up **unattributed / under the wrong subscription**. Correct source in GitHub
Actions: `${{ vars.AZURE_SUBSCRIPTION_ID }}` (or `az account show --query id -o tsv`).

---

*Test/reference repository. `# VERIFY` comments in the workflow flag CrowdStrike specifics
(region API URLs, falconutil flags, sensor-pull output) that should be confirmed against
current CrowdStrike documentation for your tenant.*
