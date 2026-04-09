# Engineering Rollout — K8s Event Triage

> Phase 1: David does the first namespace end-to-end. Document everything.
> Phase 2: Team gets exposure to all namespaces. GitLab tickets round-robin across the team.
> Phase 3: Hand off to SRE team with a dedicated GitLab board.

**Goal state:** Zero unresolved events. When something breaks, the agent triages it, creates a ticket, and the team picks it up fast. Over time, agents learn to remediate — the human action shifts from "fix it" to "update GitOps/skills so it doesn't happen again."

---

## Decision: GitLab Project Location

**Current state:** Issues go to David's personal project (`68265584`). This won't work for team rollout.

**Options:**

| Option | Pros | Cons |
|--------|------|------|
| **Dedicated project** (`platform/k8s-event-triage`) | Clean separation, own board/labels/milestones | Another project to manage |
| **Existing ops repo** (subgroup issues) | Team already has access | Noise from other issues |
| **Per-cluster projects** | Clear ownership | Too many projects |

**Recommendation:** Dedicated project under the platform group. One Kanban board visible at stand-ups.

### GitLab Project Setup Checklist

- [ ] Create project (e.g. `platform/k8s-event-triage`)
- [ ] Add engineering team as Developers (can manage issues)
- [ ] Add SRE team as Maintainers (phase 3)
- [ ] Create labels:
  - Severity: `critical`, `warning`, `info`
  - Status: `triage`, `remediation`, `resolved`, `false-positive`, `skill-updated`
  - Event reasons: `CrashLoopBackOff`, `OOMKilled`, `FailedScheduling`, `FailedMount`, `NodeNotReady`
  - Auto-generated: `kagent`, `auto-generated`
  - Namespace labels as needed
- [ ] Create Kanban board:
  - **Open** — new issues, auto-created by the pipeline
  - **Triage** — someone is looking at it
  - **Remediated** — agent or human fixed the immediate problem
  - **Skill Updated** — the learning loop is closed (agent can handle this next time)
  - **Resolved** — done, no further action
  - **False Positive** — noise, may need filter tuning
- [ ] Create issue templates for manual triage reports
- [ ] Update `gitlab-project-id` in workflow template
- [ ] Create new GitLab PAT with `api` scope scoped to the new project
- [ ] Update `gitlab-token` secret in `argo-events` namespace

---

## Decision: Team Assignment — Round-Robin

Every issue gets assigned to the next person in the roster. No namespace ownership — everyone sees everything. This gives the whole team exposure and makes it visible at stand-ups who's picking up and who's not.

### How It Works

1. Workflow creates a GitLab issue
2. Reads the `team-roster` ConfigMap to get the list of assignees
3. Picks the next person sequentially (based on a counter in a ConfigMap)
4. Assigns the issue to that person via the GitLab API
5. The person gets a GitLab notification and sees it on the Kanban board

### Team Roster ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: team-roster
  namespace: argo-events
  labels:
    app.kubernetes.io/part-of: k8s-event-triage
data:
  # GitLab user IDs for round-robin assignment
  # Get IDs: curl -H "PRIVATE-TOKEN: $TOKEN" "https://gitlab.com/api/v4/users?username=david.gardiner"
  roster: |
    [
      {"username": "david.gardiner", "gitlab_id": 0},
      {"username": "team_member_2", "gitlab_id": 0},
      {"username": "team_member_3", "gitlab_id": 0},
      {"username": "team_member_4", "gitlab_id": 0}
    ]
```

### Assignment Counter ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: assignment-counter
  namespace: argo-events
  labels:
    app.kubernetes.io/part-of: k8s-event-triage
data:
  counter: "0"
```

### Workflow Logic (add to investigate-and-report step)

