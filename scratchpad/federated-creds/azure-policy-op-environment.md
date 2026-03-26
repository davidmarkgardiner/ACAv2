# Azure Policy — FederatedIdentityCredential Environment Matching via `op-environment`

**Purpose:** Block cross-environment FIC bindings by validating that the OIDC issuer URL belongs to a cluster in the same `op-environment` as the UAMI.
**Status:** Quick win — uses existing `op-environment` tagging already in place on AKS clusters, subscriptions, and managed identities.
**Context:** This is a compensating control for a Microsoft platform limitation. ARM performs no validation on the OIDC issuer URL in FederatedIdentityCredentials. AWS and GCP both provide native guardrails for the equivalent scenario (see below). Azure does not.

---

## Why This Control Is Needed — Microsoft Platform Gap

Azure Resource Manager treats the `issuer` field on a FederatedIdentityCredential as a free-text string with no validation. There are no built-in Azure policies, no Defender for Cloud rules, and no Sentinel detections for cross-environment OIDC bindings. Microsoft does not consider this a design gap and has no announced plans to address it.

Both AWS and GCP handle the equivalent scenario with structural, platform-level controls:

| Cloud | Mechanism | How It Prevents Cross-Environment Binding |
|---|---|---|
| **AWS** | IAM OIDC Identity Provider resource | Must be explicitly created in the target account. Dev cluster's OIDC provider doesn't exist in prod unless an admin deliberately provisions it. Trust is structural. |
| **GCP** | Workload Identity Pools (project-scoped) | Pools are scoped to a GCP Project. Cross-project federation requires explicit IAM bindings. Trust is a first-class resource with explicit scope. |
| **Azure** | None | Issuer is a free-text string. ARM writes it without validation. No native guardrail exists. |

**References:**
- AWS IRSA: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- AWS IAM OIDC Provider: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
- GCP Workload Identity Federation: https://cloud.google.com/iam/docs/workload-identity-federation
- GCP GKE Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Azure Workload Identity Federation: https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
- Azure AKS Workload Identity: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview

**Note:** The AWS and GCP comparisons should be independently verified against current documentation before citing in formal stakeholder communications.

---

## 1. Current Tagging Posture

| Resource | `op-environment` tag | Confirmed |
|---|---|---|
| AKS clusters | Yes | All clusters tagged |
| Subscriptions | Yes | All subscriptions tagged |
| User-Assigned Managed Identities | Yes | All UAMIs tagged |
| OIDC issuer profile | Enabled | All clusters use Workload Identity |

**Canonical `op-environment` values:** `dev`, `pre-prod`, `prod`

Because the tag exists on all three resource types, the policy can validate environment alignment at every level — the subscription knows its environment, the UAMI knows its environment, and the cluster (via OIDC URL lookup) knows its environment.

---

## 2. Core Logic

```
FIC write request arrives at ARM
    |
    v
What environment is this subscription in?
    --> Subscription tag: op-environment = "prod"
    --> UAMI tag also confirms: op-environment = "prod"
    |
    v
What OIDC issuer URLs are allowed for "prod"?
    --> Allowlist: all AKS clusters across the management group
        where op-environment = "prod"
    --> Extract their oidcIssuerProfile.issuerUrl values
    |
    v
Is the issuer in the FIC write request in that list?
    --> Yes: ALLOW (same environment)
    --> No: DENY ("OIDC issuer does not belong to a cluster in the same op-environment")
```

The `op-environment` tag is the single source of truth. Both sides of the trust relationship (UAMI and AKS cluster) must share the same value.

---

## 3. Allowlist Generation — Management Group Scope

The script iterates all subscriptions in a management group, queries all AKS clusters, and builds per-environment allowlists. This ensures the allowlist covers clusters across all subscriptions, not just one.

