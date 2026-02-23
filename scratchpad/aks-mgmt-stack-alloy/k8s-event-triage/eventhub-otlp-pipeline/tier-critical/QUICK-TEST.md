# Quick Test — Critical Tier Workflow

Test the `k8s-triage-critical` workflow template without needing Event Hub, Alloy, or real events.

---

## Prerequisites

### 1. Workflow template applied

```bash
kubectl apply -f workflow-template.yaml
kubectl get workflowtemplate k8s-triage-critical -n argo-events
```

### 2. ConfigMaps exist (create if missing)

```bash
# KAgent config — update KAGENT_URL to your actual KAgent service
kubectl create configmap kagent-config -n argo-events \
  --from-literal=KAGENT_URL="http://kagent-a2a.kagent.svc.cluster.local" \
  --from-literal=KAGENT_CRITICAL_AGENT="sre-triage-agent" \
  --from-literal=KAGENT_WARNINGS_AGENT="sre-triage-agent" \
  --dry-run=client -o yaml | kubectl apply -f -

# Mattermost webhook — update with your real webhook URL
kubectl create configmap mattermost-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL="https://mattermost.example.com/hooks/YOUR_HOOK_ID" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3. GitLab token (optional — workflow works without it)

```bash
kubectl create secret generic gitlab-token -n argo-events \
  --from-literal=GITLAB_TOKEN="glpat-xxxx" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Test 1: JQ Parsing Only (no KAgent needed)

Tests that OTLP parsing and critical event filtering work. Deliberately leaves KAgent/GitLab/Mattermost configs empty so they're skipped gracefully.

Save this as `test-parse-only.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-parse-only-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-triage-critical
  podGC:
    strategy: ""
  arguments:
    parameters:
      - name: otlp-payload
        value: |
          {
            "resourceLogs": [{
              "resource": {
                "attributes": [
                  {"key": "cluster", "value": {"stringValue": "my-aks-cluster"}},
                  {"key": "environment", "value": {"stringValue": "dev"}}
                ]
              },
              "scopeLogs": [{
                "logRecords": [
                  {
                    "body": {"stringValue": "{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",\"message\":\"back-off 5m0s restarting failed container=myapp\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"myapp-pod-abc\",\"namespace\":\"dgdemo\"},\"count\":5,\"lastTimestamp\":\"2026-02-20T10:00:00Z\"}"},
                    "attributes": [
                      {"key": "event_type", "value": {"stringValue": "Warning"}},
                      {"key": "event_reason", "value": {"stringValue": "CrashLoopBackOff"}},
                      {"key": "obj_kind", "value": {"stringValue": "Pod"}},
                      {"key": "obj_namespace", "value": {"stringValue": "dgdemo"}}
                    ]
                  },
                  {
                    "body": {"stringValue": "{\"type\":\"Normal\",\"reason\":\"Pulled\",\"message\":\"Successfully pulled image\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"web-xyz\",\"namespace\":\"dgdemo\"},\"count\":1}"},
                    "attributes": [
                      {"key": "event_type", "value": {"stringValue": "Normal"}},
                      {"key": "event_reason", "value": {"stringValue": "Pulled"}}
                    ]
                  },
                  {
                    "body": {"stringValue": "{\"type\":\"Warning\",\"reason\":\"FailedScheduling\",\"message\":\"0/3 nodes are available: insufficient memory\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"big-app-xyz\",\"namespace\":\"production\"},\"count\":3,\"lastTimestamp\":\"2026-02-20T10:05:00Z\"}"},
                    "attributes": [
                      {"key": "event_type", "value": {"stringValue": "Warning"}},
                      {"key": "event_reason", "value": {"stringValue": "FailedScheduling"}},
                      {"key": "obj_kind", "value": {"stringValue": "Pod"}},
                      {"key": "obj_namespace", "value": {"stringValue": "production"}}
                    ]
                  }
                ]
              }]
            }]
          }
      - name: kagent-url
        value: ""
      - name: kagent-agent
        value: ""
      - name: remediate
        value: "false"
      - name: gitlab-project-id
        value: ""
      - name: gitlab-url
        value: "https://gitlab.com"
```

Run:

```bash
kubectl create -f test-parse-only.yaml

# Watch the workflow
argo watch -n argo-events @latest

# Or if you have argo CLI, stream logs in real time (recommended — podGC is disabled):
argo submit -n argo-events --from workflowtemplate/k8s-triage-critical --log \
  -p 'kagent-url=' -p 'kagent-agent=' -p 'remediate=false' \
  -p 'gitlab-project-id=' -p 'gitlab-url=https://gitlab.com' \
  -p 'otlp-payload={"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"test-cluster"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"OOMKilled\",\"message\":\"OOM killed\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"oom-pod\",\"namespace\":\"test-ns\"},\"count\":1}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"OOMKilled"}}]}]}]}]}'
```