```bash
# --- Round-robin assignment ---
ROSTER_JSON=$(kubectl get configmap team-roster -n argo-events \
  -o jsonpath='{.data.roster}')
ROSTER_COUNT=$(echo "$ROSTER_JSON" | jq length)

if [ "$ROSTER_COUNT" -gt 0 ]; then
  # Get and increment counter atomically
  COUNTER=$(kubectl get configmap assignment-counter -n argo-events \
    -o jsonpath='{.data.counter}' 2>/dev/null || echo "0")
  NEXT=$(( (COUNTER + 1) % ROSTER_COUNT ))
  kubectl patch configmap assignment-counter -n argo-events \
    --type merge -p "{\"data\":{\"counter\":\"$NEXT\"}}"

  # Pick assignee
  ASSIGNEE_ID=$(echo "$ROSTER_JSON" | jq -r ".[$COUNTER].gitlab_id")
  ASSIGNEE_NAME=$(echo "$ROSTER_JSON" | jq -r ".[$COUNTER].username")
  echo "Assigned to: $ASSIGNEE_NAME (ID: $ASSIGNEE_ID)"
fi
```

Then in the GitLab issue creation payload, add:

```bash
jq -n \
  --arg title "$TITLE" \
  --arg description "$BODY" \
  --arg labels "$GL_LABELS" \
  --argjson assignee_ids "[$ASSIGNEE_ID]" \
  '{title: $title, description: $description, labels: $labels, assignee_ids: $assignee_ids}'
```

### Stand-up Visibility

At daily stand-ups, check the Kanban board:

- **How many Open issues?** — should trend toward zero
- **Who has issues in Triage?** — are they stuck?
- **Who has nothing assigned?** — call it out
- **How many in Skill Updated?** — this is the learning loop closing
- **False Positive rate** — if high, tune filters/dedup

---

## Phase 1: David Does the First Namespace (Day 1)

### Goal
Work through one namespace end-to-end, document everything, create GitLab tickets, prove the process works. This becomes the reference for the team.

### Pick the First Namespace

**Recommended: `cert-manager`** — already partially tested (3/5 pass on proxmox-k8s), well-understood failure modes, worker cluster namespace with no EventHub dependency.

### Steps

1. **Check existing events**
   ```bash
   # On the engineering cluster
   kubectl get events -n cert-manager --sort-by='.lastTimestamp'
   kubectl get events -n cert-manager --field-selector type=Warning
   ```

2. **Clean up stale events**
   ```bash
   # Events auto-expire (default 1h TTL), but check for recurring ones
   kubectl get events -n cert-manager -o custom-columns=\
     REASON:.reason,OBJECT:.involvedObject.name,COUNT:.count,LAST:.lastTimestamp \
     --sort-by='.count'
   ```

3. **Run KAgent triage on existing issues**
   ```bash
   curl -s -X POST "http://kagent-controller.kagent:8083/api/a2a/kagent/sre-triage-agent/" \
     -H "Content-Type: application/json" \
     -d '{
       "jsonrpc":"2.0",
       "id":"rollout-cert-manager-1",
       "method":"message/send",
       "params":{"message":{"role":"user","parts":[{
         "kind":"text",
         "text":"Investigate all Warning events in the cert-manager namespace. Check pod health, certificate status, and any recurring issues. Report findings with evidence."
       }]}}
     }' | jq '.result.artifacts[0].parts[0].text'
   ```