```bash
#!/bin/bash
# generate-oidc-allowlists.sh
# Queries ALL AKS clusters across a management group
# Groups OIDC issuer URLs by op-environment tag
# Outputs one allowlist file per environment

set -euo pipefail

MGMT_GROUP="${1:?Usage: $0 <management-group-name>}"
OUTPUT_DIR="${2:-.}"

echo "=== OIDC Allowlist Generator ==="
echo "Management group: ${MGMT_GROUP}"
echo ""

# Step 1: Get all subscription IDs under the management group
SUBSCRIPTIONS=$(az account management-group subscription show-sub-under-mg \
  --name "$MGMT_GROUP" \
  --query "[].name" -o tsv 2>/dev/null \
  || az account management-group show \
    --name "$MGMT_GROUP" \
    --expand children --recurse \
    --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].name || children[].children[?type=='Microsoft.Management/managementGroups/subscriptions'].name | []" -o tsv)

SUB_COUNT=$(echo "$SUBSCRIPTIONS" | wc -l | tr -d ' ')
echo "Found ${SUB_COUNT} subscriptions"
echo ""

# Step 2: Collect all clusters with their environment and OIDC URL
ALL_CLUSTERS="[]"

for SUB_ID in $SUBSCRIPTIONS; do
  SUB_NAME=$(az account show --subscription "$SUB_ID" --query "name" -o tsv 2>/dev/null || echo "unknown")
  SUB_ENV=$(az account show --subscription "$SUB_ID" --query "tags.\"op-environment\"" -o tsv 2>/dev/null || echo "untagged")
  echo "Scanning subscription: ${SUB_NAME} (${SUB_ID}) [op-environment: ${SUB_ENV}]"

  CLUSTERS=$(az aks list --subscription "$SUB_ID" \
    --query "[].{name:name, resourceGroup:resourceGroup, subscriptionId:'${SUB_ID}', subscriptionName:'${SUB_NAME}', clusterEnv:tags.\"op-environment\", subscriptionEnv:'${SUB_ENV}', oidc:oidcIssuerProfile.issuerUrl}" \
    -o json 2>/dev/null || echo "[]")

  CLUSTER_COUNT=$(echo "$CLUSTERS" | jq length)
  echo "  Found ${CLUSTER_COUNT} AKS clusters"

  # Warn about clusters missing the tag
  UNTAGGED=$(echo "$CLUSTERS" | jq -r '.[] | select(.clusterEnv == null) | "  WARNING: \(.resourceGroup)/\(.name) has no op-environment tag"')
  if [ -n "$UNTAGGED" ]; then
    echo "$UNTAGGED"
  fi

  # Warn about cluster/subscription environment mismatch
  MISMATCHED=$(echo "$CLUSTERS" | jq -r '.[] | select(.clusterEnv != null and .clusterEnv != .subscriptionEnv) | "  WARNING: \(.resourceGroup)/\(.name) cluster env=\(.clusterEnv) != subscription env=\(.subscriptionEnv)"')
  if [ -n "$MISMATCHED" ]; then
    echo "$MISMATCHED"
  fi

  ALL_CLUSTERS=$(echo "$ALL_CLUSTERS" "$CLUSTERS" | jq -s '.[0] + .[1]')
done

TOTAL=$(echo "$ALL_CLUSTERS" | jq length)
echo ""
echo "Total AKS clusters across management group: ${TOTAL}"

# Step 3: Generate per-environment allowlists
echo ""
echo "=== Generating allowlists ==="

for ENV in dev pre-prod prod; do
  URLS=$(echo "$ALL_CLUSTERS" | jq -r --arg env "$ENV" '[.[] | select(.clusterEnv == $env) | .oidc] | sort | unique')
  URL_COUNT=$(echo "$URLS" | jq length)

  echo ""
  echo "--- op-environment: ${ENV} (${URL_COUNT} clusters) ---"
  echo "$URLS" | jq -r '.[]'

  # Write allowlist JSON for policy parameter
  echo "$URLS" > "${OUTPUT_DIR}/allowlist-${ENV}.json"
  echo "Written to ${OUTPUT_DIR}/allowlist-${ENV}.json"

  # Write detailed inventory for audit
  echo "$ALL_CLUSTERS" | jq -r --arg env "$ENV" \
    '.[] | select(.clusterEnv == $env) | "\(.subscriptionName) | \(.resourceGroup)/\(.name) | \(.oidc)"' \
    > "${OUTPUT_DIR}/inventory-${ENV}.txt"
  echo "Written to ${OUTPUT_DIR}/inventory-${ENV}.txt"
done

# Step 4: Flag clusters with no OIDC or no tag
echo ""
echo "=== Anomalies ==="
echo "$ALL_CLUSTERS" | jq -r '.[] | select(.clusterEnv == null) | "NO TAG: \(.subscriptionName)/\(.resourceGroup)/\(.name)"'
echo "$ALL_CLUSTERS" | jq -r '.[] | select(.oidc == null) | "NO OIDC: \(.subscriptionName)/\(.resourceGroup)/\(.name)"'
echo "$ALL_CLUSTERS" | jq -r '.[] | select(.clusterEnv != null and .clusterEnv != .subscriptionEnv) | "ENV MISMATCH: \(.subscriptionName)/\(.resourceGroup)/\(.name) cluster=\(.clusterEnv) sub=\(.subscriptionEnv)"'

echo ""
echo "Done. Review inventory files before applying to policy."
```

