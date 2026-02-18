# Holmes vs KAgent — Comparison Test Scenarios

> **Result: KAgent 5 – Holmes 0** (after prompt tuning)
> Date: 2026-02-17 | Cluster: proxmox-k8s | Model: Qwen 14B (RTX 3060)

---

## Executive Summary — Why KAgent Wins

We ran 5 real-world incident scenarios against both HolmesGPT and KAgent on the same cluster, same model, same alert data. KAgent won all 5 after two small prompt fixes.

### The core advantages

| Advantage | Detail |
|-----------|--------|
| **Native Kubernetes tools** | KAgent calls the K8s API directly (`k8s_describe_resource`, `k8s_get_pod_logs`). Holmes shells out via `call_kubectl` through AKS-MCP, which breaks on subshell syntax — this caused Holmes to misdiagnose Scenario 1 entirely. |
| **Native Helm tools** | KAgent has `helm_list_releases` and `helm_get_release`. Holmes has no Helm support — in Scenario 4 it couldn't inspect release values and used a literal `<pod-name>` placeholder instead of the actual pod name. |
| **Connectivity testing** | `k8s_check_service_connectivity` lets KAgent test cross-namespace dependencies live. Holmes can only describe pods. In Scenario 5, Holmes found the evidence in its tool output but ignored it. |
| **Focused output** | KAgent follows a structured Issue/Evidence/Root Cause/Fix format and stays on-topic. Holmes reported on unrelated pods in Scenarios 3 and 5, diluting the signal. |
| **Token-efficient** | Each KAgent agent loads only the tools it needs (via `toolNames`). Holmes loads every tool on every call — more tokens, more cost, no benefit. |
| **Composable agents** | Separate triage (readonly) and remediation (readwrite) agents with different RBAC. Holmes uses one agent for both — no safety boundary. |
| **Extensible architecture** | KAgent agents are CRDs — version them in Git, deploy per-team (BYOA), route by namespace. Holmes is a monolith with a single config for all alerts. |

### Where Holmes still has merit

- **Simpler deployment** — single Helm release vs KAgent's controller + tool-server + agents
- **Proven in production** — part of the Robusta ecosystem, more battle-tested
- **Single API call** — `/api/investigate` is purpose-built and easy to integrate

### Recommendation

**Use KAgent** as the primary triage/remediation platform. The composable agent model, native K8s/Helm tools, and BYOA architecture make it the better foundation for scaling to 1000+ namespaces across shared AKS clusters. Holmes can remain as a lightweight fallback for teams that don't need custom agents.

See [BYOA Agent Platform Proposal](BYOA-AGENT-PLATFORM-PROPOSAL.md) for the full routing and self-service architecture.

---

## Test Methodology

Run the same scenarios against both backends and compare quality, speed, and accuracy.

## Prerequisites

```bash
# Deploy both workflow templates
kubectl apply -f holmes-remediation.yaml
kubectl apply -f kagent-sre-workflow.yaml

# Verify both backends are healthy
# Holmes:
kubectl run --rm -it test-holmes --image=curlimages/curl --restart=Never -n argo -- \
  curl -s http://holmes-holmes.holmesgpt.svc:80/healthz

# KAgent:
kubectl run --rm -it test-kagent --image=curlimages/curl --restart=Never -n argo -- \
  curl -s http://kagent-controller.kagent.svc:8083/api/agents
```

---

## Scenario 1: ImagePullBackOff (Bad Image Tag)

**Setup:**
```bash
kubectl create namespace triage-test 2>/dev/null || true
kubectl create deployment web-broken --image=nginx:doesnotexist -n triage-test
sleep 10  # wait for BackOff
```

**Holmes — Triage only:**
```bash
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Investigate why web-broken deployment is failing in triage-test namespace" \
  -p event_type="ImagePullBackOff" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="web-broken" \
  -p severity="high" \
  -p error_message="Back-off pulling image nginx:doesnotexist" \
  -p remediate="false" \
  --watch
```

