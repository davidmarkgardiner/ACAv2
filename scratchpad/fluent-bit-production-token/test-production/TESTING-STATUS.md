# Testing Status

## Verified Working: 2026-01-19

Full pipeline tested on `kind-argo-workflow` cluster.

### Test Results

| Component | Status | Notes |
|-----------|--------|-------|
| Webhook → Sensor | ✅ Pass | Events processed, Base64 decoded |
| Holmes Investigation | ✅ Pass | Real kubectl queries executed |
| GitLab Issue Creation | ✅ Pass | Issues created with full analysis |
| Mattermost Notification | ✅ Pass | Summary + recommendations sent |

### GitLab Issues Created During Testing

- https://gitlab.com/davidmarkgardiner/mcp-test-repo/-/issues/227
- https://gitlab.com/davidmarkgardiner/mcp-test-repo/-/issues/228
- https://gitlab.com/davidmarkgardiner/mcp-test-repo/-/issues/229
- https://gitlab.com/davidmarkgardiner/mcp-test-repo/-/issues/230
- https://gitlab.com/davidmarkgardiner/mcp-test-repo/-/issues/231

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
| GitLab Project | `davidmarkgardiner/mcp-test-repo` |
| Mattermost Webhook | `http://mattermost.mattermost.svc.cluster.local:8065/hooks/xxx` |

### Issues Fixed During Testing

1. **Holmes health endpoint**: Changed `/health` → `/healthz`
2. **Holmes model**: Updated from deprecated `claude-3-5-sonnet-20241022` → `claude-sonnet-4-20250514`
3. **workflowtaskresults RBAC**: Added permission to Role
4. **ServiceAccount**: Ensured workflow uses `argo-events-sa`
5. **Mattermost emoji**: Changed `:gitlab:` → `:link:`
6. **Notification truncation**: Fixed to show complete recommendations