**Output example:**
```
=== OIDC Allowlist Generator ===
Management group: mg-platform

Found 6 subscriptions

Scanning subscription: sub-prod-01 (xxxx-xxxx) [op-environment: prod]
  Found 3 AKS clusters
Scanning subscription: sub-prod-02 (yyyy-yyyy) [op-environment: prod]
  Found 2 AKS clusters
Scanning subscription: sub-preprod-01 (zzzz-zzzz) [op-environment: pre-prod]
  Found 2 AKS clusters
Scanning subscription: sub-dev-01 (aaaa-aaaa) [op-environment: dev]
  Found 4 AKS clusters

Total AKS clusters across management group: 11

=== Generating allowlists ===

--- op-environment: prod (5 clusters) ---
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-1>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-2>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-3>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-4>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-5>/

--- op-environment: pre-prod (2 clusters) ---
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-6>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-7>/

--- op-environment: dev (4 clusters) ---
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-8>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-9>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-10>/
https://uksouth.oic.prod-aks.azure.com/<tenant>/<uuid-11>/
```

---

## 4. Policy Definition

One policy definition, deployed at management group level. Assigned per-subscription with the environment-appropriate allowlist.

```json
{
  "properties": {
    "displayName": "Restrict FederatedIdentityCredential OIDC issuer to same op-environment",
    "description": "Denies creation or update of FederatedIdentityCredentials where the issuer URL is not in the allowlist of AKS OIDC endpoints for this subscription's op-environment. Prevents cross-environment workload identity bindings.",
    "policyType": "Custom",
    "mode": "All",
    "metadata": {
      "category": "Managed Identity",
      "version": "1.0.0"
    },
    "parameters": {
      "allowedIssuerUrls": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed OIDC Issuer URLs",
          "description": "OIDC issuer URLs from AKS clusters sharing the same op-environment as this subscription."
        }
      },
      "effect": {
        "type": "String",
        "metadata": {
          "displayName": "Effect",
          "description": "Audit or Deny"
        },
        "allowedValues": ["Audit", "Deny", "Disabled"],
        "defaultValue": "Audit"
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials"
          },
          {
            "not": {
              "field": "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/issuer",
              "in": "[parameters('allowedIssuerUrls')]"
            }
          }
        ]
      },
      "then": {
        "effect": "[parameters('effect')]"
      }
    }
  }
}
```

---

## 5. Policy Assignment — Automated Across Management Group

Rather than manually assigning per-subscription, automate assignments for all subscriptions in the management group using each subscription's `op-environment` tag to select the correct allowlist.

### Automated assignment script

```bash
#!/bin/bash
# assign-fic-policy.sh
# Creates policy assignments for all subscriptions in a management group
# Uses the subscription's op-environment tag to select the correct allowlist

set -euo pipefail

MGMT_GROUP="${1:?Usage: $0 <management-group-name> <policy-definition-id>}"
POLICY_DEF_ID="${2:?Usage: $0 <management-group-name> <policy-definition-id>}"
ALLOWLIST_DIR="${3:-.}"
EFFECT="${4:-Audit}"  # Default to Audit — pass "Deny" when ready

echo "Assigning FIC issuer policy across management group: ${MGMT_GROUP}"
echo "Effect: ${EFFECT}"
echo ""

# Get all subscriptions
SUBSCRIPTIONS=$(az account management-group show \
  --name "$MGMT_GROUP" \
  --expand children --recurse \
  --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].{id:name, displayName:displayName} || children[].children[?type=='Microsoft.Management/managementGroups/subscriptions'].{id:name, displayName:displayName} | []" \
  -o json)

echo "$SUBSCRIPTIONS" | jq -r '.[] | .id' | while read SUB_ID; do
  SUB_NAME=$(echo "$SUBSCRIPTIONS" | jq -r --arg id "$SUB_ID" '.[] | select(.id == $id) | .displayName')

  # Get the subscription's op-environment tag
  ENV=$(az tag list --resource-id "/subscriptions/${SUB_ID}" \
    --query "properties.tags.\"op-environment\"" -o tsv 2>/dev/null || echo "")

  if [ -z "$ENV" ]; then
    echo "SKIP: ${SUB_NAME} (${SUB_ID}) — no op-environment tag"
    continue
  fi

  ALLOWLIST_FILE="${ALLOWLIST_DIR}/allowlist-${ENV}.json"
  if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "ERROR: ${SUB_NAME} (${SUB_ID}) — op-environment=${ENV} but no ${ALLOWLIST_FILE} found"
    continue
  fi

  ASSIGNMENT_NAME="fic-issuer-${ENV}-$(echo "$SUB_ID" | cut -d'-' -f1)"

  echo "Assigning to: ${SUB_NAME} (${SUB_ID}) [op-environment: ${ENV}]"
  echo "  Allowlist: ${ALLOWLIST_FILE} ($(jq length < "$ALLOWLIST_FILE") URLs)"

  az policy assignment create \
    --name "$ASSIGNMENT_NAME" \
    --display-name "FIC OIDC issuer restriction - ${ENV}" \
    --description "Restricts FederatedIdentityCredential issuers to AKS clusters in the ${ENV} environment" \
    --policy "$POLICY_DEF_ID" \
    --scope "/subscriptions/${SUB_ID}" \
    --params "{
      \"allowedIssuerUrls\": {
        \"value\": $(cat "$ALLOWLIST_FILE")
      },
      \"effect\": {
        \"value\": \"${EFFECT}\"
      }
    }"

  echo "  Done."
  echo ""
done

echo "All assignments complete."
```

