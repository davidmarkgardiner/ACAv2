# Quick Test — Critical Tier Workflow

Test the `k8s-triage-critical` workflow template without needing Event Hub, Alloy, or real events.

Verified working on proxmox-k8s (2026-02-23): 3/3 steps Succeeded in 20s, jq parsed correctly, fan-out created 2 pods, graceful degradation when KAgent/GitLab/Mattermost not configured.

---

## Prerequisites

### 1. Workflow template applied

```bash
kubectl apply -f workflow-template.yaml
kubectl get workflowtemplate k8s-triage-critical -n argo-events
```

### 2. ConfigMaps exist (create if missing)

For **parse-only testing** (no KAgent/GitLab/Mattermost), create with empty values:

```bash
kubectl create configmap kagent-config -n argo-events \
  --from-literal=KAGENT_URL="" \
  --from-literal=KAGENT_CRITICAL_AGENT="" \
  --from-literal=KAGENT_WARNINGS_AGENT="" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap mattermost-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL="" \
  --dry-run=client -o yaml | kubectl apply -f -
```

For **full pipeline testing**, set real values:

```bash
kubectl create configmap kagent-config -n argo-events \
  --from-literal=KAGENT_URL="http://kagent-a2a.kagent.svc.cluster.local" \
  --from-literal=KAGENT_CRITICAL_AGENT="sre-triage-agent" \
  --from-literal=KAGENT_WARNINGS_AGENT="sre-triage-agent" \
  --dry-run=client -o yaml | kubectl apply -f -

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

Tests that OTLP parsing and critical event filtering work. KAgent/GitLab/Mattermost are skipped gracefully when ConfigMaps have empty values.

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
  podGC: {}
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

# Watch it run
argo watch -n argo-events @latest

# Get logs IMMEDIATELY after completion (pods are cleaned up fast)
argo logs -n argo-events @latest

# Or check step details + output parameters
argo get -n argo-events @latest
```

**Expected result (verified):**
- `parse-otlp`: Succeeds (~4s), outputs 2 events (CrashLoopBackOff + FailedScheduling), filters out the Normal/Pulled event
- `process-event(0)` + `process-event(1)`: Both run in parallel (~4s each), print graceful skip messages
- All 3/3 steps green, total ~20s

---

## Test 2: Full Pipeline (KAgent + GitLab + Mattermost)

Same YAML file as Test 1 — just update the ConfigMaps to point to real services first (see prerequisites).

```bash
# Verify your configs are set
kubectl get configmap kagent-config -n argo-events -o yaml
kubectl get configmap mattermost-webhook-config -n argo-events -o yaml
kubectl get secret gitlab-token -n argo-events

# Run the same test
kubectl create -f test-parse-only.yaml
```

**Expected result:**
- `parse-otlp`: Same as Test 1
- `process-event(0)`: KAgent A2A call → GitLab issue created → Mattermost notification sent
- `process-event(1)`: Same for second event

---

## Test 3: Single Event (Minimal)

For the quickest possible smoke test with just one event — run directly, no file needed:

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
  podGC: {}
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

**Expected:** 1 event parsed, 1 process-event pod, 2/2 steps green.

---

## Checking Results

```bash
# List recent workflows
argo list -n argo-events --sort-by=.metadata.creationTimestamp | head

# Get logs (use argo CLI — pods are cleaned up by podGC)
argo logs -n argo-events @latest

# Detailed step status
argo get -n argo-events @latest

# Check parse-otlp output (jq extraction + event count)
argo get -n argo-events @latest -o json | jq '.status.nodes[] | select(.displayName == "parse-otlp") | .outputs.parameters'
```

### What to look for in logs

**parse-otlp step** (may not appear in `argo logs` if it finishes before log collector starts — check output params instead):
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

## Test 4: Event Deduplication (memoize)

Tests that the same event within 24h is skipped (memoized) on second submission.

**Step 1: Submit the first workflow**