4. **Inject test faults** — see [Chaos Injection](#chaos-injection-framework) below

5. **For each fault:**
   - Record the event that fires
   - Record the KAgent analysis
   - Create a GitLab issue (manually for Phase 1, auto for Phase 2+)
   - Document in `TEST-RESULTS-2026-04-09.md`
   - Follow the full [Namespace Lifecycle](../../kagent-triage/NAMESPACE-LIFECYCLE.md)
   - **Close the learning loop:** update the agent skill so it can handle this next time

6. **Clean up after testing**
   ```bash
   kubectl get pods -n cert-manager
   kubectl get certificates --all-namespaces
   ```

---

## Phase 2: Engineering Team Rollout (Days 2-3)

### Prerequisites
- [ ] GitLab project created and configured (from checklist above)
- [ ] `team-roster` ConfigMap deployed with real GitLab user IDs
- [ ] `assignment-counter` ConfigMap created
- [ ] Workflow template updated with round-robin assignee logic
- [ ] `gitlab-token` secret updated with new project PAT
- [ ] Chaos injection manifests ready for all target namespaces
- [ ] David's Phase 1 documented and shared as the reference

### How It Runs

1. **Chaos injection hits a namespace** (scheduled or manual)
2. K8s Warning events fire
3. Pipeline triggers: Event → KAgent triage → GitLab issue created → assigned to next person in roster
4. Person gets notified, picks it up on the Kanban board
5. They investigate — the agent already triaged it, so they're validating + learning
6. **Key action:** update the agent skill/prompt so it can remediate this class of issue next time
7. Move the issue through: Open → Triage → Remediated → Skill Updated → Resolved

### What "Done" Looks Like for Each Issue

The issue is only **Resolved** when:
- [ ] The immediate problem is fixed (agent or human)
- [ ] The agent's skill/prompt is updated so it can handle this autonomously next time
- [ ] If a GitOps change is needed, it's documented in the issue (future: agent does this)

### Daily Standup Check

- How many **Open** issues? (should trend toward zero)
- Who has issues stuck in **Triage**?
- How many issues reached **Skill Updated**? (this is the real metric)
- False positive rate — tune if >20%
- Any namespace generating excessive noise?

---

## Chaos Injection Framework

### Purpose

Deliberately break namespaces to:
1. Validate the triage pipeline fires correctly
2. Test agent diagnosis quality
3. **Build the skill library** — each fault teaches the agent something new
4. Give the team hands-on exposure to the full workflow

### NOT the Goal (Yet)

The agent should NOT auto-remediate in this phase. The flow is:

```
Fault injected → Agent triages → GitLab issue created → Human reviews
  → Human fixes (or confirms agent's suggested fix)
  → Human updates agent skill so it CAN fix it next time
  → Next time this fault occurs → Agent remediates → Human just gets a notification:
      "Problem detected. Remediated automatically. Human action needed: [update GitOps / review config / none]"
```

### Chaos Manifests Per Namespace

Each namespace gets a set of fault injection manifests. Apply them to trigger events, then clean up.

#### cert-manager

```yaml
# chaos/cert-manager/01-bad-issuer.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: chaos-bad-issuer
  namespace: cert-manager
spec:
  secretName: chaos-bad-issuer-tls
  issuerRef:
    name: nonexistent-issuer
    kind: ClusterIssuer
  dnsNames:
    - chaos-test.example.com
---
# chaos/cert-manager/02-cainjector-oom.yaml
# Patch cainjector to trigger OOMKilled
# kubectl patch deployment cert-manager-cainjector -n cert-manager \
#   --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"10Mi"}]'
---
# chaos/cert-manager/03-webhook-down.yaml
# kubectl scale deployment cert-manager-webhook -n cert-manager --replicas=0
```

#### external-secrets

```yaml
# chaos/external-secrets/01-bad-secretstore.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: chaos-bad-store
  namespace: external-secrets
spec:
  provider:
    fake:
      data: []
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: chaos-missing-key
  namespace: external-secrets
spec:
  refreshInterval: 10s
  secretStoreRef:
    name: chaos-bad-store
    kind: SecretStore
  target:
    name: chaos-secret
  data:
    - secretKey: password
      remoteRef:
        key: nonexistent/key
```

#### kyverno

```yaml
# chaos/kyverno/01-webhook-timeout.yaml
# kubectl patch deployment kyverno-admission-controller -n kyverno \
#   --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"10Mi"}]'
---
# chaos/kyverno/02-policy-violation.yaml
# Deploy a pod that violates an existing policy
apiVersion: v1
kind: Pod
metadata:
  name: chaos-privileged-pod
  namespace: default
spec:
  containers:
    - name: test
      image: busybox
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

#### monitoring (kube-prometheus-stack)

```yaml
# chaos/monitoring/01-prometheus-oom.yaml
# kubectl patch statefulset prometheus-kube-prom-prometheus -n monitoring \
#   --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"50Mi"}]'
---
# chaos/monitoring/02-scrape-target-down.yaml
# kubectl scale deployment kube-prom-kube-state-metrics -n monitoring --replicas=0
```

#### Generic (works in any namespace)

```yaml
# chaos/generic/crashloop.yaml
apiVersion: v1
kind: Pod
metadata:
  name: chaos-crashloop
  # Apply with: kubectl apply -f - -n <TARGET_NAMESPACE>
spec:
  containers:
    - name: crash
      image: busybox
      command: ["sh", "-c", "exit 1"]
---
# chaos/generic/oom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: chaos-oom
spec:
  containers:
    - name: oom
      image: python:3.9-slim
      command: ["python3", "-c", "x = [' ' * 10**6 for _ in range(10**6)]"]
      resources:
        limits:
          memory: "32Mi"
---
# chaos/generic/imagepull.yaml
apiVersion: v1
kind: Pod
metadata:
  name: chaos-imagepull
spec:
  containers:
    - name: bad
      image: nonexistent-registry.example.com/fake/image:latest
```

### Chaos Runner Script

```bash
#!/bin/bash
# chaos/run-chaos.sh — Inject faults into a namespace and watch for pipeline response
#
# Usage: ./run-chaos.sh <namespace> <fault-dir>
#   e.g.: ./run-chaos.sh cert-manager chaos/cert-manager/

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <fault-dir>}"
FAULT_DIR="${2:?Usage: $0 <namespace> <fault-dir>}"