### Usage

```bash
# Step 1: Generate allowlists across the management group
./generate-oidc-allowlists.sh mg-platform ./allowlists/

# Step 2: Create the policy definition at management group level
POLICY_ID=$(az policy definition create \
  --name "restrict-fic-oidc-issuer" \
  --display-name "Restrict FederatedIdentityCredential OIDC issuer to same op-environment" \
  --management-group "mg-platform" \
  --rules policy-rule.json \
  --params policy-params.json \
  --mode All \
  --query id -o tsv)

# Step 3: Assign to all subscriptions in Audit mode
./assign-fic-policy.sh mg-platform "$POLICY_ID" ./allowlists/ Audit

# Step 4 (later): Switch to Deny
./assign-fic-policy.sh mg-platform "$POLICY_ID" ./allowlists/ Deny
```

---

## 6. Allowlist Refresh — Nightly Schedule + Manual Trigger

The allowlist must stay current. Two modes of operation:

1. **Nightly scheduled run** — catches all changes from the day (new clusters, rebuilds, decommissions)
2. **Manual trigger** — run on-demand when you need the allowlist updated immediately (e.g. cluster rebuild, emergency)

Same script for both. No Event Grid dependency, no extra infrastructure.

### Refresh script

```bash
#!/bin/bash
# refresh-oidc-allowlists.sh
# Regenerates OIDC allowlists and updates all policy assignments
# Run nightly via cron/pipeline schedule, or manually on demand
#
# Usage:
#   ./refresh-oidc-allowlists.sh <management-group> <policy-definition-id> [effect]
#
# Examples:
#   ./refresh-oidc-allowlists.sh mg-platform "/providers/.../restrict-fic-oidc-issuer"        # Keeps current effect
#   ./refresh-oidc-allowlists.sh mg-platform "/providers/.../restrict-fic-oidc-issuer" Deny   # Explicit effect

set -euo pipefail

MGMT_GROUP="${1:?Usage: $0 <management-group-name> <policy-definition-id> [effect]}"
POLICY_DEF_ID="${2:?Usage: $0 <management-group-name> <policy-definition-id> [effect]}"
EFFECT="${3:-}"  # If empty, preserve current assignment effect
WORK_DIR=$(mktemp -d)
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LOG_FILE="${WORK_DIR}/refresh-${TIMESTAMP}.log"

log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== OIDC Allowlist Refresh ==="
log "Management group: ${MGMT_GROUP}"
log "Timestamp: ${TIMESTAMP}"
log "Working directory: ${WORK_DIR}"
log ""

# ── Step 1: Get all subscriptions ──────────────────────────────────────
SUBSCRIPTIONS=$(az account management-group show \
  --name "$MGMT_GROUP" \
  --expand children --recurse \
  --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].name || children[].children[?type=='Microsoft.Management/managementGroups/subscriptions'].name | []" -o tsv)

# ── Step 2: Collect all clusters across management group ───────────────
ALL_CLUSTERS="[]"

for SUB_ID in $SUBSCRIPTIONS; do
  SUB_NAME=$(az account show --subscription "$SUB_ID" --query "name" -o tsv 2>/dev/null || echo "unknown")
  SUB_ENV=$(az tag list --resource-id "/subscriptions/${SUB_ID}" \
    --query "properties.tags.\"op-environment\"" -o tsv 2>/dev/null || echo "untagged")

  CLUSTERS=$(az aks list --subscription "$SUB_ID" \
    --query "[].{name:name, resourceGroup:resourceGroup, subscriptionId:'${SUB_ID}', clusterEnv:tags.\"op-environment\", subscriptionEnv:'${SUB_ENV}', oidc:oidcIssuerProfile.issuerUrl}" \
    -o json 2>/dev/null || echo "[]")

  COUNT=$(echo "$CLUSTERS" | jq length)
  log "  ${SUB_NAME} (${SUB_ENV}): ${COUNT} clusters"

  # Flag anomalies
  echo "$CLUSTERS" | jq -r '.[] | select(.clusterEnv == null) | "  WARNING: no op-environment tag on \(.resourceGroup)/\(.name)"' | while read LINE; do log "$LINE"; done
  echo "$CLUSTERS" | jq -r '.[] | select(.clusterEnv != null and .clusterEnv != .subscriptionEnv) | "  WARNING: env mismatch \(.resourceGroup)/\(.name) cluster=\(.clusterEnv) sub=\(.subscriptionEnv)"' | while read LINE; do log "$LINE"; done

  ALL_CLUSTERS=$(echo "$ALL_CLUSTERS" "$CLUSTERS" | jq -s '.[0] + .[1]')
done

TOTAL=$(echo "$ALL_CLUSTERS" | jq length)
log ""
log "Total clusters: ${TOTAL}"

# ── Step 3: Build per-environment allowlists ───────────────────────────
for ENV in dev pre-prod prod; do
  URLS=$(echo "$ALL_CLUSTERS" | jq -r --arg env "$ENV" '[.[] | select(.clusterEnv == $env) | .oidc] | sort | unique')
  URL_COUNT=$(echo "$URLS" | jq length)
  echo "$URLS" > "${WORK_DIR}/allowlist-${ENV}.json"
  log "  ${ENV}: ${URL_COUNT} OIDC endpoints"
done

# ── Step 4: Compare with current assignments and update if changed ─────
log ""
log "=== Updating policy assignments ==="

CHANGES=0

for SUB_ID in $SUBSCRIPTIONS; do
  SUB_NAME=$(az account show --subscription "$SUB_ID" --query "name" -o tsv 2>/dev/null || echo "unknown")
  ENV=$(az tag list --resource-id "/subscriptions/${SUB_ID}" \
    --query "properties.tags.\"op-environment\"" -o tsv 2>/dev/null || echo "")

  if [ -z "$ENV" ]; then
    log "  SKIP: ${SUB_NAME} — no op-environment tag"
    continue
  fi

  NEW_ALLOWLIST=$(cat "${WORK_DIR}/allowlist-${ENV}.json")
  ASSIGNMENT_NAME="fic-issuer-${ENV}-$(echo "$SUB_ID" | cut -d'-' -f1)"

  # Get current assignment parameters (if exists)
  CURRENT_ALLOWLIST=$(az policy assignment show \
    --name "$ASSIGNMENT_NAME" \
    --scope "/subscriptions/${SUB_ID}" \
    --query "parameters.allowedIssuerUrls.value" -o json 2>/dev/null || echo "null")

  CURRENT_EFFECT=$(az policy assignment show \
    --name "$ASSIGNMENT_NAME" \
    --scope "/subscriptions/${SUB_ID}" \
    --query "parameters.effect.value" -o tsv 2>/dev/null || echo "Audit")

  # Use provided effect or keep current
  ASSIGN_EFFECT="${EFFECT:-$CURRENT_EFFECT}"

  # Compare — update only if different
  if [ "$CURRENT_ALLOWLIST" != "null" ] && [ "$(echo "$NEW_ALLOWLIST" | jq -S .)" = "$(echo "$CURRENT_ALLOWLIST" | jq -S .)" ] && [ "$ASSIGN_EFFECT" = "$CURRENT_EFFECT" ]; then
    log "  ${SUB_NAME} (${ENV}): no change"
    continue
  fi

  log "  ${SUB_NAME} (${ENV}): UPDATING ($(echo "$NEW_ALLOWLIST" | jq length) URLs, effect=${ASSIGN_EFFECT})"
  CHANGES=$((CHANGES + 1))

  az policy assignment create \
    --name "$ASSIGNMENT_NAME" \
    --display-name "FIC OIDC issuer restriction - ${ENV}" \
    --description "Restricts FederatedIdentityCredential issuers to AKS clusters in the ${ENV} environment. Last updated: ${TIMESTAMP}" \
    --policy "$POLICY_DEF_ID" \
    --scope "/subscriptions/${SUB_ID}" \
    --params "{
      \"allowedIssuerUrls\": { \"value\": ${NEW_ALLOWLIST} },
      \"effect\": { \"value\": \"${ASSIGN_EFFECT}\" }
    }" > /dev/null

done

log ""
log "=== Complete ==="
log "Assignments updated: ${CHANGES}"
log "Log: ${LOG_FILE}"

# ── Step 5: Alert if unexpected changes ────────────────────────────────
if [ "$CHANGES" -gt 0 ]; then
  log ""
  log "Changes detected — review the log for details."
  log "If this was a manual run after a cluster rebuild, this is expected."
  log "If this was the nightly run, investigate any unexpected cluster additions/removals."
fi
```