```bash
kubectl create -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-dedup-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-triage-critical
  podGC: {}
  arguments:
    parameters:
      - name: otlp-payload
        value: '{"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"dedup-cluster"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",\"message\":\"back-off restarting container\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"dedup-test-pod\",\"namespace\":\"default\"},\"count\":1}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"CrashLoopBackOff"}}]}]}]}]}'
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

Wait for completion:

```bash
argo watch -n argo-events @latest
```

**Expected:** `investigate-and-report` runs fully (not memoized).

**Step 2: Submit the identical workflow again**

Run the exact same `kubectl create` command above again.

```bash
argo watch -n argo-events @latest
```

**Expected:** `investigate-and-report` step shows as **memoized/skipped** — the step completes instantly without running the script.

**Step 3: Verify the cache ConfigMap**

```bash
# Cache lives in the argo namespace (controller namespace), not argo-events
kubectl get configmap event-dedup-cache -n argo -o yaml
```

You should see a cached key like `dedup-cluster-default-dedup-test-pod-CrashLoopBackOff`.

**Step 4: Verify different pod is NOT deduped**

Submit a workflow with a different pod name — it should run fully (different cache key):

```bash
kubectl create -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-dedup-different-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-triage-critical
  podGC: {}
  arguments:
    parameters:
      - name: otlp-payload
        value: '{"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"dedup-cluster"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",\"message\":\"back-off restarting container\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"different-pod\",\"namespace\":\"default\"},\"count\":1}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"CrashLoopBackOff"}}]}]}]}]}'
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

**Expected:** Runs fully — different pod name = different cache key.

---

## Test 5: Remediation Mode Toggle

Tests the `remediate` parameter override. No template change needed — just pass `remediate: "true"`.

```bash
kubectl create -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-remediate-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-triage-critical
  podGC: {}
  arguments:
    parameters:
      - name: otlp-payload
        value: '{"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"my-cluster"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"OOMKilled\",\"message\":\"container killed due to OOM\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"oom-test-pod\",\"namespace\":\"staging\"},\"count\":1}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"OOMKilled"}}]}]}]}]}'
      - name: kagent-url
        value: ""
      - name: kagent-agent
        value: ""
      - name: remediate
        value: "true"
      - name: gitlab-project-id
        value: ""
      - name: gitlab-url
        value: "https://gitlab.com"
EOF
```

```bash
argo logs -n argo-events @latest
```

**Expected in logs:**
- `Remediate: true` in the header
- `MODE_LABEL="REMEDIATION"` path taken
- parse-otlp routes to `sre-remediation-agent` (instead of `sre-triage-agent`)
- If KAgent is configured: A2A prompt says "Fix this CRITICAL K8s issue..." instead of "Investigate..."

**With KAgent configured**, also check:
- GitLab issue title has `:wrench:` emoji and `REMEDIATION APPLIED` label
- Mattermost notification reflects remediation mode

---

## Cleanup

```bash
# Delete test workflows
argo delete -n argo-events --selector workflows.argoproj.io/workflow-template=k8s-triage-critical

# Or delete all completed
argo delete -n argo-events --completed

# Clear dedup cache (to re-test memoize) — lives in argo namespace (controller)
kubectl delete configmap event-dedup-cache -n argo --ignore-not-found
```

---

## Important Notes

### podGC behaviour

The workflow template uses `podGC: OnPodCompletion` which cleans up pods as soon as each step finishes. This means:
- **Pod logs disappear quickly** — you can't `kubectl logs` completed pods
- **Use `argo logs`** instead — it captures logs from the workflow controller
- **Use `argo get -o json`** to inspect output parameters (always available even after pods are gone)
- The test files set `podGC: {}` to try to override, but the template's setting takes precedence

### podGC strategy values

| Strategy | Valid? | Behaviour |
|----------|--------|-----------|
| `OnPodCompletion` | Yes | Deletes pod when step completes |
| `OnPodSuccess` | Yes | Deletes pod only on success |
| `OnWorkflowCompletion` | Yes | Deletes all pods when workflow ends |
| `OnWorkflowSuccess` | Yes | Deletes all pods only on workflow success |
| `Never` | **NO** — fails with "unknown strategy" | |
| `""` (empty string) | Works but template default still applies | |

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
| Pods disappear before logs | podGC cleaning up | Use `argo logs` not `kubectl logs`, or check output params via `argo get -o json` |
| `unknown strategy 'Never'` | Invalid podGC value | Use `podGC: {}` or omit podGC entirely |
| `investigate-and-report` skipped unexpectedly | memoize cache hit (24h dedup) | Delete ConfigMap: `kubectl delete cm event-dedup-cache -n argo` |
| memoize "configmaps is forbidden" | Controller SA missing ConfigMap create/update | Patch `argo-cluster-role` to add `create`, `update` verbs on `configmaps` resource |