echo "=== Chaos Injection: $NAMESPACE ==="
echo "Fault dir: $FAULT_DIR"
echo ""

# Apply each fault manifest
for f in "$FAULT_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  echo "--- Injecting: $(basename $f) ---"
  kubectl apply -f "$f" -n "$NAMESPACE" 2>&1 || true
  echo ""
done

echo "=== Watching for events (30s) ==="
timeout 30 kubectl get events -n "$NAMESPACE" --watch 2>/dev/null || true

echo ""
echo "=== Check for triggered workflows ==="
kubectl get workflows -n argo-events --sort-by='.metadata.creationTimestamp' | tail -5

echo ""
echo "=== Check GitLab issues ==="
echo "Check the Kanban board for new issues assigned to the team."
echo ""
echo "To clean up:"
echo "  kubectl delete -f $FAULT_DIR -n $NAMESPACE"
```

### Cleanup Script

```bash
#!/bin/bash
# chaos/cleanup.sh — Remove all chaos artifacts from a namespace
#
# Usage: ./cleanup.sh <namespace> [fault-dir]

NAMESPACE="${1:?Usage: $0 <namespace> [fault-dir]}"
FAULT_DIR="${2:-}"

if [ -n "$FAULT_DIR" ]; then
  kubectl delete -f "$FAULT_DIR" -n "$NAMESPACE" --ignore-not-found
else
  # Clean up by label
  kubectl delete pods -n "$NAMESPACE" -l chaos=true --ignore-not-found
  kubectl delete certificates -n "$NAMESPACE" -l chaos=true --ignore-not-found 2>/dev/null || true
  kubectl delete externalsecrets -n "$NAMESPACE" -l chaos=true --ignore-not-found 2>/dev/null || true
fi

echo "Cleaned up chaos artifacts in $NAMESPACE"
echo "Verify:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get events -n $NAMESPACE --field-selector type=Warning"
```

---

## The Learning Loop

This is the most important part. The goal isn't just to detect problems — it's to make the agents smarter over time.

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ 1. FAULT     │────▶│ 2. AGENT     │────▶│ 3. HUMAN     │────▶│ 4. SKILL     │
│              │     │    TRIAGES   │     │    REVIEWS   │     │    UPDATED   │
│ Event fires  │     │ Creates      │     │ Validates    │     │ Agent can    │
│ (real or     │     │ GitLab issue │     │ diagnosis    │     │ handle this  │
│  injected)   │     │ with triage  │     │ Fixes if     │     │ next time    │
│              │     │ + suggested  │     │ needed       │     │              │
│              │     │ remediation  │     │              │     │              │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                                                                      │
                                                                      ▼
                                                              ┌──────────────┐
                                                              │ 5. NEXT TIME │
                                                              │              │
                                                              │ Agent auto-  │
                                                              │ remediates   │
                                                              │ Notification:│
                                                              │ "Fixed. Human│
                                                              │  action: X"  │
                                                              └──────────────┘
```

### What "Skill Updated" Means

When closing an issue as **Skill Updated**, the team member must have done ONE of:

