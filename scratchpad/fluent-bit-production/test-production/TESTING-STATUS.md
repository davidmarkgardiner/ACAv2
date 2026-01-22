# Testing Status

## Verified Working: 2026-01-20

Full pipeline tested on `kind-argo-workflow` cluster.

---

## EventHub Integration Testing: 2026-01-20

### Azure Resources Created

| Resource | Name | Location |
|----------|------|----------|
| EventHub Namespace | `k8s-events-hub-fb` | uksouth |
| EventHub | `kube-events` | - |
| Resource Group | `k8s-cluster` | uksouth |
| Consumer Group | `$Default` | Basic tier |
| K8s Secret | `eventhub-listener-secret` | argo-events |

### EventHub Test Results

| Component | Status | Notes |
|-----------|--------|-------|
| EventHub Namespace Creation | ✅ Pass | Created successfully |
| EventHub Creation | ✅ Pass | 2 partitions, 1 day retention |
| K8s Secret Creation | ✅ Pass | SAS key stored |
| EventSource Deployment | ✅ Pass | Connected to partitions |
| EventSource Message Processing (v1.9.9) | ❌ BUG | Panic on message receive |
| **EventSource Message Processing (v1.9.5)** | ✅ **FIXED** | Downgrade resolved the issue |
| **Full Pipeline via EventHub** | ✅ **PASS** | Holmes → GitLab → Mattermost |

### Bug Discovered & Fixed: Argo Events v1.9.6+

**Issue**: Azure EventHub EventSource panics when receiving messages in v1.9.6, v1.9.7, v1.9.8, v1.9.9

```
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x1c52df4]
```

**Fix**: Downgrade to Argo Events **v1.9.5** (Helm chart **2.4.14**)

```bash
helm upgrade argo-events argo/argo-events \
  --namespace argo-events \
  --version 2.4.14 \
  --reuse-values
```

See [GitHub Issue #3595](https://github.com/argoproj/argo-events/issues/3595) for details.

### EventHub Full Pipeline Test: ✅ PASS

After downgrading to v1.9.5, the full pipeline works:

```
Azure EventHub → Argo EventSource → Sensor → Holmes AI → GitLab Issue → Mattermost
```

**Successful Workflows:**
- `eh-debug-87gh5` - Debug workflow (EventHub)
- `eh-debug-r95fn` - Debug workflow (EventHub)
- `eh-triage-4v6mw` - Full triage workflow (EventHub → Holmes → GitLab)

---

### Test Results

| Component | Status | Notes |
|-----------|--------|-------|
| Webhook → Sensor | ✅ Pass | Events processed, Base64 decoded |
| Holmes Investigation | ✅ Pass | Real kubectl queries executed |
| GitLab Issue Creation | ✅ Pass | Issues created with full analysis |
| Mattermost Notification | ✅ Pass | Summary + recommendations sent |

### GitLab Issues Created During Testing

- https://gitlab.com/xxxmarkgardiner/mcp-test-repo/-/issues/227
- https://gitlab.com/xxxmarkgardiner/mcp-test-repo/-/issues/228
- https://gitlab.com/xxxmarkgardiner/mcp-test-repo/-/issues/229
- https://gitlab.com/xxxmarkgardiner/mcp-test-repo/-/issues/230
- https://gitlab.com/xxxmarkgardiner/mcp-test-repo/-/issues/231

### Holmes Verification

Holmes executed real kubectl commands during investigation:

```
kubectl get -A --show-labels -o wide namespace
kubectl get -A --show-labels -o wide pod | grep test-pod-abc123
kubectl get pods --all-namespaces -o custom-columns='NAME,NAMESPACE,STATUS,RESTARTS,IMAGE'
kubectl get pods -o json | jq '...ImagePullBackOff...'
kubectl get events -o json | jq '...BackOff...'
```

### Configuration Used

| Component | Value |
|-----------|-------|
| Holmes Model | `claude-sonnet-4-20250514` |
| Holmes Health Endpoint | `/healthz` |
| Holmes API Endpoint | `/api/investigate` |
| GitLab Project | `xxxmarkgardiner/mcp-test-repo` |
| Mattermost Webhook | `http://mattermost.mattermost.svc.cluster.local:8065/hooks/xxx` |

### Issues Fixed During Testing

1. **Holmes health endpoint**: Changed `/health` → `/healthz`
2. **Holmes model**: Updated from deprecated `claude-3-5-sonnet-20241022` → `claude-sonnet-4-20250514`
3. **workflowtaskresults RBAC**: Added permission to Role
4. **ServiceAccount**: Ensured workflow uses `argo-events-sa`
5. **Mattermost emoji**: Changed `:gitlab:` → `:link:`
6. **Notification truncation**: Fixed to show complete recommendations