### Nightly schedule (cron / pipeline)

Run once per night. Catches any cluster changes from the day.

```yaml
# Azure DevOps pipeline example
schedules:
  - cron: "0 2 * * *"  # 02:00 UTC every night
    displayName: "Nightly OIDC allowlist refresh"
    branches:
      include: [main]
    always: true

steps:
  - script: |
      ./refresh-oidc-allowlists.sh mg-platform "$POLICY_DEF_ID"
    displayName: "Refresh OIDC allowlists"
    env:
      POLICY_DEF_ID: $(policyDefinitionId)
```

### Manual trigger (cluster rebuild, emergency)

Same script, run by hand. Use when you can't wait for the nightly run.

```bash
# Cluster just rebuilt — update the allowlists now
./refresh-oidc-allowlists.sh mg-platform "/providers/.../restrict-fic-oidc-issuer"

# The script will:
# 1. Query all clusters across the management group
# 2. Pick up the new cluster's OIDC URL (available immediately from AKS API)
# 3. Add it to the correct environment's allowlist
# 4. Update only the policy assignments that changed
# 5. Log everything
```

### What happens during a cluster rebuild

```
Cluster dies
    |
    v
Rebuild automation creates new cluster
    --> New OIDC URL generated (available via AKS API immediately)
    --> Old OIDC URL no longer valid
    |
    v
Engineer runs: ./refresh-oidc-allowlists.sh mg-platform "$POLICY_ID"
    --> Script picks up new OIDC URL
    --> Adds to environment allowlist
    --> Old URL from dead cluster is gone (no longer returned by az aks list)
    --> Updates policy assignments for all subscriptions in that environment
    |
    v
FICs referencing old cluster also need updating (separate step — see Section 7a)
    |
    v
Nightly run confirms state is clean
```

