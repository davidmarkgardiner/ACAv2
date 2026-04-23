# networking-triage-agent — kagent POC

Specialist kagent agent for AKS networking diagnostics. Mirrors the diagnostic
patterns of Microsoft's Container Network Insights Agent but runs inside your
kagent pipeline so it's callable from Argo Workflows, feeds the lessons-learned
loop, and outputs structured JSON suitable for automated decision-making.

**Status:** POC — manifests and prompts ready; not yet integrated with
`remediation-tier-mapping` workflow enforcement step (ConfigMap is here but
the workflow that consumes it is a separate build).

## Architecture

```
Argo Workflow: net-triage
     │
     ▼
kagent A2A call → networking-triage-agent
     │
     ├─ loads skills from git (dns-diagnostics, k8s-networking)
     │
     ├─ uses TWO MCP servers:
     │    kagent-tool-server (typed kubectl wrappers, primary)
     │      - k8s_get_resources, k8s_describe_resource, k8s_get_resource_yaml
     │      - k8s_get_pod_logs, k8s_get_events
     │      - k8s_check_service_connectivity, k8s_get_cluster_configuration
     │      - k8s_execute_command (for cilium/hubble CLI via exec)
     │    aks-mcp (optional, Azure-aware)
     │      - call_kubectl (generic exec)
     │      - aks_network_resources (VNet, NSG, LB, route tables)
     │      - aks_monitoring (Azure Monitor)
     │      - cilium / hubble (if ACNS + additional-tools enabled)
     │
     ├─ collects evidence, analyses
     │
     └─ returns structured JSON with proposed tier
            │
            ▼
Argo Workflow: enforce tier via remediation-tier-mapping ConfigMap
            │
            ├─ T0/T1 → auto-execute
            ├─ T2/T3 → Teams approval card → wait → execute
            └─ T4    → GitLab ticket, stop
```

## MCP Server Cheat Sheet — which tool to use

Two separate MCP servers, two different vocabularies. Tool names matter.

| Tool | From | Read/Write | Use for |
|---|---|---|---|
| `k8s_get_resources` | kagent-tool-server | R | List pods/services/etc — typed |
| `k8s_describe_resource` | kagent-tool-server | R | Full describe output — typed |
| `k8s_get_pod_logs` | kagent-tool-server | R | Stream logs — typed |
| `k8s_get_events` | kagent-tool-server | R | Events for namespace — typed |
| `k8s_get_resource_yaml` | kagent-tool-server | R | Raw YAML — typed |
| `k8s_check_service_connectivity` | kagent-tool-server | R | Probe svc from a pod — typed |
| `k8s_execute_command` | kagent-tool-server | R | `kubectl exec` — generic |
| `call_kubectl` | aks-mcp | R* | Generic kubectl (under accessLevel:readonly) |
| `call_cilium` | aks-mcp | R* | Cilium CLI — `status`, `endpoint list`, `policy get` |
| `call_hubble` | aks-mcp | R | Hubble flow observe (native read-only) |
| `call_helm` | aks-mcp | R* | helm list/get values/history |
| `aks_network_resources` | aks-mcp | R | Azure VNet/NSG/LB (off-cluster) |
| `aks_monitoring` | aks-mcp | R | Azure Monitor metrics/logs |
| `aks_detector` | aks-mcp | R | AKS diagnostic detectors |
| `aks_advisor_recommendation` | aks-mcp | R | Azure Advisor |
| `az_aks_operations` | aks-mcp | R* | AKS cluster ops |

\* aks-mcp tools inherit the deployment's `accessLevel` setting. With
`accessLevel: readonly` (recommended and set in `values-networking.yaml`),
these tools reject any destructive command at the server level regardless of
what the agent asks for.

**Intentionally NOT listed in the agent tool set:**
- `inspektor_gadget_observability` — its `deploy`/`run` actions are
  destructive (install eBPF gadget DaemonSet). Belongs in `remediation-agent`
  behind workflow approval, not triage.

**Rule of thumb:** typed tools first (safer, structured errors); fall back to
`call_kubectl` / `call_cilium` / `call_hubble` for the things typed tools
don't cover.

## Files

| File | Purpose |
|---|---|
| `agent.yaml` | The kagent Agent resource |
| `tier-mapping-configmap.yaml` | Tier enforcement rules read by Argo Workflow |
| `skills/dns-diagnostics/SKILL.md` | DNS diagnostic playbook |
| `skills/k8s-networking/SKILL.md` | Pod/svc/endpoint/policy diagnostic playbook |
| `VALIDATION.md` | Test prompts + expected JSON output |
| `README.md` | This file |

## Pre-reqs

Checklist before deploying on the worker cluster:

- [ ] kagent 0.8.0+ installed (v0.8.0-beta4 verified on red cluster)
- [ ] agentgateway configured with `agentgateway-azure-openai` + `agentgateway-qwen` ModelConfigs
- [ ] `kagent-tool-server` RemoteMCPServer registered (standard — ships with kagent; check with `kubectl get remotemcpserver -n kagent`)
- [ ] `aks-mcp` RemoteMCPServer deployed — see `../../aks-mcp-deploy/` for the Helm values + RemoteMCPServer manifest. Deploys aks-mcp with all 12 components enabled.
- [ ] ACNS (Advanced Container Networking Services) enabled on the AKS cluster — needed for `call_hubble`: `az aks update --name <aks> --resource-group <rg> --enable-acns`
- [ ] (Optional, for memory) kagent configured with pgvector-enabled Postgres. Without this, comment out the `memory:` block in `agent.yaml`
- [ ] Git access to this repo — public or via `git-credentials` Secret (`kubectl create secret generic git-credentials -n kagent --from-literal=token="$(gh auth token)"`)

