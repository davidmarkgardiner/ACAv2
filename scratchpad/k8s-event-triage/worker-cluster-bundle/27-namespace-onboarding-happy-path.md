# GitLab Issue: Namespace Onboarding — Happy Path

**Title:** `[Onboarding] {NAMESPACE} — End-to-End Triage Pipeline Validation`

**Labels:** `onboarding`, `kagent`, `{NAMESPACE}`

**Assignee:** _{one person owns the onboarding for this namespace}_

---

## Overview

This ticket walks through onboarding a single namespace into the K8s event triage pipeline. Follow each step in order. Don't skip ahead — the goal is to prove the pipeline works, improve the agent, and leave the namespace ready to run unattended.

When this ticket is done, the namespace is "live" — events trigger the pipeline, the agent triages (and ideally remediates), and GitLab tickets go out to the team on rotation.

---

## Step 1: Pick Your Namespace

- **Namespace:** `{NAMESPACE}`
- **Cluster:** `{CLUSTER}`
- **Worker or Management:** _{worker namespaces triage locally, no EventHub needed}_

Familiarise yourself with what runs here:

```bash
kubectl get all -n {NAMESPACE}
kubectl get events -n {NAMESPACE} --sort-by='.lastTimestamp'
kubectl top pods -n {NAMESPACE}
```

Document what you find:

- [ ] What pods/deployments/statefulsets run here?
- [ ] What CRDs does this namespace use (if any)?
- [ ] What are the common failure modes? (check docs, past incidents, team knowledge)

---

## Step 2: KAgent Sweep — What's Already Broken?

Ask the agent to look at everything in the namespace right now:

```bash
curl -s -X POST "http://kagent-controller.kagent:8083/api/a2a/kagent/sre-triage-agent/" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":"onboarding-{NAMESPACE}-sweep",
    "method":"message/send",
    "params":{"message":{"role":"user","parts":[{
      "kind":"text",
      "text":"Investigate the {NAMESPACE} namespace thoroughly. Check all pod health, recent events, resource usage, and any Warning or Error conditions. CRITICAL: use exact namespace \"{NAMESPACE}\". Report everything you find."
    }]}}
  }' | jq -r '.result.artifacts[0].parts[0].text'
```

Save the output:

```bash
# Save to file for the record
curl ... | jq -r '.result.artifacts[0].parts[0].text' > results/{NAMESPACE}-initial-sweep.txt
```

- [ ] Record the agent's findings below
- [ ] Note anything the agent missed or got wrong

<details>
<summary>Agent sweep results (paste here)</summary>

```
{paste agent output}
```

</details>

---

## Step 3: Clean Up — Fix What You Can

Work through the agent's findings. Fix anything that's a real issue:

```bash
# Example fixes — adapt to what you found
kubectl delete pod {stuck-pod} -n {NAMESPACE}              # Restart stuck pod
kubectl rollout restart deployment {name} -n {NAMESPACE}   # Restart deployment
kubectl patch {resource} -n {NAMESPACE} ...                # Fix misconfiguration
```

For each fix:

| # | Issue Found | Action Taken | Resolved? |
|---|------------|--------------|-----------|
| 1 | | | |
| 2 | | | |
| 3 | | | |

- [ ] All fixable issues resolved
- [ ] Re-run the sweep to confirm clean state:
  ```bash
  kubectl get events -n {NAMESPACE} --field-selector type=Warning
  # Should be empty or minimal
  ```

---

## Step 4: Turn On the Pipeline

Ensure this namespace's events will flow through the triage pipeline.

**For worker cluster namespaces** (no EventHub):

- [ ] Verify KAgent is running and the agent can reach this namespace:
  ```bash
  kubectl auth can-i get pods -n {NAMESPACE} --as=system:serviceaccount:kagent:kagent
  ```