**Key point:** The script is idempotent. Running it twice does nothing if nothing changed. Running it after a rebuild picks up the new URL and drops the old one in a single pass.

---

## 6a. Cluster Rebuild Runbook

When a cluster is rebuilt, two things break:
1. The policy allowlist no longer contains the new OIDC URL (new FIC writes blocked)
2. Existing FICs still reference the old OIDC URL (workloads can't authenticate)

Both must be fixed. The allowlist refresh handles #1. This script handles #2.

### Update FICs after cluster rebuild

```bash
#!/bin/bash
# update-fics-after-rebuild.sh
# After a cluster rebuild, updates all FICs that referenced the old cluster's OIDC URL
#
# Usage: ./update-fics-after-rebuild.sh <old-oidc-url> <new-oidc-url> [--dry-run]

set -euo pipefail

OLD_OIDC="${1:?Usage: $0 <old-oidc-url> <new-oidc-url> [--dry-run]}"
NEW_OIDC="${2:?Usage: $0 <old-oidc-url> <new-oidc-url> [--dry-run]}"
DRY_RUN="${3:-}"

echo "=== FIC Issuer URL Migration ==="
echo "Old OIDC: ${OLD_OIDC}"
echo "New OIDC: ${NEW_OIDC}"
[ "$DRY_RUN" = "--dry-run" ] && echo "MODE: DRY RUN (no changes will be made)"
echo ""

MGMT_GROUP="${MGMT_GROUP:-mg-platform}"
UPDATED=0
FOUND=0

az account management-group show \
  --name "$MGMT_GROUP" \
  --expand children --recurse \
  --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].name || children[].children[?type=='Microsoft.Management/managementGroups/subscriptions'].name | []" -o tsv \
  | while read SUB_ID; do

  SUB_NAME=$(az account show --subscription "$SUB_ID" --query name -o tsv 2>/dev/null || echo "unknown")

  # Get all UAMIs in this subscription
  UAMIS=$(az identity list --subscription "$SUB_ID" --query "[].{id:id, name:name, rg:resourceGroup}" -o json 2>/dev/null || echo "[]")

  echo "$UAMIS" | jq -r '.[] | "\(.id)|\(.rg)|\(.name)"' | while IFS='|' read UAMI_ID RG UAMI_NAME; do

    # Get FICs for this UAMI
    FICS=$(az rest --method GET \
      --url "https://management.azure.com${UAMI_ID}/federatedIdentityCredentials?api-version=2023-01-31" \
      --query "value[?properties.issuer=='${OLD_OIDC}']" -o json 2>/dev/null || echo "[]")

    FIC_COUNT=$(echo "$FICS" | jq length)
    if [ "$FIC_COUNT" -eq 0 ]; then
      continue
    fi

    echo "$FICS" | jq -r '.[] | "\(.name)|\(.properties.subject)|\(.properties.audiences[0])"' | while IFS='|' read FIC_NAME SUBJECT AUDIENCE; do
      FOUND=$((FOUND + 1))
      echo "FOUND: ${SUB_NAME} / ${RG} / ${UAMI_NAME} / ${FIC_NAME}"
      echo "  Subject:  ${SUBJECT}"
      echo "  Old OIDC: ${OLD_OIDC}"
      echo "  New OIDC: ${NEW_OIDC}"

      if [ "$DRY_RUN" = "--dry-run" ]; then
        echo "  ACTION: would update (dry run)"
      else
        az identity federated-credential update \
          --identity-name "$UAMI_NAME" \
          --resource-group "$RG" \
          --subscription "$SUB_ID" \
          --name "$FIC_NAME" \
          --issuer "$NEW_OIDC" \
          2>/dev/null && echo "  ACTION: UPDATED" || echo "  ACTION: FAILED"
        UPDATED=$((UPDATED + 1))
      fi
      echo ""
    done
  done
done

echo "=== Complete ==="
echo "FICs found referencing old OIDC: review output above"
echo "Run without --dry-run to apply changes"
```

### Full rebuild sequence

```bash
# 1. Cluster rebuilt — get the new OIDC URL
NEW_OIDC=$(az aks show -g $RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)
OLD_OIDC="https://uksouth.oic.prod-aks.azure.com/<tenant>/<old-uuid>/"

# 2. Update the policy allowlists (adds new URL, removes old)
./refresh-oidc-allowlists.sh mg-platform "$POLICY_ID"

# 3. Dry-run: see which FICs need updating
./update-fics-after-rebuild.sh "$OLD_OIDC" "$NEW_OIDC" --dry-run

# 4. Apply FIC updates
./update-fics-after-rebuild.sh "$OLD_OIDC" "$NEW_OIDC"

# 5. Verify workloads can authenticate on the new cluster
```

---

## 7. Audit Existing FICs — Management Group Scope

Before enabling the policy, audit all existing FICs across the management group.

```bash
#!/bin/bash
# audit-fics.sh
# Audits all FederatedIdentityCredentials across a management group
# Flags any cross-environment bindings

set -euo pipefail

MGMT_GROUP="${1:?Usage: $0 <management-group-name> <allowlist-dir>}"
ALLOWLIST_DIR="${2:-.}"

echo "=== FIC Cross-Environment Audit ==="
echo "Management group: ${MGMT_GROUP}"
echo ""

VIOLATIONS=0
TOTAL=0

az account management-group show \
  --name "$MGMT_GROUP" \
  --expand children --recurse \
  --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].name || children[].children[?type=='Microsoft.Management/managementGroups/subscriptions'].name | []" -o tsv \
  | while read SUB_ID; do

  SUB_ENV=$(az tag list --resource-id "/subscriptions/${SUB_ID}" \
    --query "properties.tags.\"op-environment\"" -o tsv 2>/dev/null || echo "untagged")
  SUB_NAME=$(az account show --subscription "$SUB_ID" --query name -o tsv 2>/dev/null || echo "unknown")

  ALLOWLIST_FILE="${ALLOWLIST_DIR}/allowlist-${SUB_ENV}.json"

  echo "--- ${SUB_NAME} (${SUB_ID}) [op-environment: ${SUB_ENV}] ---"

  # Get all UAMIs in this subscription
  UAMIS=$(az identity list --subscription "$SUB_ID" --query "[].id" -o tsv 2>/dev/null || echo "")

  for UAMI_ID in $UAMIS; do
    UAMI_NAME=$(basename "$UAMI_ID")

    # Get FICs for this UAMI
    FICS=$(az rest --method GET \
      --url "https://management.azure.com${UAMI_ID}/federatedIdentityCredentials?api-version=2023-01-31" \
      --query "value[]" -o json 2>/dev/null || echo "[]")

    FIC_COUNT=$(echo "$FICS" | jq length)
    if [ "$FIC_COUNT" -eq 0 ]; then
      continue
    fi

    echo "$FICS" | jq -r '.[] | "\(.name)|\(.properties.issuer)|\(.properties.subject)"' | while IFS='|' read FIC_NAME ISSUER SUBJECT; do
      TOTAL=$((TOTAL + 1))

      # Check if issuer is in the environment's allowlist
      if [ -f "$ALLOWLIST_FILE" ]; then
        IN_LIST=$(jq -r --arg issuer "$ISSUER" 'if index($issuer) then "YES" else "NO" end' < "$ALLOWLIST_FILE")
      else
        IN_LIST="NO_ALLOWLIST"
      fi

      if [ "$IN_LIST" != "YES" ]; then
        VIOLATIONS=$((VIOLATIONS + 1))
        echo "  VIOLATION: ${UAMI_NAME} / ${FIC_NAME}"
        echo "    Issuer:  ${ISSUER}"
        echo "    Subject: ${SUBJECT}"
        echo "    Reason:  Issuer not in ${SUB_ENV} allowlist"
      fi
    done
  done
done

echo ""
echo "=== Audit complete ==="
echo "Violations found: review output above"
echo "Action required: remediate or exempt violations BEFORE switching policy to Deny"
```

---

## 8. Rollout Plan

### Week 1: Inventory

1. Run `generate-oidc-allowlists.sh` against the management group
2. Review output — confirm all clusters are tagged, no mismatches
3. Run `audit-fics.sh` — identify any existing cross-environment bindings
4. Remediate or document exemptions for any existing violations

**Blocking gate:** Do NOT deploy policy until existing violations are understood.

### Week 2: Deploy in Audit mode

1. Create policy definition at management group level
2. Run `assign-fic-policy.sh` with `Audit` effect
3. Monitor Azure Policy compliance dashboard for 1 week
4. Verify zero false positives

### Week 3: Deploy nightly refresh + test rebuild scenario

1. Set up nightly pipeline schedule running `refresh-oidc-allowlists.sh`
2. Add monitoring/alerting on pipeline health (did it run? did it fail?)
3. Test manual trigger: rebuild a dev cluster, run the script, verify allowlist updates
4. Test FIC migration: run `update-fics-after-rebuild.sh` in dry-run mode against the rebuilt cluster

### Week 4: Switch to Deny mode

1. Confirm zero compliance violations in Audit
2. Define and document the policy exemption process
3. Run `assign-fic-policy.sh` with `Deny` effect
4. Test: attempt cross-environment FIC creation, confirm denial
5. Communicate to teams

---

## 9. Testing the Policy

### Positive test (same environment — should succeed)

```bash
# In a prod subscription, create FIC with issuer from a prod cluster
az identity federated-credential create \
  --identity-name uami-prod-app \
  --resource-group rg-prod \
  --name test-fic-same-env \
  --issuer "https://uksouth.oic.prod-aks.azure.com/<tenant>/<PROD-CLUSTER-UUID>/" \
  --subject "system:serviceaccount:app-ns:app-sa" \
  --audiences "api://AzureADTokenExchange"
# Expected: SUCCESS
```

### Negative test (cross environment — should be denied)

```bash
# In a prod subscription, create FIC with issuer from a dev cluster
az identity federated-credential create \
  --identity-name uami-prod-app \
  --resource-group rg-prod \
  --name test-fic-cross-env \
  --issuer "https://uksouth.oic.prod-aks.azure.com/<tenant>/<DEV-CLUSTER-UUID>/" \
  --subject "system:serviceaccount:default:attacker-sa" \
  --audiences "api://AzureADTokenExchange"
# Expected: DENIED ("OIDC issuer does not belong to a cluster in the same op-environment")
```

### Cross-environment matrix test

| UAMI subscription env | Cluster OIDC env | Expected |
|---|---|---|
| `prod` | `prod` | ALLOW |
| `prod` | `pre-prod` | DENY |
| `prod` | `dev` | DENY |
| `pre-prod` | `pre-prod` | ALLOW |
| `pre-prod` | `prod` | DENY |
| `pre-prod` | `dev` | DENY |
| `dev` | `dev` | ALLOW |
| `dev` | `prod` | DENY |
| `dev` | `pre-prod` | DENY |

---

## 10. Monitoring and Alerting

| What | How | Priority |
|---|---|---|
| Policy violations (Audit mode) | Azure Policy compliance dashboard | Check daily during rollout |
| Policy denials (Deny mode) | Activity Log: `Microsoft.Authorization/policyAssignments/deny` | Alert in real-time |
| FIC write/delete events | Activity Log alert on `federatedIdentityCredentials/write` and `/delete` | Alert in real-time |
| Policy exemption creation | Activity Log alert on `policyExemptions/write` | Alert in real-time |
| Nightly refresh pipeline failure | Pipeline health monitoring | Alert if nightly run fails |
| Allowlist staleness | Compare pipeline last-run timestamp vs 36-hour threshold | Alert if stale (missed nightly run) |
| Cluster/subscription env mismatch | Output of allowlist generation script | Review on each run |

---

## 11. Known Limitations

| Limitation | Impact | Mitigation |
|---|---|---|
| Policy propagation delay (5-30 min ARM cache) | Window where new deny rules aren't enforced | Allowlist refresh runs ahead of cluster provisioning |
| `Owner` can create policy exemptions | Bypasses the deny entirely | Alert on `policyExemptions/write` |
| Allowlist static between refreshes | Stale until nightly run or manual trigger | Manual trigger after rebuild; nightly catches anything missed |
| Policy evaluates at write time only | Existing non-compliant FICs not retroactively blocked | Audit all existing FICs before enabling Deny |
| `op-environment` tag must be accurate | Wrong tag = wrong allowlist = wrong environment boundary | Already in place and consistent |
| Cross-subscription allowlist update | New cluster in sub-A must appear in sub-B's allowlist if same env | Refresh script queries entire management group every run |
| Management group query permissions | Allowlist pipeline needs Reader across all subscriptions | Use a management group-scoped identity |