**KAgent — Triage only:**
```bash
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Investigate why web-broken deployment is failing in triage-test namespace" \
  -p event_type="ImagePullBackOff" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="web-broken" \
  -p severity="high" \
  -p error_message="Back-off pulling image nginx:doesnotexist" \
  -p remediate="false" \
  --watch
```

**What to compare:**
- Did it identify the bad image tag?
- Did it suggest the correct fix (`nginx:stable` or `nginx:latest`)?
- How many tool calls were needed?
- How long did it take?

**Holmes — Remediation:**
```bash
# Reset the broken deployment first
kubectl delete deployment web-broken -n triage-test 2>/dev/null
kubectl create deployment web-broken --image=nginx:doesnotexist -n triage-test
sleep 10

argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Fix the web-broken deployment — it has a bad image tag" \
  -p event_type="ImagePullBackOff" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="web-broken" \
  -p severity="high" \
  -p remediate="true" \
  --watch
```

**KAgent — Remediation:**
```bash
kubectl delete deployment web-broken -n triage-test 2>/dev/null
kubectl create deployment web-broken --image=nginx:doesnotexist -n triage-test
sleep 10

argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Fix the web-broken deployment — it has a bad image tag" \
  -p event_type="ImagePullBackOff" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="web-broken" \
  -p severity="high" \
  -p remediate="true" \
  --watch
```

**What to compare:**
- Did it actually fix the image? (check `kubectl get pods -n triage-test`)
- Did it verify the fix worked?
- Was the container name correct in the `set image` command?

---

## Scenario 2: Missing ConfigMap

**Setup:**
```bash
kubectl create namespace triage-test 2>/dev/null || true
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-reader
  namespace: triage-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-reader
  template:
    metadata:
      labels:
        app: config-reader
    spec:
      containers:
      - name: config-reader
        image: busybox:1.36
        command: ["sh", "-c", "cat /config/app.conf && sleep 3600"]
        volumeMounts:
        - name: config
          mountPath: /config
      volumes:
      - name: config
        configMap:
          name: app-config-missing
EOF
sleep 15
```

**Holmes — Triage:**
```bash
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Pod config-reader in triage-test is stuck in CreateContainerConfigError" \
  -p event_type="CreateContainerConfigError" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="config-reader" \
  -p severity="medium" \
  -p remediate="false" \
  --watch
```

**KAgent — Triage:**
```bash
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Pod config-reader in triage-test is stuck in CreateContainerConfigError" \
  -p event_type="CreateContainerConfigError" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="config-reader" \
  -p severity="medium" \
  -p remediate="false" \
  --watch
```

**What to compare:**
- Did it identify the missing configmap `app-config-missing`?
- Did it recommend creating the configmap?

**Remediation (run for each):**
```bash
# Reset between runs
kubectl delete configmap app-config-missing -n triage-test 2>/dev/null
kubectl rollout restart deployment/config-reader -n triage-test
sleep 15

# Holmes:
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Fix config-reader — missing configmap" \
  -p event_type="CreateContainerConfigError" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="config-reader" \
  -p remediate="true" --watch

# KAgent:
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Fix config-reader — missing configmap" \
  -p event_type="CreateContainerConfigError" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="config-reader" \
  -p remediate="true" --watch
```

---

## Scenario 3: OOMKilled Pod

**Setup:**
```bash
kubectl create namespace triage-test 2>/dev/null || true
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-hog
  namespace: triage-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: memory-hog
  template:
    metadata:
      labels:
        app: memory-hog
    spec:
      containers:
      - name: memory-hog
        image: busybox:1.36
        command: ["sh", "-c", "dd if=/dev/zero of=/dev/null bs=1M"]
        resources:
          limits:
            memory: "32Mi"
EOF
sleep 30  # wait for OOMKill + restart
```

**Triage (both):**
```bash
# Holmes:
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Pod memory-hog is being OOMKilled repeatedly" \
  -p event_type="OOMKilled" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="memory-hog" \
  -p severity="high" \
  -p remediate="false" --watch

# KAgent:
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Pod memory-hog is being OOMKilled repeatedly" \
  -p event_type="OOMKilled" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="memory-hog" \
  -p severity="high" \
  -p remediate="false" --watch
```

