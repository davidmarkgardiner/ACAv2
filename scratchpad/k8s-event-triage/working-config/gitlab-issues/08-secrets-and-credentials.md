<!--
Labels: infrastructure, security, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# Create production secrets (Gitea, Mattermost, Event Hub)

## Context

The v2 WorkflowTemplate requires several secrets with **exact key names** (see GOTCHAS.md #2). These must be created before enabling the v2 template.

## Secrets Required

### gitea-credentials (argo-events namespace)
| Key | Value | Notes |
|-----|-------|-------|
| `token` | Gitea API token | Personal access token with repo write |
| `base-url` | `https://gitea.example.com` | No trailing slash |
| `repo-owner` | `ops` | Organisation or user |
| `repo-name` | `k8s-incidents` | Must exist beforehand |

### mattermost-webhook (argo-events namespace)
| Key | Value | Notes |
|-----|-------|-------|
| `url` | `https://mattermost.example.com/hooks/<TOKEN>` | Incoming webhook URL |

### eventhub-credentials (argo-events namespace) — already exists from PoC
| Key | Value | Notes |
|-----|-------|-------|
| `username` | `$ConnectionString` | Literal string |
| `connection-string` | `Endpoint=sb://...` | SAS connection string |

### eventhub-tls-ca (argo-events namespace) — already exists from PoC
| Key | Value | Notes |
|-----|-------|-------|
| `ca.pem` | PEM certificate chain | NOT `ca.crt` |

## Tasks

- [ ] Create Gitea API token (scope: repo write)
- [ ] Create Gitea repo `k8s-incidents` if it doesn't exist
- [ ] Create `gitea-credentials` secret with exact key names
- [ ] Create Mattermost incoming webhook
- [ ] Create `mattermost-webhook` secret with exact key name `url`
- [ ] Verify existing Event Hub secrets are correct
- [ ] Verify all secrets: `kubectl get secret -n argo-events -o json | jq '.items[].metadata.name'`

## Verification

```bash
# Verify exact key names (critical — wrong keys cause silent failures)
for secret in gitea-credentials mattermost-webhook eventhub-credentials eventhub-tls-ca; do
  echo "=== $secret ==="
  kubectl get secret $secret -n argo-events -o jsonpath='{.data}' | python3 -c "import sys,json; [print(f'  {k}') for k in json.load(sys.stdin)]"
done
```

## Acceptance Criteria

- [ ] All 4 secrets exist in `argo-events` namespace
- [ ] Key names match exactly (verified with script above)
- [ ] Gitea token can create issues (test with curl)
- [ ] Mattermost webhook delivers messages (test with curl)
