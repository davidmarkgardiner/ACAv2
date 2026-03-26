Good question. These are two separate logging mechanisms in Azure that complement each other rather than one replacing the other.

## Microsoft Defender for Containers on AKS

When Defender is enabled on an AKS cluster, it deploys a **DaemonSet** (`microsoft-defender-collector-ds`) into the cluster. The logs and security signals it collects go to:

- **Microsoft Defender for Cloud** — security alerts, vulnerability assessments, threat detections
- **Microsoft Sentinel** (if connected) — via the Defender for Cloud connector
- **Log Analytics Workspace** — specifically the `SecurityAlert`, `SecurityRecommendation`, and `DefenderForContainersSecurity*` tables

The workspace used is whichever one is configured in **Defender for Cloud → Environment Settings → your subscription/workspace**.

---

## Diagnostic Settings (separate, not replaced)

Diagnostic settings configured on the AKS resource itself are completely independent. They capture:

| Log Category | What it contains |
|---|---|
| `kube-apiserver` | API server audit logs |
| `kube-controller-manager` | Controller decisions |
| `kube-scheduler` | Scheduling decisions |
| `kube-audit` / `kube-audit-admin` | Full audit trail |
| `cluster-autoscaler` | Scale events |
| `guard` | AAD/RBAC auth logs |

These go wherever **you** point them — a Log Analytics Workspace, Storage Account, or Event Hub — based on what's defined in the ARM template's `microsoft.insights/diagnosticSettings` resource.

---

## The Key Distinction

| | Defender for Containers | Diagnostic Settings |
|---|---|---|
| **Scope** | Security signals, threat detection, runtime behaviour | Control plane operational logs |
| **Destination** | Defender for Cloud / designated LA Workspace | Your configured destination |
| **Configured by** | Defender for Cloud policy / subscription-level | ARM template / AzPolicy on the AKS resource |
| **Replaces each other?** | ❌ No | ❌ No |

---

## In your ARM template context

Your ARM template will have something like:

```json
{
  "type": "Microsoft.Insights/diagnosticSettings",
  "properties": {
    "workspaceId": "[parameters('logAnalyticsWorkspaceId')]",
    "logs": [
      { "category": "kube-audit", "enabled": true },
      { "category": "kube-apiserver", "enabled": true }
    ]
  }
}
```

That's orthogonal to Defender. If you're deploying Defender via ARM, you'd also have a `Microsoft.Security/pricings` resource or you're relying on a policy assignment — but that doesn't touch diagnostic settings at all.

**Bottom line:** run both. Diagnostic settings give you the operational/audit trail; Defender gives you the security intelligence layer on top of it.


---

If diagnostic settings are turned on, you choose the destination — Azure gives you three options:

1. **Log Analytics Workspace** — most common, queryable via KQL in the Azure portal or via your LGTM/Grafana stack
2. **Storage Account** — blob storage, JSON format, good for long-term archival/compliance
3. **Event Hub** — streaming out to external consumers like Splunk, Sentinel, or your own pipeline

You can send to **all three simultaneously** if needed.

---

The destination is whatever is specified in the diagnostic settings configuration itself — there's no default. So if your ARM templates are deploying clusters with diagnostic settings enabled, the target workspace/storage account/event hub will be defined in that resource block in the template.

If you're not sure where yours are pointed, quickest check is:

```bash
az monitor diagnostic-settings list \
  --resource <aks-resource-id> \
  --query "[].{name:name, workspace:workspaceId, storage:storageAccountId, hub:eventHubAuthorizationRuleId}"
```

That'll tell you exactly where each cluster's diagnostics are being sent.