**What to compare:**
- Did it find the OOMKilled termination reason?
- Did it report the 32Mi limit?
- Did it recommend increasing memory?
- For remediation: did it use `kubectl patch` correctly (not `kubectl edit`)?

---

## Scenario 4: Failed Helm Release

**Setup:**
```bash
# Install a chart with intentionally wrong values to cause failure
helm install broken-release oci://registry-1.docker.io/bitnamicharts/nginx \
  --namespace triage-test --create-namespace \
  --set image.tag=99.99.99-doesnotexist \
  --wait=false 2>/dev/null || true
sleep 20
```

**Triage (both):**
```bash
# Holmes (limited — no built-in helm tools):
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Helm release broken-release in triage-test has pods not ready" \
  -p event_type="HelmReleaseFailed" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="broken-release-nginx" \
  -p severity="medium" \
  -p remediate="false" --watch

# KAgent (has helm tools — should give richer output):
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Helm release broken-release in triage-test has pods not ready — check the release history and identify the issue" \
  -p event_type="HelmReleaseFailed" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="broken-release-nginx" \
  -p severity="medium" \
  -p remediate="false" --watch
```

**What to compare:**
- **Holmes**: Can only `kubectl describe` the pods. Cannot check helm release history.
- **KAgent**: Should call `helm_list_releases` + `helm_get_release` to see chart version, values diff, previous revision. Much richer diagnosis.

---

## Scenario 5: Cross-Namespace Dependency Chain

**Setup:**
```bash
kubectl create namespace triage-test 2>/dev/null || true
# Backend that depends on a service that doesn't exist
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: triage-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      containers:
      - name: backend-api
        image: busybox:1.36
        command: ["sh", "-c", "while true; do wget -q -O- http://database-svc.database-ns:5432 2>&1 || echo 'Connection failed'; sleep 5; done"]
EOF
sleep 15
```

**Triage (both):**
```bash
# Holmes:
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="backend-api in triage-test keeps logging connection failures to database-svc" \
  -p event_type="ConnectionError" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="backend-api" \
  -p severity="high" \
  -p remediate="false" --watch

# KAgent:
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="backend-api in triage-test keeps logging connection failures to database-svc.database-ns — trace the dependency chain" \
  -p event_type="ConnectionError" \
  -p namespace="triage-test" \
  -p resource_kind="Deployment" \
  -p resource_name="backend-api" \
  -p severity="high" \
  -p remediate="false" --watch
```

**What to compare:**
- Did it check logs to find the connection error?
- Did it check if `database-ns` namespace exists?
- Did it check if `database-svc` service exists?
- **KAgent advantage**: `k8s_check_service_connectivity` tool can test the connection directly

---

## Comparison Scorecard

### Scenario 1: ImagePullBackOff — Tested 2026-02-17

