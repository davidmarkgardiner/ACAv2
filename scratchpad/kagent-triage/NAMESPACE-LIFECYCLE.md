# Namespace Agent Lifecycle

> The repeatable process for onboarding any namespace into the kagent triage pipeline.
> Every namespace follows the same 6-step cycle. No shortcuts.

## The Cycle

```
┌─────────┐    ┌──────┐    ┌───────┐    ┌──────────┐    ┌────────────┐    ┌───────┐
│ 1. WORK │───▶│2.TEST│───▶│3.PROVE│───▶│4.DOCUMENT│───▶│5.GITLAB    │───▶│6.LEARN│
│ Build   │    │Inject│    │Verify │    │Results + │    │Issue with  │    │Update │
│ agent   │    │faults│    │output │    │evidence  │    │evidence    │    │skill  │
└─────────┘    └──────┘    └───────┘    └──────────┘    └────────────┘    └───────┘
```

---

## Step 1: WORK — Build the Agent

```bash
cd ~/repos/argo-workflow/kagent-triage

# Use the skill script to generate manifests
~/clawd/skills/kagent-namespace-agent/scripts/create-agent.sh \
  --namespace <NAMESPACE> \
  --description "<what this namespace does, failure modes, key commands>" \
  --output-dir . \
  --deploy
```

**Outputs:**
- `<namespace>-agent.yaml` — kagent Agent CR
- `<namespace>-sensor.yaml` — Argo Sensor CR
- `<namespace>-test-error.yaml` — Generic test errors
- `<namespace>-fault-injection.yaml` — Domain-specific faults (create manually)

**Verify:**
```bash
kubectl get agent <namespace>-agent -n kagent -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Must return: True
```

---

## Step 2: TEST — Inject Faults

Create domain-specific fault injection (not just generic CrashLoop):

| Namespace | Example Faults |
|-----------|---------------|
| cert-manager | Bad issuer ref, expired cert, webhook scale-to-0, cainjector OOM |
| external-dns | Wrong provider creds, missing RBAC, conflicting records |
| ingress-nginx | Bad config snippet, missing backend, TLS secret missing |
| monitoring | Prometheus OOM, scrape target down, storage full |

```bash
# Apply fault injection
kubectl apply -f <namespace>-fault-injection.yaml

# Watch for events
kubectl get events -n <namespace> --watch

# Watch for workflows (if sensor triggers on Warning events)
kubectl get workflows -n argo-events --watch
```

**If events are `type: Normal` (like cert-manager):** Test via direct A2A call instead:
```bash
curl -s -X POST "http://kagent-controller.kagent:8083/api/a2a/kagent/<namespace>-agent/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"test-1","method":"message/send","params":{"message":{"role":"user","parts":[{"text":"Diagnose issues in the <namespace> namespace"}]}}}'
```

---

## Step 3: PROVE — Verify Output Quality

Check the agent's diagnostic report against these criteria:

- [ ] **Identified the correct resource(s)** — not guessing
- [ ] **Used kubectl/tools** — actually inspected the cluster, not just parroting the prompt
- [ ] **Root cause identified** — not just symptoms
- [ ] **Remediation provided** — actionable commands, not vague advice
- [ ] **Risk assessment** — severity, blast radius
- [ ] **Verification steps** — how to confirm the fix worked

Save the raw output:
```bash
# For workflow-triggered tests
kubectl logs -n argo-events <workflow-pod> -c main | tee results/<namespace>-test-<N>.txt

# For direct A2A tests
curl ... | jq '.result.artifacts[0].parts[0].text' | tee results/<namespace>-test-<N>.txt
```

---

## Step 4: DOCUMENT — Write Test Results

Create/append to `TEST-RESULTS-<date>.md`:

```markdown
## Test N: <namespace> — <fault type>

**Fault injected:** <what was broken>
**Trigger:** <auto-sensor | manual A2A>
**Result:** ✅ PASS / ❌ FAIL

### Agent Output (excerpt)
<paste key findings>

### Quality Assessment
- [x] Correct resource identified
- [x] Used cluster inspection tools
- [x] Root cause found
- [ ] Remediation actionable ← if missing, note what's needed

### Gaps / Improvements
- <anything the agent missed or got wrong>
```

---

## Step 5: GITLAB ISSUE — Create the Ticket

Use the template from `aks-mgmt-stack/k8s-event-triage/working-config/gitlab-issues/13-kagent-onboarding-template.md`.

Each namespace gets its own issue with:
- Component overview + failure modes table
- 5 fault injection test scenarios with results
- Phase tracking: Research → Build → Test → SRE Review → Fine-tune → Integrate
- Evidence from Step 4 attached

**File location:** `working-config/gitlab-issues/<N>-kagent-<namespace>.md`

```bash
# Copy and customise the template
cp working-config/gitlab-issues/13-kagent-onboarding-template.md \
   working-config/gitlab-issues/<N>-kagent-<namespace>.md
```

---

## Step 6: LEARN — Update the Skill

After each namespace, capture what we learned:

1. **Update GOTCHAS.md** — any new traps (e.g. "cert-manager uses Normal events not Warning")
2. **Update the skill templates** — if we found a pattern that should be default
3. **Update ADDING-NAMESPACE-AGENTS.md** — if the process changed
4. **Commit everything** — manifests, results, issues, learnings

```bash
cd ~/repos/argo-workflow
git add kagent-triage/ aks-mgmt-stack/
git commit -m "feat(kagent): <namespace> agent — tested and documented"
git push origin main-clean
```

---

## Completed Namespaces

| # | Namespace | Agent | Sensor | Faults Tested | Results | GitLab Issue | Date |
|---|-----------|-------|--------|---------------|---------|--------------|------|
| 1 | test-ns | ✅ | ✅ auto | CrashLoop, ImagePull, OOM | 4/5 pass | — | 2026-03-13 |
| 2 | cert-manager | ✅ | ✅ (Normal events) | IssuerNotFound (x2), OOMKilled cainjector | 3/5 pass | Pending | 2026-03-13, 2026-03-16 |
| 3 | external-secrets | ✅ | ✅ auto | SecretStore not found | 7/7 pass | — | 2026-03-16 |
| 4 | kro | ✅ | ✅ auto | CrashLoopBackOff | 7/7 pass | — | 2026-03-16 |
| 5 | kyverno | ✅ | ✅ auto | Webhook timeout, policy violations | 7/7 pass | — | 2026-03-16 |
| 6 | reloader | ✅ | ✅ auto | CrashLoopBackOff, missing resource limits | 7/7 pass | — | 2026-03-16 |

**Dropped:**
- external-dns — not on Kind cluster, will test on AKS
- ingress-nginx — replaced by AKS Istio addon at work

---

## Phase 2 Backlog (AKS cluster)

- flux-system
- aks-istio-ingress
- gateway (Gateway API)

## Other Backlog

- monitoring (kube-prometheus-stack)
- storage (Longhorn / local-path)
- workload (generic app namespaces)
- network (CNI, kube-proxy, NetworkPolicy)
