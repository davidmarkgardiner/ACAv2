# External Integrations — GitLab + Mattermost

Both integrations are optional. The pipeline runs without them — KAgent analysis still executes and results are visible in the Argo Workflows UI.

## GitLab (Issue Tracking)

### What it does
When a triage or remediation workflow completes, it creates a GitLab issue with:
- Alert metadata (cluster, namespace, resource, severity)
- Full KAgent analysis (root cause, evidence, recommended fixes)
- Quick kubectl commands for manual follow-up
- Raw A2A response in a collapsible section

### Setup

1. Create a Personal Access Token at `https://gitlab.com/-/user_settings/personal_access_tokens`
   - Scope: `api`
   - Expiry: set per your org policy

2. Create the K8s secret:
   ```bash
   kubectl create secret generic gitlab-token -n argo \
     --from-literal=GITLAB_TOKEN='glpat-YOUR-TOKEN-HERE'
   ```

3. Find your project ID: GitLab project -> Settings -> General -> Project ID

4. The workflow templates default to project ID `68265584`. To change:
   ```bash
   # Update all workflow templates at once
   for wft in kagent-sre-workflow local-llm-analysis holmes-remediation; do
     kubectl get workflowtemplate $wft -n argo -o yaml 2>/dev/null | \
       sed 's/68265584/YOUR_PROJECT_ID/' | kubectl apply -f - 2>/dev/null || true
   done
   ```

### What gets created

Example GitLab issue title:
```
[:wrench:][proxmox-k8s] ImagePullBackOff: default/crash-test
```

Example labels: `kagent, triage, ImagePullBackOff, high, auto-generated`

### Without GitLab
The `create-gitlab-issue` step fails but the workflow continues (`continueOn: {failed: true}`). The Mattermost notification still fires. The KAgent analysis is still in the workflow logs.

---

## Mattermost (Real-Time Notifications)

### What it does
Posts a formatted card to a Mattermost channel with:
- Alert summary table (cluster, event, resource, severity)
- KAgent analysis (truncated to 2000 chars)
- Quick kubectl commands
- Link to the GitLab issue

### Setup

1. In Mattermost: Main Menu -> Integrations -> Incoming Webhooks -> Add Incoming Webhook
   - Choose the channel for alerts
   - Copy the webhook URL

2. Create the K8s secret (for workflow templates in `argo` namespace):
   ```bash
   kubectl create secret generic mattermost-webhook -n argo \
     --from-literal=url='https://mattermost.your-domain.com/hooks/YOUR-WEBHOOK-ID'
   ```

3. For the Prometheus alerting pipeline (workflows in `argo-events` namespace):
   ```bash
   kubectl create configmap mattermost-webhook-config -n argo-events \
     --from-literal=WEBHOOK_URL='https://mattermost.your-domain.com/hooks/YOUR-WEBHOOK-ID'
   ```

### Message format

The Mattermost notification includes:
```
### :mag: Triage Complete
| Field | Value |
|---|---|
| Cluster | proxmox-k8s |
| Event | ImagePullBackOff |
| Resource | Pod/crash-test |
| Namespace | default |
| Severity | high |
| Agent | sre-triage-agent |
| Duration | 55s (8 turns) |
| GitLab | #123 |

---
#### Analysis Summary
[KAgent's analysis text...]

---
#### Quick Commands
kubectl describe pod crash-test -n default
kubectl logs crash-test -n default --tail=100
```

### Without Mattermost
The notify step checks if the webhook URL is empty/placeholder and exits cleanly with code 0. The workflow succeeds.

---

## Both Missing? That's Fine.

The core pipeline is:

```
Alert -> Argo Events -> Workflow -> KAgent AI Analysis
```

GitLab and Mattermost are reporting channels. The analysis runs regardless. View results in:

```bash
# Argo Workflows UI
kubectl port-forward -n argo svc/argo-server 2746:2746
# Visit https://localhost:2746

# Or CLI
argo logs -n argo @latest
argo logs -n argo-events @latest
```

---

## Telegram (Alternative to Mattermost)

The Prometheus alerting pipeline (`../prometheus-alerting/`) has a separate Telegram notification path. If you prefer Telegram:

```bash
kubectl create secret generic telegram-credentials -n argo-events \
  --from-literal=bot-token='YOUR-BOT-TOKEN' \
  --from-literal=chat-id='YOUR-CHAT-ID'
```

The workflow template in `../prometheus-alerting/04-workflow-template.yaml` handles Telegram if the secret exists.
