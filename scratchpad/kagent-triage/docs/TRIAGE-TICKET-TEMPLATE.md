# [Triage] {NAMESPACE} — K8s Event Triage

**Labels:** `kagent`, `auto-generated`, `triage`, `{NAMESPACE}`
**Assignee:** _{assigned via round-robin}_
**Milestone:** Engineering Rollout

> **How to use this template:**
> Replace every `{NAMESPACE}` with the actual namespace (e.g. `cert-manager`).
> Replace `{CLUSTER}` with the target cluster (e.g. `proxmox-k8s`).
> Work through Steps 1–3 in order. Fill in the results tables as you go.
> Don't close this ticket until the Done Checklist is complete.

---

## Context

| Field | Value |
|-------|-------|
| **Namespace** | `{NAMESPACE}` |
| **Cluster** | `{CLUSTER}` |
| **Auto-triage run** | _{link to Argo workflow run, or "not yet triggered"}_ |
| **Agent diagnosis** | _(paste KAgent output below, or "see workflow logs")_ |

<details>
<summary>Agent triage output (paste here)</summary>

```
{paste KAgent output from the Argo workflow logs}
```

</details>

---

## Step 1: Survey and Clean Up

Get a clear picture of the namespace before touching anything.

```bash
# What's running?
kubectl get all -n {NAMESPACE}

# What events are firing?
kubectl get events -n {NAMESPACE} --sort-by='.lastTimestamp'
kubectl get events -n {NAMESPACE} --field-selector type=Warning

# Resource health
kubectl top pods -n {NAMESPACE} 2>/dev/null || true
```

Work through what you find. Fix anything that's a genuine existing issue before injecting test faults.

| # | Issue Found | Action Taken | Resolved? |
|---|-------------|--------------|-----------|
| 1 | | | |
| 2 | | | |
| 3 | | | |

```bash
# Confirm clean after fixes
kubectl get events -n {NAMESPACE} --field-selector type=Warning
# → should be empty or only known noise
```

- [ ] Existing issues resolved (or noted as known/acceptable)
- [ ] Namespace is in a known-good state before fault injection

---

## Step 2: Inject Faults — Let the Agent Work

Inject realistic faults for this namespace. The pipeline should fire automatically: event → KAgent triage → GitLab issue created. Your job here is to watch, not to fix — let the agent attempt remediation first.

### 2a. Generic pipeline smoke test (run this first)

```bash
kubectl apply -n {NAMESPACE} -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: triage-test-crashloop
  labels:
    chaos: "true"
    purpose: triage-test
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

Watch for the pipeline to fire:

```bash
# Terminal 1 — watch for events
kubectl get events -n {NAMESPACE} --watch --field-selector reason=BackOff

# Terminal 2 — watch for workflow triggering
kubectl get workflows -n argo-events --watch
```

- [ ] CrashLoopBackOff event fired
- [ ] Argo workflow triggered
- [ ] KAgent triage ran
- [ ] GitLab issue created (link: _______________)

```bash
# Clean up smoke test pod
kubectl delete pod triage-test-crashloop -n {NAMESPACE} --ignore-not-found
```

### 2b. Namespace-specific faults

Pick 2–3 faults realistic for `{NAMESPACE}`. Use the catalogue from [`ENGINEERING-ROLLOUT.md`](../../../k8s-event-triage/ENGINEERING-ROLLOUT.md#chaos-injection-framework), or write your own in `chaos/{NAMESPACE}/`.

For each fault injected:

```bash
# Inject
kubectl apply -f chaos/{NAMESPACE}/0X-fault.yaml -n {NAMESPACE}
# (or: kubectl patch deployment {name} -n {NAMESPACE} --type=json -p='[...]')

# Wait for pipeline (~30–60s)
kubectl get workflows -n argo-events --watch
```

Record what happened:

| # | Fault Injected | Event Reason | Agent Diagnosis Correct? | Agent Remediation Attempted? | Outcome |
|---|---------------|--------------|-------------------------|------------------------------|---------|
| 1 | | | Yes / No / Partial | Yes / No | Fixed / Still broken / FP |
| 2 | | | Yes / No / Partial | Yes / No | Fixed / Still broken / FP |
| 3 | | | Yes / No / Partial | Yes / No | Fixed / Still broken / FP |

- [ ] All faults injected and pipeline triggered for each
- [ ] Results recorded above

---

## Step 3: Human Verification

For each fault where the agent attempted remediation, go in and confirm it actually worked.

```bash
# Verify the fix held
kubectl get pods -n {NAMESPACE}
kubectl get events -n {NAMESPACE} --field-selector type=Warning