Verify with:

```bash
kubectl get modelconfig -n kagent            # need agentgateway-azure-openai + agentgateway-qwen
kubectl get remotemcpserver -n kagent        # need kagent-tool-server, optionally aks-mcp

# Check what tools aks-mcp has registered (if installed)
kubectl logs -n <aks-mcp-ns> deploy/aks-mcp --tail=100 | grep -iE 'registered|tool'
```

If `aks-mcp` is missing, the agent still works via `kagent-tool-server` alone —
you just lose Azure-level network queries and dedicated cilium/hubble tools.
For cilium/hubble in that case, the agent falls back to `k8s_execute_command`
to run the CLI inside cilium pods.

**Replicating MS Container Network Insights Agent:** deploy aks-mcp per
`../../aks-mcp-deploy/README.md`. That enables all 12 components and gives
you parity with the MS agent's diagnostic surface (DNS, policies, flows,
Azure network resources, Monitor). The only gap is the MS agent's dedicated
host-level packet-drop DaemonSet — Inspektor Gadget covers most of that via
eBPF gadgets on-demand (but it's invoked by the remediation-agent, not
triage, because deploy/run actions are destructive).

## Deploy

```bash
# 1. Apply the tier mapping ConfigMap (does nothing yet — Argo workflow reads it)
kubectl apply -f tier-mapping-configmap.yaml

# 2. If using a private repo for skills, create the auth secret
#    kubectl create secret generic git-credentials -n kagent \
#      --from-literal=token="<github-PAT-or-gitea-PAT>"

# 3. Apply the agent
kubectl apply -f agent.yaml

# 4. Wait for ready
kubectl wait --for=condition=ready agent/networking-triage-agent -n kagent --timeout=120s

# 5. Verify skills loaded
POD=$(kubectl get pod -n kagent -l kagent/agent-name=networking-triage-agent -o name | head -1)
kubectl exec -n kagent $POD -c kagent -- ls -la /skills/
# Expected: dns-diagnostics/ and k8s-networking/ directories with SKILL.md inside
```

## Smoke test

```bash
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &
sleep 2

# Ask a networking question
curl -s -X POST "http://localhost:8083/api/a2a/kagent/networking-triage-agent/" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":"1","method":"message/send",
    "params":{"message":{"role":"user","parts":[{"kind":"text",
      "text":"Check CoreDNS health in this cluster and report."
    }]}}
  }' -m 180 | jq '.result.artifacts[0].parts[0].text'
```

Expected: prose narrative followed by a ```json fenced block matching the
schema in `agent.yaml` systemMessage. See `VALIDATION.md` for more test
prompts and JSON validation.

## Parse the JSON output from a workflow

Once the agent responds, extract the JSON in an Argo workflow step:

```yaml
- name: extract-report
  script:
    image: alpine:3.19
    command: [sh]
    source: |
      apk add --no-cache jq > /dev/null
      # Assume agent output is in /tmp/agent-response.json from the previous step
      # Extract the ```json fenced block from the assistant's text:
      REPORT=$(jq -r '.result.artifacts[0].parts[0].text' /tmp/agent-response.json \
        | awk '/^```json$/,/^```$/' \
        | sed '1d;$d')
      echo "$REPORT" > /tmp/report.json
      echo "=== Parsed report ==="
      jq . /tmp/report.json

      # Extract key fields for subsequent steps
      echo "category=$(jq -r .category /tmp/report.json)"
      echo "status=$(jq -r .status /tmp/report.json)"
      echo "proposed_tier=$(jq -r .remediation.proposed_tier // \"none\" /tmp/report.json)"
```

## Next steps after this POC

This folder is the "agent" piece only. The surrounding workflow logic that
consumes the agent's output still needs to be built:

1. **Tier-enforcement classifier** — Argo Workflow step that reads the agent's
   output, looks up the action in `remediation-tier-mapping`, and emits the
   FINAL tier (which may override the agent's proposal upward).

2. **Teams approval gate** — Adaptive Card sent via Logic App, workflow
   `suspend` step, resume webhook wired through.

3. **Remediation executor** — separate kagent agent with WRITE tools, invoked
   only after approval, given the exact approved action.

4. **Lessons integration** — agent output + resolution added to
   `shared_lessons` pgvector DB for future retrieval.

See `../../container-network-insights/ROADMAP.md` for the broader plan this
POC fits into.

## Known limitations

- **Packet drop diagnostics not included.** Requires a host-level debug
  DaemonSet (Phase 2b). For now, if user asks about packet drops, agent
  will set `status: insufficient_data` and point them at the MS Container
  Network Insights Agent for deep analysis.
- **Hubble flow analysis only if ACNS enabled.** Skill `k8s-networking`
  skips Step 6 gracefully if Hubble is unavailable.
- **Agent proposes a tier; it doesn't decide.** The tier ConfigMap is the
  enforced policy. Don't let the agent's `proposed_tier` drive execution
  directly — always route through the workflow's static mapping.
- **Memory requires pgvector.** If your kagent Postgres doesn't have
  pgvector, comment out the `memory:` block in `agent.yaml`. Agent works
  fine without memory (loses cross-session continuity).