- [ ] Verify the sensor/eventsource is watching this namespace (or it's covered by the default sensor)
- [ ] Check agent routing — does this namespace have a specialist agent, or does it use the default?
  ```bash
  kubectl get configmap agent-routing -n argo-events -o yaml
  ```

**For EventHub namespaces** (management cluster pipeline):

- [ ] Verify Alloy is collecting events from this namespace
- [ ] Verify the EventSource consumer group is active
- [ ] Verify the sensor trigger conditions match events from this namespace

**Test the pipeline with a dry run:**

```bash
# Inject a harmless test event (generic crashloop pod)
kubectl apply -n {NAMESPACE} -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: onboarding-test-crashloop
  labels:
    chaos: "true"
    purpose: onboarding-test
spec:
  containers:
    - name: crash
      image: busybox
      command: ["sh", "-c", "exit 1"]
      resources:
        limits:
          memory: "32Mi"
          cpu: "50m"
EOF
```

- [ ] Event fires (check `kubectl get events -n {NAMESPACE} --watch`)
- [ ] Workflow triggers (check `kubectl get workflows -n argo-events --watch`)
- [ ] KAgent analysis runs
- [ ] GitLab issue created
- [ ] Clean up: `kubectl delete pod onboarding-test-crashloop -n {NAMESPACE}`

---

## Step 5: Inject Real Faults

Now inject faults that are realistic for this namespace. Pick 3-5 from the table below (or create your own based on what you learned in Step 1).

### Fault Catalogue

Adapt these to your namespace. Not all will apply.

| # | Fault Type | How to Inject | What to Watch For |
|---|-----------|---------------|-------------------|
| 1 | **CrashLoopBackOff** | Bad env var or command | Agent identifies the bad config |
| 2 | **OOMKilled** | Set memory limit to 10Mi | Agent spots OOM, suggests resource increase |
| 3 | **ImagePullBackOff** | Change image to `nonexistent:latest` | Agent identifies bad image ref |
| 4 | **FailedMount** | Reference non-existent secret/configmap in a volume | Agent finds missing volume source |
| 5 | **Namespace-specific** | _(depends on what runs here — bad CRD ref, missing RBAC, webhook down, etc.)_ | Agent understands the domain |

### Run Each Fault

For each fault:

```bash
# 1. Inject
kubectl apply -f chaos/{NAMESPACE}/0X-fault-name.yaml -n {NAMESPACE}
# Or: kubectl patch deployment X -n {NAMESPACE} --type=json -p='[...]'

# 2. Watch for events
kubectl get events -n {NAMESPACE} --watch

# 3. Wait for pipeline (workflow + GitLab issue)
kubectl get workflows -n argo-events --watch

# 4. Check the GitLab issue that was created
# → Was the diagnosis correct?
# → Was the suggested remediation actionable?
```

Record results:

| # | Fault | Agent Diagnosis Correct? | Remediation Suggested? | Actionable? | Notes |
|---|-------|-------------------------|----------------------|-------------|-------|
| 1 | | Yes/No | Yes/No | Yes/No | |
| 2 | | Yes/No | Yes/No | Yes/No | |
| 3 | | Yes/No | Yes/No | Yes/No | |

- [ ] All faults injected and results recorded

---

## Step 6: Confirm Issues Persist (If They Should)

For faults you haven't cleaned up yet, verify the problem is still there:

```bash
kubectl get pods -n {NAMESPACE} | grep -E 'CrashLoop|Error|OOM|ImagePull'
kubectl get events -n {NAMESPACE} --field-selector type=Warning
```

- [ ] Confirmed: injected faults are still producing events
- [ ] This is the baseline the agent needs to improve against

---

## Step 7: Update the Agent

This is the key step. Based on what the agent got wrong or missed in Step 5, improve it.

**Options (pick what fits):**

### A. Update the agent's system prompt

If the agent missed domain-specific context (e.g. didn't know what a Certificate CRD is):

```bash
# Edit the agent CRD
kubectl edit agent sre-triage-agent -n kagent
# Or: kubectl edit agent {NAMESPACE}-agent -n kagent

# Add to systemMessage, e.g.:
# "When investigating {NAMESPACE}, check {specific CRDs/resources}."
# "Common failure modes in {NAMESPACE}: {list them}."
```

### B. Create or update a skill

If the agent needs a new diagnostic or remediation script:

```
skills/{NAMESPACE}-diagnostics/
├── SKILL.md
└── scripts/
    └── diagnose.sh    # or diagnose.py
```

See [SKILLS-AND-REMEDIATION.md](../../../kagent-triage/worker-cluster-bundle/SKILLS-AND-REMEDIATION.md) for skill format.

### C. Update the agent routing

If this namespace should have a specialist agent instead of the default:

```bash
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"'{NAMESPACE}'\": \"'{NAMESPACE}'-agent\"}"}}'
```

Document what you changed:

| What Changed | Before | After | Why |
|-------------|--------|-------|-----|
| | | | |

- [ ] Agent updated

---

## Step 8: Re-run — Prove the Agent Improved

Re-inject the same faults from Step 5. The agent should do better this time.

```bash
# Re-inject the faults that the agent struggled with
kubectl apply -f chaos/{NAMESPACE}/0X-fault-name.yaml -n {NAMESPACE}

# Watch the pipeline run again
kubectl get workflows -n argo-events --watch
```

Compare before and after:

| # | Fault | Round 1 Result | Round 2 Result | Improved? |
|---|-------|---------------|---------------|-----------|
| 1 | | | | Yes/No |
| 2 | | | | Yes/No |
| 3 | | | | Yes/No |

- [ ] Agent performance improved on at least the faults it missed in Round 1
- [ ] If still failing: iterate (go back to Step 7, update again, re-test)

---

## Step 9: Clean Up and Go Live

```bash
# Remove all chaos artifacts
kubectl delete pods -n {NAMESPACE} -l chaos=true --ignore-not-found
kubectl delete -f chaos/{NAMESPACE}/ -n {NAMESPACE} --ignore-not-found 2>/dev/null || true

# Undo any resource patches
kubectl rollout undo deployment {patched-deployment} -n {NAMESPACE}  # if applicable

# Verify clean
kubectl get pods -n {NAMESPACE}
kubectl get events -n {NAMESPACE} --field-selector type=Warning
```

- [ ] All chaos artifacts removed
- [ ] Namespace is healthy
- [ ] Pipeline is active — any future real events will trigger triage + GitLab issue

---

## Done Checklist

- [ ] Namespace surveyed (Step 1-2)
- [ ] Existing issues cleaned up (Step 3)
- [ ] Pipeline verified working (Step 4)
- [ ] 3+ faults injected and tested (Step 5)
- [ ] Agent improved based on results (Step 7)
- [ ] Improvement verified with re-test (Step 8)
- [ ] Namespace clean and live (Step 9)
- [ ] This ticket updated with all results and findings
- [ ] Any new skills/prompts committed to the repo

### Handoff

This namespace is now live. From here:

- Triage GitLab tickets will be assigned **round-robin across the whole team**
- Anyone might get a ticket for this namespace — the onboarding notes above are the reference
- If the agent can't handle something new, repeat Steps 7-8 (update skill → re-test)

---

## Template Usage

To create this ticket for a new namespace:

1. Copy this template
2. Replace all `{NAMESPACE}` with the actual namespace name
3. Replace `{CLUSTER}` with the target cluster
4. Assign to the person doing the onboarding
5. Create in the GitLab triage project with labels: `onboarding`, `kagent`, `{namespace-name}`
