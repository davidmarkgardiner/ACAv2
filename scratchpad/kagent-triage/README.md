# kagent Triage Pipeline

AI-powered Kubernetes event triage using [kagent](https://github.com/kagent-dev/kagent) (CNCF Sandbox) agents and Argo Events/Workflows.

**Namespace-specific AI agents** automatically diagnose K8s warning events, identify root causes, suggest remediation, and notify via Telegram — all triggered by native Kubernetes events with zero human intervention.

## Architecture

```
┌─────────────────────┐
│  Kubernetes Cluster  │
│  (Warning Events)    │
└──────────┬──────────┘
           │ cluster-wide watch
           ▼
┌──────────────────────┐
│  Argo EventSource     │
│  (k8s-warning-events) │
│  namespace: argo-events│
└──────────┬───────────┘
           │ EventBus (NATS)
           ▼
┌──────────────────────┐     ┌─────────────────────┐
│  Argo Sensor          │     │  Argo Sensor          │
│  (kagent-triage-      │     │  (kagent-triage-      │
│   test-ns)            │     │   cert-manager)       │
│  filters: ns=test-ns  │     │  filters: ns=cert-mgr │
└──────────┬───────────┘     └──────────┬────────────┘
           │                             │
           ▼                             ▼
┌─────────────────────────────────────────────────────┐
│           Argo WorkflowTemplate: kagent-triage       │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │ 1. Find Agent│─▶│ 2. Chat API  │─▶│ 3. Telegram│ │
│  │ (GET /agents)│  │ (POST /chat) │  │ Notify     │ │
│  └──────────────┘  └──────────────┘  └────────────┘ │
└──────────┬──────────────────┬───────────────────────┘
           │                  │
           ▼                  ▼
┌─────────────────┐  ┌─────────────────┐
│ kagent Agent:    │  │ kagent Agent:    │
│ test-ns-agent    │  │ cert-mgr-agent   │
│ (namespace-      │  │ (cert-manager    │
│  scoped AI)      │  │  domain expert)  │
└─────────────────┘  └─────────────────┘
```

## How It Works

1. **K8s Warning Events** fire cluster-wide (pod failures, OOM, image pull errors, etc.)
2. **EventSource** (`k8s-warning-events`) captures all warning events across namespaces
3. **Sensors** filter events by namespace and trigger the triage workflow
4. **WorkflowTemplate** (`kagent-triage`) runs a 3-step DAG:
   - **find-agent**: Discovers the correct namespace-specific kagent agent via API
   - **create-conversation**: Sends the event details to the agent for AI diagnosis
   - **send-telegram**: Posts the diagnosis to Telegram
5. **kagent Agents** use MCP tools (kubectl equivalents) to investigate the cluster and provide structured diagnoses

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| `k8s-warning-events` EventSource | `argo-events` | Watches K8s warning events cluster-wide |
| `kagent-triage` WorkflowTemplate | `argo-events` | Orchestrates find → diagnose → notify |
| `kagent-triage-<ns>` Sensor | `argo-events` | Filters events for specific namespace |
| `<ns>-agent` Agent CR | `kagent` | Namespace-specific AI diagnostic agent |
| `kagent-controller` | `kagent` | REST API serving agent conversations |
| `kagent-ui` | `kagent` | Web UI for viewing agents and conversations |
| EventBus (NATS) | `argo-events` | Message bus connecting EventSource → Sensors |

## Manifest Files

| File | Description |
|------|-------------|
| `00-test-namespace.yaml` | Test namespace with ServiceAccount and RBAC |
| `01-test-agent.yaml` | kagent Agent CR for `test-ns` with diagnostic system prompt |
| `02-workflow-kagent-triage.yaml` | Argo WorkflowTemplate (find-agent → chat → telegram) |
| `03-sensor-kagent-triage.yaml` | Argo Sensor routing `test-ns` events to the workflow |
| `04-ingress-kagent-ui.yaml` | Traefik IngressRoute for kagent UI at `kagent.xxx` |
| `05-test-error-injection.yaml` | Test pods: ImagePullBackOff, OOMKilled, CrashLoopBackOff |

## Quick Start

```bash
# Deploy everything in order
for f in 00-test-namespace.yaml 01-test-agent.yaml 02-workflow-kagent-triage.yaml \
         03-sensor-kagent-triage.yaml 04-ingress-kagent-ui.yaml; do
  kubectl --context kind-homelab apply -f "$f"
done

# Wait for agent to be ready
kubectl --context kind-homelab wait agent/test-ns-agent -n kagent \
  --for=condition=Ready --timeout=60s

# Inject test errors
kubectl --context kind-homelab apply -f 05-test-error-injection.yaml

# Watch workflows fire
kubectl --context kind-homelab get workflows -n argo-events -w
```

## Prerequisites

- Kubernetes cluster with `kubectl` access
- **kagent** v0.8.0+ installed in `kagent` namespace
- **Argo Workflows** controller running (in `argo` namespace)
- **Argo Events** controller + EventBus (NATS) running (in `argo-events` namespace)
- **EventSource** `k8s-warning-events` watching all namespaces
- **Telegram bot token** stored in `telegram-bot-secret` secret (`argo-events` namespace)
- **ModelConfig** configured (e.g., `default-model-config` pointing to LiteLLM/Kimi/OpenAI)

## Related Documentation

- [API Reference](./API-REFERENCE.md) — kagent controller REST API endpoints
- [Deployment Guide](./DEPLOYMENT-GUIDE.md) — Step-by-step deployment with verification
- [Lift-and-Shift Guide](./LIFT-AND-SHIFT-AKS.md) — Migrating from Kind/homelab to Azure AKS
- [Adding Namespace Agents](./ADDING-NAMESPACE-AGENTS.md) — How to add new namespace agents using the OpenClaw skill

## Sensor Safeguards (REQUIRED)

**⚠️ All sensors MUST have these safeguards to prevent cascade loops.**

Kyverno generates `PolicyViolation` events when workflow pods violate policies. Without filters,
this causes an infinite loop: event → workflow → PolicyViolation → event → ...

Each sensor includes:
1. **PolicyViolation reason filter** — `body.reason != PolicyViolation`
2. **Rate limit** — max 5 workflows/minute per sensor
3. **Namespace filter** — only watch the target namespace (not argo-events/argo)

See [SENSOR-SAFEGUARDS.md](./SENSOR-SAFEGUARDS.md) for full details and emergency procedures.

## Current Deployment

| Setting | Value |
|---------|-------|
| Cluster | Kind (`kind-homelab` context) |
| kagent version | v0.8.0-beta4 |
| LLM Provider | Kimi For Coding via LiteLLM proxy |
| ModelConfig | `default-model-config` |
| kagent UI | https://kagent.xxx |
| Telegram Channel | `xxx` |
| A2A Protocol | `POST /api/a2a/kagent/{agent-name}/` (trailing slash required!) |

### Active Namespace Agents

| Agent | Namespace | Capabilities | Status |
|-------|-----------|-------------|--------|
| `test-ns-agent` | test-ns | Read-only diagnostic | ✅ Active |
| `cert-manager-agent` | cert-manager | Read + auto-patch deployments | ✅ Active |
| `external-secrets-agent` | external-secrets | Read-only diagnostic | ✅ Active |
| `kro-agent` | kro-system | Read-only diagnostic | ✅ Active |
| `kyverno-agent` | kyverno | Read-only diagnostic | ✅ Active |
| `reloader-agent` | reloader | Read-only diagnostic | ✅ Active |

### Known Issues

- **Kimi rate limits**: After ~10 A2A calls in quick succession, Kimi returns 429. Space tests 30s+ apart.
- **A2A trailing slash**: `POST /api/a2a/kagent/{agent-name}/` — trailing slash is REQUIRED or you get 404.
- **Message parts**: JSON-RPC parts must include `"kind": "text"` field.
- **PolicyViolation cascade**: See SENSOR-SAFEGUARDS.md. Fixed 2026-03-16 with reason filter + rate limit.

## References

- [kagent GitHub](https://github.com/kagent-dev/kagent) — CNCF Sandbox project
- [Argo Events Docs](https://argoproj.github.io/argo-events/)
- [Argo Workflows Docs](https://argoproj.github.io/argo-workflows/)
- [OpenClaw Skill](~/clawd/skills/kagent-namespace-agent/) — Automation for creating namespace agents

---

## ⚠️ Sensor Safeguards

**IMPORTANT:** Read `SENSOR-SAFEGUARDS.md` before deploying any sensors.

All sensors MUST have:
1. Rate limiting (5/min)
2. PolicyViolation event filtering
3. argo-events namespace exclusion
4. Test pods cleaned up before sensors are active

Failure to follow these will cause a cascade loop that burns API quota.