| Metric | Holmes | KAgent | Winner |
|--------|--------|--------|--------|
| Identified root cause | No — got confused by `call_kubectl` subshell error, explained shell quoting instead of the image issue | Yes — identified `nginx:doesnotexist` as bad tag, recommended `nginx:latest` | **KAgent** |
| Fix applied correctly | N/A (triage only run) | Yes — `k8s_patch_resource` with correct container name `nginx` and `nginx:latest` | **KAgent** |
| Triage duration (seconds) | 153s | 55s | **KAgent** |
| Remediation duration (seconds) | Not tested | 183s (3 min) | KAgent |
| Tool calls (triage) | 2 (`call_kubectl` x2) | 1 (`k8s_describe_resource`) | **KAgent** |
| Tool calls (remediation) | N/A | 4 (describe → patch → get deployments → get pod yaml) | KAgent |
| Output quality | Poor — diagnosed shell error instead of image issue | Excellent — followed Issue/Evidence/Root Cause/Fix format exactly | **KAgent** |
| Verified fix | N/A | Yes — confirmed pod Running with `nginx:latest` | **KAgent** |
| GitLab issue created | Yes (#412) | Yes (#413 triage, #414 remediation) | Tie |

**Key insight**: Holmes's `call_kubectl` tool tried to use `$(kubectl ...)` subshell in its args, which AKS-MCP doesn't support. KAgent's native `k8s_describe_resource` tool avoids this entirely — it's a direct API call, not a shell command.

### Scenario 2: Missing ConfigMap — Tested 2026-02-17 (re-tested after prompt fix)

**Original run**: Holmes won (64s, YAML template) vs KAgent (114s, no YAML). See [Round 1](#scenario-2-round-1) below.

**Re-test after adding YAML-example rule to agent system prompt:**

| Metric | Holmes | KAgent (v2) | Winner |
|--------|--------|-------------|--------|
| Identified missing ConfigMap | Yes — confirmed `app-config-missing` not found | Yes — listed all ConfigMaps, found only `kube-root-ca.crt` | Tie |
| Root cause correct | Yes — ConfigMap does not exist in namespace | Yes — confirmed missing (used exact namespace `triage-test`) | Tie |
| Recommended fix quality | 4-step guide with YAML template | Structured Issue/Evidence/Root Cause/Fix **with ready-to-use YAML template** | Tie |
| Triage duration (seconds) | 64s | 40s | **KAgent** |
| Tool calls (triage) | 2 (`describe pod`, `get configmap`) | 1 (`k8s_get_resources configmap`) | **KAgent** |
| Output quality | Thorough — pod describe + direct CM lookup + YAML | Concise + actionable — structured format + YAML + escalation note | Tie |
| GitLab issue created | Yes (#415) | Yes (#423) | Tie |

**Key insight**: After adding the rule "always include a ready-to-use YAML example", KAgent now provides a ConfigMap YAML template matching Holmes's output quality. KAgent is also 38% faster (40s vs 64s). The system prompt change was sufficient — no model upgrade needed.

**Winner: KAgent (v2)**

<details><summary><a id="scenario-2-round-1"></a>Round 1 results (before fix)</summary>

Holmes won: 64s with YAML template vs KAgent 114s with no YAML. KAgent correctly identified root cause but provided less actionable output. Issue #419.

</details>

### Scenario 3: OOMKilled — Tested 2026-02-17 (re-tested after namespace fix)

**Original run**: Holmes won because KAgent misspelled `triage-test` as `triaage-test`. See [Round 1](#scenario-3-round-1) below.

**Re-test after adding namespace anchoring (`CRITICAL: use exact namespace...`):**

| Metric | Holmes | KAgent (v2) | Winner |
|--------|--------|-------------|--------|
| Found OOMKill + limits | Yes — saw Exit Code 137, 32Mi limit | Yes — saw Exit Code 137, 32Mi limit, CrashLoopBackOff for both pods | Tie |
| Correct namespace used | Yes | Yes — `triage-test` used correctly in all tool calls (no typo) | Tie |
| Recommended correct fix | Vague — "adjusting memory limits", bundled with unrelated pods | Detailed — explained *why* `tail /dev/zero` causes OOM vs the other command | **KAgent** |
| Evidence quality | Strong — pod describe output | Excellent — full describe of both pods + analysis of memory behaviour per command | **KAgent** |
| Focus on target resource | Poor — reported on broken-release-nginx, config-reader, web-broken | Focused — only discussed memory-hog pods | **KAgent** |
| Triage duration (seconds) | 150s | 161s | Tie (both under 3 min) |
| Tool calls (triage) | 4 (2 succeeded, 2 failed) | 1 (`k8s_describe_resource` — succeeded) | **KAgent** |
| GitLab issue created | Yes (#416) | Yes (#424) | Tie |

**Key insight**: The namespace anchoring fix (`CRITICAL: use exact namespace "triage-test"`) completely eliminated the Qwen 14B typo bug. KAgent now gathers real cluster data and provides superior analysis — it even explained the difference between the two pod commands and why one triggers OOM while the other doesn't. Holmes still reports on unrelated pods in the namespace.

**Winner: KAgent (v2)**

<details><summary><a id="scenario-3-round-1"></a>Round 1 results (before fix)</summary>

Holmes won: KAgent misspelled namespace as `triaage-test`, all 3 tool calls failed. Analysis was just inference from the error message. Issue #420.

</details>

### Scenario 4: Failed Helm Release — Tested 2026-02-17

| Metric | Holmes | KAgent | Winner |
|--------|--------|--------|--------|
| Found chart/image issue | Partially — described deployment and saw ImagePullBackOff | Yes — found `image.tag: 99.99.99-doesnotexist` in Helm values | **KAgent** |
| Checked Helm history/values | No — only used `kubectl` commands | Yes — `helm_get_release` returned user-supplied values showing bad tag | **KAgent** |
| Suggested fix | No — used literal `<pod-name>` placeholder, analysis derailed | Yes — "Update Helm release values to use a valid image tag and redeploy" | **KAgent** |
| Triage duration (seconds) | 125s | 83s | **KAgent** |
| Tool calls (triage) | 3 (describe deployment, get pods, describe pod `<pod-name>` literal) | 2 (`helm_get_release` history, `helm_get_release` values) | **KAgent** |
| Output quality | Poor — `kubectl describe pod <pod-name>` used literal placeholder instead of actual pod name | Excellent — clear Issue/Evidence/Root Cause/Fix with Helm-specific data | **KAgent** |
| GitLab issue created | Yes (#417) | Yes (#421) | Tie |

**Key insight**: Holmes has a `<pod-name>` literal placeholder bug — after running `kubectl get pods` (which showed the actual pod name), it then ran `kubectl describe pod <pod-name>` using the literal string. KAgent's native `helm_get_release` tool immediately revealed the bad Helm values. This scenario demonstrates KAgent's Helm-native advantage.

**Winner: KAgent**

### Scenario 5: Cross-Namespace Dependency Chain — Tested 2026-02-17

| Metric | Holmes | KAgent | Winner |
|--------|--------|--------|--------|
| Traced dependency chain | Partially — found `database-ns` namespace NotFound in tool output but ignored it in analysis | Yes — confirmed `database-ns` not in namespace list, service missing | **KAgent** |
| Used connectivity check | N/A | Yes — `k8s_check_service_connectivity` to test `database-svc.database-ns.svc.cluster.local:5432` | **KAgent** |
| Found missing namespace/service | Evidence was in tool output but not in conclusion | Yes — explicitly identified both missing namespace and service | **KAgent** |
| Triage duration (seconds) | 146s | 88s | **KAgent** |
| Tool calls (triage) | 3 (`get services -n database-ns`, `get endpoints`, `get pods -n triage-test`) | 4 (`get service`, `get namespaces`, `check_service_connectivity`, `get_resource_yaml`) | Tie |
| Output quality | Poor — reported on all unrelated pods instead of the actual connection error | Good — clear 3-step fix + escalation path, despite minor `triate-test` typo | **KAgent** |
| GitLab issue created | Yes (#418) | Yes (#422) | Tie |

**Key insight**: Holmes discovered the critical evidence (`database-ns` namespace not found) in its tool output but then got distracted by the pod listing and reported on unrelated pods (broken-release-nginx, memory-hog, config-reader). It completely ignored the original query about `database-svc.database-ns:5432`. KAgent stayed focused on the actual problem and provided actionable recommendations. KAgent also had a minor namespace typo (`triate-test`), but this didn't derail its analysis.

**Winner: KAgent**

### Overall Scorecard — All Scenarios (after prompt improvements)

| Scenario | Holmes Duration | KAgent Duration | Winner | Key Differentiator |
|----------|----------------|-----------------|--------|-------------------|
| 1. ImagePullBackOff | 153s | 55s | **KAgent** | Holmes confused by shell quoting; KAgent native API calls |
| 2. Missing ConfigMap | 64s | 40s (v2) | **KAgent** | Both provide YAML templates now; KAgent faster |
| 3. OOMKilled | 150s | 161s (v2) | **KAgent** | Namespace fix eliminated typo; KAgent gives deeper OOM analysis |
| 4. Helm Release | 125s | 83s | **KAgent** | KAgent has native helm tools; Holmes used `<pod-name>` literal |
| 5. Cross-Namespace | 146s | 88s | **KAgent** | KAgent traced dependency; Holmes reported unrelated pods |
| **Total** | | | **KAgent 5 – Holmes 0** | |

**Round 1 score** (before prompt fixes): KAgent 3 – Holmes 2
**Round 2 score** (after namespace anchoring + YAML example rules): KAgent 5 – Holmes 0

GitLab issues created: #412–#424 (13 issues across all tests).

### What changed between rounds
Two prompt-level fixes turned the two losses into wins:
1. **Namespace anchoring** — added `CRITICAL: use exact namespace "X"` to the workflow prompt. Fixed the Qwen 14B typo bug (Scenario 3).
2. **YAML example rule** — added "always include a ready-to-use YAML example" to the agent system prompt. Made output actionable (Scenario 2).

---

## Cleanup

```bash
kubectl delete namespace triage-test
helm uninstall broken-release -n triage-test 2>/dev/null
```

---

## Pros & Cons Summary

### HolmesGPT

| Pros | Cons |
|------|------|
| Single API call — simple to integrate | Token-hungry — loads all toolsets even if unused |
| Proven in production (Robusta ecosystem) | Single agent loop — no triage/remediation separation |
| Built-in investigation patterns | Only kubectl via AKS-MCP — no native helm, no gateway tools |
| `/api/investigate` is purpose-built for incident triage | Overly chatty output (hard to control format) |
| Good documentation and community support | `kubectl edit` and other interactive commands are footguns |
| Single Helm release to deploy | Separate AKS-MCP deployment needed for cluster access |

### KAgent

| Pros | Cons |
|------|------|
| Token-efficient — each agent gets only its tools via `toolNames` | Newer project (v0.7.13) — less battle-tested |
| Triage + remediation agents with separate RBAC | More moving parts (controller, agents, tool server, MCP) |
| Built-in k8s tools (17+) + helm tools (6) + kgateway tools | A2A protocol adds complexity vs simple REST |
| Structured output format enforced by agent system prompts | Session-based interaction requires more orchestration |
| A2A protocol for agent-to-agent escalation | Qwen 14B on RTX 3060 can be slow for multi-step reasoning |
| Runbook support via Skills (OCI images) or ConfigMap system prompts | No built-in investigation endpoint like Holmes `/api/investigate` |
| Grafana MCP available for metrics-backed diagnosis | Grafana MCP not yet deployed on homelab |
| `k8s_check_service_connectivity` for live dependency validation | Agent CRDs are K8s-native (good) but verbose to configure |
| `k8s_execute_command` for in-pod debugging | |
| `k8s_generate_resource` for Istio/Gateway/Argo manifests | |
| Multi-agent orchestration (triage escalates to remediation) | |

### When to Use Which

| Scenario | Recommended Backend | Why |
|----------|-------------------|-----|
| Simple pod investigation (logs, events) | Either | Both handle this well |
| Helm release issues (rollback, version drift) | **KAgent** | Has native helm tools |
| Auto-remediation (fix + verify) | **KAgent** | Separate agent with safety protocol |
| Quick first-pass alert triage | **Holmes** | Single API call, faster for simple cases |
| Cross-namespace dependency tracing | **KAgent** | `k8s_check_service_connectivity` tool |
| Metrics-backed diagnosis (CPU/memory trends) | **KAgent** | Grafana MCP (when deployed) |
| Gateway/ingress routing issues | **KAgent** | kgateway-agent with route tools |
| Work environment (AKS + Azure) | **KAgent** | AKS-MCP full toolset (detectors, fleet, advisor) |
| Cost-optimised (minimal LLM calls) | **KAgent** | Selective tool loading, concise system prompt |
