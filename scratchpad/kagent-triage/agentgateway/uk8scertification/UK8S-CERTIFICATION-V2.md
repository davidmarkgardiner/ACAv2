# UK8S Certification V2 — Agent-Triaged Cluster Certification

`uk8s-certification-v2.yaml` is a sibling RGD to `uk8s-certification.yaml`. v1 stays untouched; v2 is opt-in per cluster.

## What's new vs v1

1. **Per-workflow ConfigMap** captures structured pass/fail counts from every validation task. ownerReference points at the Workflow, so it's GC'd automatically — no Minio, no PVC.
2. **`agent-triage` DAG task** hands the aggregated report to KAgent's `sre-triage-agent` over A2A and parses a strict-schema verdict back into Argo output parameters.
3. **Verdict surface** — `severity`, `verdict` available on the task as `outputs.parameters` so any downstream step (Teams, exit hook, GitHub issue, whatever) can branch on it without re-parsing.
4. **Optional gating** — `failOnCritical` flag can fail the workflow when the agent returns severity=CRITICAL. Off by default.

## Data flow (the handover)

```
init-results-store
  └─► creates ConfigMap cert-results-<workflow-name> (ownerRef = Workflow)

validate-kro / validate-aso / validate-flux / ...
  └─► each appends one line:
      kubectl patch configmap cert-results-<wf> --type=merge \
        -p '{"data":{"<task>":"passed=N failed=N warnings=N"}}'

aggregate-certification
  ├─► reads ConfigMap data block
  ├─► sums passed/failed across all tasks → CERTIFIED | FAILED
  ├─► writes /tmp/cert-report.json
  └─► outputs.parameters.report  (full structured JSON)

agent-triage
  ├─► consumes inputs.parameters.cert-report
  ├─► POST http://kagent.kagent.svc.cluster.local/api/a2a/kagent/sre-triage-agent/
  │   {"jsonrpc":"2.0","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"..."}]}}}
  ├─► parses result.artifacts[0].parts[0].text → strict-schema JSON
  └─► outputs.parameters.severity   ← CRITICAL | WARNING | INFO | AGENT_UNAVAILABLE | PARSE_ERROR
      outputs.parameters.verdict    ← {severity, blast_radius, failed_checks[], first_remediation}

gate-on-critical (optional, when failOnCritical=true)
  └─► exit 1 if severity=CRITICAL → workflow fails → upstream alerting fires
```

## Schema additions

```yaml
agentAnalysis:
  enabled: bool        # default true
  kagentService: str   # default kagent.kagent.svc.cluster.local
  kagentPort: int      # default 80
  agentName: str       # default sre-triage-agent
  timeoutSeconds: int  # default 120
  failOnCritical: bool # default false
```

## Deploying the RGD

```bash
# Apply the RGD itself (one-time per cluster)
kubectl apply -f infra-stack/kro-stack/definitions/uk8s-certification-v2.yaml

# Verify it's Active
kubectl get resourcegraphdefinition uk8scertificationv2.kro.run

# Should show: STATE=Active
```

## Creating an instance

```yaml
apiVersion: kro.run/v1alpha1
kind: UK8SCertificationV2
metadata:
  name: cert-my-cluster
  namespace: default
spec:
  clusterName: my-aks-cluster
  resourceGroup: my-rg
  targetNamespace: aso-clusters
  instanceName: my-aks-cluster
  subscriptionId: 00000000-0000-0000-0000-000000000000
  environment: dev
  clusterType: PUBLIC
  certification:
    schedule: "0 2 * * 0"
    suspended: false
    autoTrigger: true
  agentAnalysis:
    enabled: true
    failOnCritical: false   # set true once you trust the agent verdicts
```

## Manually triggering a run

```bash
# Submit a one-off certification workflow (skips the autoTrigger Job)
kubectl create -n argo -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: certify-v2-my-aks-cluster-manual-
  namespace: argo
  labels:
    kro.run/cluster: my-aks-cluster
    kro.run/trigger: manual
    kro.run/version: v2
spec:
  workflowTemplateRef:
    name: certify-v2-my-aks-cluster
EOF
```

## Reading verdict from a running / completed workflow

```bash
# Latest workflow for this cluster
WF=$(kubectl get wf -n argo -l kro.run/cluster=my-aks-cluster --sort-by=.metadata.creationTimestamp -o name | tail -1)

# Severity (single string)
kubectl get $WF -n argo -o jsonpath='{.status.nodes[?(@.displayName=="agent-triage")].outputs.parameters[?(@.name=="severity")].value}'

# Full verdict JSON
kubectl get $WF -n argo -o jsonpath='{.status.nodes[?(@.displayName=="agent-triage")].outputs.parameters[?(@.name=="verdict")].value}' | jq .
```

The same data is also persisted in the ConfigMap under `_aggregated` and `_agent_verdict` keys:

```bash
kubectl get configmap cert-results-${WF##*/} -n argo -o jsonpath='{.data._agent_verdict}' | jq .
```

## Failure modes the agent task handles

| Condition | severity output | Workflow result |
|---|---|---|
| KAgent service unreachable / 5xx / timeout | `AGENT_UNAVAILABLE` | succeeds (cert verdict still valid) |
| Agent returned non-JSON or malformed text | `PARSE_ERROR` | succeeds (raw response in pod logs) |
| Agent returned valid CRITICAL/WARNING/INFO | as returned | succeeds, unless `failOnCritical=true` and severity=CRITICAL |

The agent step is intentionally `set +e` and never blocks on its own errors — the cert verdict from the validation tasks is the authoritative pass/fail signal.

## Connecting to a notification system (Teams, etc.)

Because the verdict is exposed as Argo output parameters, downstream notification is just another DAG task in this workflow OR a sibling workflow triggered by Argo Events watching for completed workflows with label `kro.run/component: certification` and `kro.run/version: v2`.

Either approach reads:
- `{{tasks.agent-triage.outputs.parameters.severity}}`
- `{{tasks.agent-triage.outputs.parameters.verdict}}`
- `{{tasks.aggregate-results.outputs.parameters.report}}`

## Verification checklist before flipping `failOnCritical=true`

- [ ] `uk8scertificationv2.kro.run` RGD shows `state: Active`
- [ ] One run completes end-to-end against a known-good cluster → severity=INFO
- [ ] One run against a deliberately-broken cluster (e.g. delete a flux deployment) → severity=WARNING or CRITICAL with sensible `blast_radius` and `failed_checks`
- [ ] Verify ConfigMap `cert-results-<wf>` is GC'd when the Workflow is deleted (proves ownerReference works)
- [ ] Confirm KAgent `sre-triage-agent` is reachable from the `argo` namespace at the configured service DNS

## Files

- `uk8s-certification-v2.yaml` — the RGD
- `UK8S-CERTIFICATION-V2.md` — this doc
- `uk8s-certification.yaml` — v1, untouched