**Expected result:**
- `parse-otlp`: Succeeds, outputs 2 events (CrashLoopBackOff + FailedScheduling), filters out the Normal/Pulled
- `process-event(0)` + `process-event(1)`: Both run, print "KAgent not configured, skipping" and "No Mattermost webhook configured, skipping"
- All steps green

---

## Test 2: Full Pipeline (KAgent + GitLab + Mattermost)

Same payload but with real service endpoints. Update the ConfigMaps (prerequisites above), then:

```bash
kubectl create -f test-parse-only.yaml
```

But this time with ConfigMaps pointing to real services:

```bash
# Verify your configs are set
kubectl get configmap kagent-config -n argo-events -o yaml
kubectl get configmap mattermost-webhook-config -n argo-events -o yaml
kubectl get secret gitlab-token -n argo-events
```

**Expected result:**
- `parse-otlp`: Same as Test 1
- `process-event(0)`: KAgent A2A call → GitLab issue created → Mattermost notification sent
- `process-event(1)`: Same for second event

---

## Test 3: Single Event (Minimal)

For the quickest possible test with just one event:

```bash
kubectl create -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-single-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-triage-critical
  podGC:
    strategy: ""
  arguments:
    parameters:
      - name: otlp-payload
        value: '{"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"my-cluster"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",\"message\":\"back-off restarting container\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"test-pod\",\"namespace\":\"default\"},\"count\":1}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"CrashLoopBackOff"}}]}]}]}]}'
      - name: kagent-url
        value: ""
      - name: kagent-agent
        value: ""
      - name: remediate
        value: "false"
      - name: gitlab-project-id
        value: ""
      - name: gitlab-url
        value: "https://gitlab.com"
EOF
```

---

## Checking Results

```bash
# List recent workflows
argo list -n argo-events --sort-by=.metadata.creationTimestamp | head

# Get logs (before podGC cleans up — podGC is disabled in test files)
argo logs -n argo-events @latest

# Detailed step status
argo get -n argo-events @latest
```

### What to look for in logs

**parse-otlp step:**
```
[CRITICAL] 2 critical event(s) from OTLP payload
  - CrashLoopBackOff: Pod/myapp-pod-abc in dgdemo
  - FailedScheduling: Pod/big-app-xyz in production
```

**investigate-and-report step (no KAgent):**
```
==========================================
[CRITICAL] CrashLoopBackOff: Pod/myapp-pod-abc in dgdemo
Cluster: my-aks-cluster | Agent:  | Remediate: false
==========================================
KAgent not configured, skipping analysis
GitLab not configured, skipping issue creation
No Mattermost webhook configured, skipping
```

**investigate-and-report step (with KAgent):**
```
Calling KAgent: sre-triage-agent via A2A...
KAgent HTTP: 200, Duration: 55s
KAgent status: completed, Turns: 3, Analysis: 1247 chars
Creating GitLab issue...
GitLab HTTP: 201
Issue #42: https://gitlab.com/...
Mattermost: HTTP 200
```

---

## Cleanup

```bash
# Delete test workflows
argo delete -n argo-events --selector workflows.argoproj.io/workflow-template=k8s-triage-critical

# Or delete all completed
argo delete -n argo-events --completed
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `parse-otlp` fails | jq parse error | Check OTLP JSON is valid — look at pod logs for the jq error |
| 0 events extracted | No Warning+critical events in payload | Ensure `type: "Warning"` and `reason` is one of: CrashLoopBackOff, OOMKilled, OOMKilling, FailedScheduling, NodeNotReady, NodeNotSchedulable, FailedMount, FailedAttachVolume |
| `process-event` not created | Empty events array | parse-otlp returned `[]` — check the payload has critical events |
| KAgent timeout | KAgent service unreachable | Check `KAGENT_URL` in configmap, verify service exists: `kubectl get svc -n kagent` |
| KAgent A2A error | Wrong agent name or method | Verify agent exists: `kubectl get agents -n kagent`, ensure trailing slash in URL |
| GitLab 401 | Bad token | Check `GITLAB_TOKEN` secret value and project access |
| Mattermost 404 | Bad webhook URL | Verify webhook URL in configmap is correct |
| Pods disappear before logs | podGC cleaning up | Test files above set `podGC.strategy: ""` to disable — if using real sensor trigger, logs must be captured fast or use `argo logs --follow` |
