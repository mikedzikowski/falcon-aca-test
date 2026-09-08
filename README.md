# Falcon Container Apps Demo - Setup & Migration Guide

## 🚀 Quick Setup

### Required GitHub Repository Variables (`vars.*`)
```bash
AZURE_CLIENT_ID=<your-managed-identity-client-id>
AZURE_TENANT_ID=<your-azure-tenant-id>
AZURE_SUBSCRIPTION_ID=<your-azure-subscription-id>
ACR_NAME=<your-container-registry-name>
RESOURCE_GROUP=<your-resource-group>
CONTAINER_APP_NAME=<your-container-app-name>
ACA_ENV_NAME=<your-container-apps-environment>
AZURE_LOCATION=<azure-region-eg-eastus>
```

### Required GitHub Repository Secrets (`secrets.*`)
```bash
FALCON_CLIENT_ID=<crowdstrike-api-client-id>
FALCON_CLIENT_SECRET=<crowdstrike-api-client-secret>
FALCON_CID=<crowdstrike-customer-id-without-hash>
FALCON_CID_FCS=<crowdstrike-customer-id-for-fcs-without-hash>
```

### Azure Setup Commands

1. **Create User-Assigned Managed Identity**:
```bash
az identity create \
  --name myapp-github-deploy \
  --resource-group <RESOURCE_GROUP> \
  --subscription <AZURE_SUBSCRIPTION_ID>

# Capture the output - you'll need clientId, principalId
```

2. **Create Federated Credential for GitHub Actions**:
```bash
az identity federated-credential create \
  --name github-main-branch \
  --identity-name myapp-github-deploy \
  --resource-group <RESOURCE_GROUP> \
  --issuer https://token.actions.githubusercontent.com \
  --subject repo:<GITHUB_ORG>/<REPO_NAME>:ref:refs/heads/main \
  --audiences api://AzureADTokenExchange
```

3. **Assign Required Azure Roles**:
```bash
# ACR Push permission
az role assignment create \
  --assignee <MANAGED_IDENTITY_PRINCIPAL_ID> \
  --role AcrPush \
  --scope /subscriptions/<AZURE_SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.ContainerRegistry/registries/<ACR_NAME>

# Container App Contributor (for deployment)
az role assignment create \
  --assignee <MANAGED_IDENTITY_PRINCIPAL_ID> \
  --role Contributor \
  --scope /subscriptions/<AZURE_SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>
```

4. **Ensure ACR Admin User is Disabled** (security best practice):
```bash
az acr update --name <ACR_NAME> --admin-enabled false
```

## 🔄 Azure DevOps → GitHub Actions Migration Guide

| **Azure DevOps Concept** | **GitHub Actions Equivalent** | **Notes** |
|---------------------------|--------------------------------|-----------|
| Variable Groups | Repository Variables (`vars.*`) + Secrets (`secrets.*`) | Split sensitive vs non-sensitive |
| Service Connection (Azure) | Workload Identity Federation + `azure/login` | No stored secrets, OIDC-based |
| Service Connection (ACR) | `az acr login` after Azure auth | No admin user, token-based |
| `##vso[task.setvariable]` | `echo "key=value" >> $GITHUB_OUTPUT` | Job outputs, not runtime variables |
| `${{ parameters.x }}` | `${{ inputs.x }}` | Compile-time, workflow dispatch inputs |
| `$(variables.x)` | `${{ env.x }}` or `${{ vars.x }}` | Runtime environment/repo variables |
| `condition: eq(...)` | `if: ${{ ... }}` | Step/job conditional execution |
| Stages → Jobs | Jobs with `needs:` dependencies | Parallel by default, sequence with needs |
| `pool: vmImage` | `runs-on: ubuntu-latest` | GitHub-hosted runners |
| Pipeline triggers | `on: push/schedule/workflow_dispatch` | Similar trigger syntax |

## 🎯 Demo Script - Live Walkthrough

1. **Pre-Demo Setup**:
   - Ensure all GitHub variables/secrets are configured
   - Verify Azure Resource Group exists (the workflow will create Container Apps environment if needed)
   - Check CrowdStrike Falcon console access