# For any namespace-specific resources (adapt as needed):
kubectl get {crds-if-relevant} -n {NAMESPACE}
kubectl describe {problematic-resource} -n {NAMESPACE}
```

For each fault:

| # | Fault | Agent Said It Fixed | Human Verified? | Actually Fixed? | Notes |
|---|-------|---------------------|-----------------|-----------------|-------|
| 1 | | Yes / No | Yes / No | Yes / No / Partial | |
| 2 | | Yes / No | Yes / No | Yes / No / Partial | |
| 3 | | Yes / No | Yes / No | Yes / No / Partial | |

### If something is still broken

Fix it manually and note what the agent missed:

```bash
# Manual fix (adapt):
kubectl rollout restart deployment {name} -n {NAMESPACE}
kubectl patch {resource} -n {NAMESPACE} --type merge -p '{...}'
kubectl delete pod {stuck-pod} -n {NAMESPACE}
```

Document the gap — this feeds into the skill update below.

---

## Step 4: Clean Up

Remove all chaos artifacts before closing.

```bash
# Remove chaos pods/resources by label
kubectl delete pods -n {NAMESPACE} -l chaos=true --ignore-not-found

# Remove any named fault manifests
kubectl delete -f chaos/{NAMESPACE}/ -n {NAMESPACE} --ignore-not-found 2>/dev/null || true

# Undo any patches (if applicable)
# kubectl rollout undo deployment {name} -n {NAMESPACE}

# Final health check
kubectl get pods -n {NAMESPACE}
kubectl get events -n {NAMESPACE} --field-selector type=Warning
```

- [ ] All chaos artifacts removed
- [ ] Namespace healthy and clean

---

## Step 5: Close the Learning Loop

This is the step most people skip. Don't. The whole point of this process is to make the agent better so the next person gets a ticket with less work to do.

If the agent got everything right: note it. The skill is good as-is.

If the agent missed something or gave a wrong/incomplete diagnosis, update it:

### Option A — Update the agent system prompt

```bash
kubectl edit agent sre-triage-agent -n kagent
# Add to systemMessage:
# "When investigating {NAMESPACE}, always check: ..."
# "Common failure modes in {NAMESPACE}: ..."
```

### Option B — Commit a new skill

Create `kagent-triage/worker-cluster-bundle/skills/{NAMESPACE}-diagnostics/SKILL.md`
See [SKILLS-AND-REMEDIATION.md](../../../kagent-triage/worker-cluster-bundle/SKILLS-AND-REMEDIATION.md) for format.

### Option C — Nothing needed

Agent performed well. Note it so the next person knows the baseline is solid.

Fill this in before moving the issue to **Skill Updated**:

| What Changed | Before | After | Why |
|-------------|--------|-------|-----|
| | | | |

- [ ] Skill/prompt updated (or confirmed no update needed)
- [ ] Changes committed to repo (if applicable)

---

## Done Checklist

- [ ] Namespace surveyed and existing issues cleaned up (Step 1)
- [ ] Smoke test passed — pipeline fires end-to-end (Step 2a)
- [ ] 2+ namespace-specific faults injected and results recorded (Step 2b)
- [ ] Each agent fix verified by a human (Step 3)
- [ ] All chaos artifacts removed, namespace healthy (Step 4)
- [ ] Learning loop closed — skill updated or baseline confirmed (Step 5)
- [ ] This ticket updated with all findings

### Move the issue through the board:

```
Open  →  Triage  →  Remediated  →  Skill Updated  →  Resolved
```

Only close (**Resolved**) once **Skill Updated** is done.

---

## To create this ticket for a new namespace

1. Copy this file
2. Replace all `{NAMESPACE}` → actual namespace name
3. Replace `{CLUSTER}` → target cluster
4. Assign to the next person in the round-robin roster
5. Add labels: `kagent`, `auto-generated`, `triage`, `{namespace-name}`
6. Link to this template in the issue description so the assignee has the guide