1. **Updated the agent's system prompt** — added a new remediation rule or diagnostic step
2. **Created/updated a skill script** — a bash/python script the agent can execute via BashTool
3. **Updated a runbook** — new troubleshooting steps the agent references
4. **Noted it as a GitOps action** — "next time, the agent should update repo X" (future phase)

### GitLab Issue Template for Triage

```markdown
## Event Details
| Field | Value |
|-------|-------|
| **Cluster** | {cluster} |
| **Namespace** | {namespace} |
| **Reason** | {reason} |
| **Resource** | {kind}/{name} |

## Agent Triage
{agent analysis}

## Suggested Remediation
{agent's suggested fix}

## Human Action Required
- [ ] Validate the agent's diagnosis
- [ ] Apply fix (if agent didn't auto-remediate)
- [ ] Update agent skill/prompt so it can handle this next time
- [ ] If GitOps change needed, document what and where

## Skill Update
<!-- Fill this in before moving to "Skill Updated" -->
- What was updated:
- File/CRD changed:
- How the agent will handle this next time:
```

---

## Future: GitOps Agents (Phase 4)

> Not in scope now. Bake this in later.

Once agents can reliably triage and suggest fixes, the next step is agents that can:

1. Clone a GitOps repo
2. Make the necessary change (update a Helm value, fix a Kustomize patch, update a ConfigMap)
3. Create a PR/MR
4. Notify the human: "I've created MR #123 to fix this. Please review."

This turns the notification from "here's what you need to do" into "here's what I've done, please approve."

---

## Phase 3: SRE Handoff (After Engineering Validation)

### Prerequisites
- [ ] All core namespaces have been through the chaos + learning loop
- [ ] False-positive rate acceptable (<20%)
- [ ] Agent skill library covers common failure modes
- [ ] GitLab Kanban board populated with resolved issues as reference
- [ ] Runbooks created for top 5 recurring issues

### What SRE Gets

1. **Kanban board** with triage issues auto-assigned on round-robin rotation
2. **Documented process** — this doc + Namespace Lifecycle + David's Phase 1 reference
3. **Agent routing** — specialist agents per namespace already configured
4. **Skill library** — agents can auto-remediate known issues
5. **Escalation path** — issues the agent can't resolve get labelled `needs-human`

### Outstanding for Phase 3

- [ ] **Management cluster in dev** — needed for EventHub-dependent namespaces
- [ ] **New GitLab board** — separate from engineering, SRE-owned
- [ ] **On-call integration** — link GitLab issues to on-call rotation
- [ ] **SLA definition** — how fast must triage issues be acknowledged?
- [ ] **Chase up moving into dev area** — needs management cluster + GitLab board

---

## Worker Cluster Namespaces — No EventHub Dependency

These namespaces can be triaged entirely on the worker cluster:

| Namespace | Why No EventHub Needed |
|-----------|----------------------|
| cert-manager | Local CRDs, no external deps |
| external-secrets | Local SecretStore + ExternalSecret CRDs |
| kro | Local ResourceGroup CRDs |
| kyverno | Local policies |
| reloader | Local ConfigMap/Secret watching |
| monitoring | Local Prometheus stack |
| ingress-nginx | Local ingress controller |

**How it works:** KAgent on the worker cluster has direct access via its service account. Events generated locally, triage runs locally, GitLab issues created via outbound HTTPS.

**What still needs EventHub:** Application namespaces where events flow through Alloy → EventHub → management cluster → Argo Events → workflow.

---

## Quick Reference: Key Files

| What | Where |
|------|-------|
| Workflow template (critical) | `eventhub-otlp-pipeline/tier-critical/workflow-template.yaml` |
| Agent routing ConfigMap | `eventhub-otlp-pipeline/tier-critical/agent-routing.yaml` |
| Namespace lifecycle process | `kagent-triage/NAMESPACE-LIFECYCLE.md` |
| Chaos injection manifests | `chaos/` (to be created) |
| Production readiness | `PRODUCTION-READINESS.md` |
| Phased rollout (infra) | `PHASED-ROLLOUT.md` |
| Test results template | `kagent-triage/TEST-RESULTS-*.md` |
| GitLab issue templates | `working-config/gitlab-issues/` |