2. **Workflow Execution**:
   - Go to Actions tab → "Build and Deploy Falcon Container Apps" → "Run workflow"
   - Enable all options: `useDockerfile=false`, `runFCSScan=true`, `deployToACA=true`
   - Select your Falcon region (typically `us-1`)
   - Set `failOnPolicyViolation=true` to demonstrate policy enforcement

3. **What to Highlight**:
   - **Infrastructure**: Workflow automatically creates Container Apps environment and app if they don't exist
   - **Security**: No long-lived secrets, OIDC authentication throughout
   - **Reliability**: Immutable image tags, deterministic digest resolution
   - **Regional Support**: Proper API/registry alignment based on Falcon region
   - **Observability**: GitHub Actions UI shows real-time progress, FCS scan results in summary

4. **Expected Results**:
   - Azure Container Apps environment created (if new)
   - Base image (nginx:latest) pulled/built and pushed to ACR
   - Falcon sensor downloaded and pushed to ACR  
   - Image patched with sensor for Azure Container Apps attribution
   - FCS scan uploads results to Falcon console (if enabled)
   - Container App created/updated with new revision

5. **Falcon Console Verification**:
   - Navigate to Container Security → Container Images
   - Find your patched image with ACA resource attribution
   - Review scan results and policy compliance
   - Check that the running container shows proper cloud resource linkage

6. **Before/After Comparison**:
   - **Before**: No infrastructure, standard nginx container, no security instrumentation
   - **After**: Full ACA deployment + CrowdStrike runtime protection + compliance scanning

## 🐛 Fixes from Azure DevOps Pipeline

### **P0 - Broken/Security Issues**
- ✅ **Wrong subscription ID**: `--subscription` now uses `${{ vars.AZURE_SUBSCRIPTION_ID }}` instead of service connection GUID
- ✅ **Regional API mismatch**: Dynamic API base URL mapping prevents `eu-1`/GovCloud failures  
- ✅ **Secrets in CLI args**: All sensitive values now passed via environment or stdin
- ✅ **ACR admin user dependency**: Uses `az acr login` with managed identity, no admin credentials

### **P1 - Fragility Issues**  
- ✅ **Docker config conflicts**: Removed fragile `mv ~/.docker/config.json` hack, uses `az acr login`
- ✅ **Fragile stdout parsing**: Added fallback digest resolution via `az acr manifest show`
- ✅ **Missing image push**: `docker/build-push-action` handles build+push atomically
- ✅ **Mutable tags**: Immutable tags based on commit SHA prevent race conditions
- ✅ **Undeclared variables**: All dependencies explicitly declared as `vars.*` or `secrets.*`

### **P2 - Polish Issues**
- ✅ **Hourly scheduling**: Changed to daily at off-minute (2:17 AM) to reduce cost/noise
- ✅ **Expression misuse**: Proper `${{ inputs.x }}` vs `${{ env.x }}` usage throughout  
- ✅ **Missing error handling**: `set -euo pipefail` in all shell steps
- ✅ **No cleanup**: Docker logout handled automatically by runner cleanup
- ✅ **Unpinned actions**: All actions pinned to specific commit SHAs with version comments
- ✅ **No rollback path**: Azure Container Apps action provides built-in revision management

## 🔍 Specific Answer: falconutil --subscription Parameter

**Question**: What does `--subscription` do in `falconutil patch-image --cloud-service ACA`?

**Answer**: Based on the code analysis, `--subscription` (along with `--resource-group` and `--cloud-service ACA`) provides **Azure resource attribution metadata** that gets baked into the patched container image. This allows the running workload to appear correctly attributed to the specific Azure Container App resource in the CrowdStrike Falcon console.

**These parameters are NOT used to make live Azure API calls during patching** - they're embedded as metadata for runtime correlation.

**Incorrect GUID symptom**: If `--subscription` receives a wrong-but-well-formed GUID (like the Azure DevOps service connection GUID), the sensor will still register and function, but the workload will appear **unattributed or grouped under the wrong Azure subscription** in the Falcon console, making it harder to correlate security events with the correct cloud resources.

**Correct value in GitHub Actions**: `${{ vars.AZURE_SUBSCRIPTION_ID }}` (or derived via `az account show --query id -o tsv` after `azure/login`)

---

*This is a test repository for demonstrating the Falcon Container Apps workflow.*