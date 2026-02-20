# Phased Rollout - Three-Tier Event Triage

## Architecture

One Event Hub topic, three consumer groups. Each consumer group gets ALL messages independently. Filtering happens in the workflow's parse-otlp step — cheap to run (Python, 3s, 64Mi) and discards non-matching events with zero fan-out.

```
                                    ┌─────────────────────────────┐
                                    │ Azure Event Hub             │
                                    │ Topic: k8s-events           │
                                    │                             │
                                    │ ┌─────────────────────────┐ │
Alloy ──OTLP JSON──────────────────►│ │ Partition 0 │ Part 1    │ │
(workload cluster)                  │ └─────────────────────────┘ │
                                    └──────┬──────┬──────┬────────┘
                                           │      │      │
                            ┌──────────────┘      │      └──────────────┐
                            │                     │                     │
                    consumer-critical     consumer-warnings     consumer-infra
                            │                     │                     │
                    ┌───────▼───────┐     ┌───────▼───────┐     ┌───────▼───────┐
                    │ EventSource   │     │ EventSource   │     │ EventSource   │
                    │ (critical)    │     │ (warnings)    │     │ (infra)       │
                    └───────┬───────┘     └───────┬───────┘     └───────┬───────┘
                            │                     │                     │
                    ┌───────▼───────┐     ┌───────▼───────┐     ┌───────▼───────┐
                    │ Sensor        │     │ Sensor        │     │ Sensor        │
                    │ 5/min         │     │ 10/min        │     │ 3/min         │
                    └───────┬───────┘     └───────┬───────┘     └───────┬───────┘
                            │                     │                     │
                    ┌───────▼───────┐     ┌───────▼───────┐     ┌───────▼───────┐
                    │ Workflow      │     │ Workflow       │     │ Workflow      │
                    │               │     │                │     │               │
                    │ parse-otlp:   │     │ parse-otlp:    │     │ parse-otlp:   │
                    │  critical     │     │  non-critical   │     │  infra ns     │
                    │  reasons only │     │  warnings only  │     │  all warnings │
                    │               │     │                │     │               │
                    │ ► Cloud VLLM  │     │ ► Hosted VLLM  │     │ ► Mattermost  │
                    │ ► Mattermost  │     │   (best effort) │     │   (notify)    │
                    │   (must alert)│     │                │     │               │
                    └───────────────┘     └────────────────┘     └───────────────┘
```

## Three Tiers

| Tier | Consumer Group | Filter | Backend | SLA | Rate Limit |
|---|---|---|---|---|---|
| **Critical** | `consumer-critical` | CrashLoopBackOff, OOMKilled, FailedScheduling, NodeNotReady | Cloud VLLM (fast, capable) | **Must be handled** | 5/min |
| **Warnings** | `consumer-warnings` | All other Warning events (non-critical) | Hosted VLLM (local, cheaper) | Best effort | 10/min |
| **Infra** | `consumer-infra` | Warning events in core infra namespaces | Mattermost notification only (to start) | Monitoring | 3/min |

## Phased Deployment

### Phase 1: Critical Only

Deploy: `tier-critical/` + Alloy config with target app namespaces

```
Alloy namespaces: ["app-ns-1", "app-ns-2"]
Consumer groups:  consumer-critical
Workflows:        k8s-triage-critical → Cloud VLLM + Mattermost
```

**Goal:** Prove the pipeline works end-to-end with real events. Only critical events trigger, low volume, high signal.

**Alloy config:** `alloy/alloy-config-phase1.yaml`

### Phase 2: Add Warnings

Deploy: `tier-warnings/` (critical stays running)

```
Alloy namespaces: ["app-ns-1", "app-ns-2"]  (unchanged)
Consumer groups:  consumer-critical, consumer-warnings
Workflows:        k8s-triage-critical → Cloud VLLM
                  k8s-triage-warnings → Hosted VLLM (best effort)
```

**Goal:** Start triaging warning events with the cheaper hosted model. Warnings are higher volume but lower priority. If hosted VLLM is slow or overloaded, workflows queue up and that's fine.

**Alloy config:** Same as Phase 1 (no change needed — warnings come from same namespaces)

### Phase 3: Infra Catch-All

Deploy: `tier-infra/` + update Alloy namespace list

```
Alloy namespaces: ["app-ns-1", "app-ns-2", "external-dns", "cert-manager",
                    "ingress-nginx", "kube-system", "monitoring"]
Consumer groups:  consumer-critical, consumer-warnings, consumer-infra
Workflows:        k8s-triage-critical → Cloud VLLM
                  k8s-triage-warnings → Hosted VLLM
                  k8s-triage-infra    → Mattermost (notification only initially)
```

**Goal:** Visibility into core infra namespace health. Start with notifications only; add VLLM analysis later once the pattern is proven.

**Alloy config:** `alloy/alloy-config-phase3.yaml`

## Why One Topic, Three Consumer Groups?

**Alternative considered:** Three separate Event Hub topics with Alloy routing events to each.

**Why we chose one topic:**
- Simpler Alloy config (one exporter, one pipeline)
- Simpler Azure infrastructure (one topic, one partition set)
- Filtering is cheap (3-second Python pod per message)
- Consumer groups are independent — if warnings fall behind, critical isn't affected
- Adding a new tier = new consumer group + new sensor, no Alloy changes

**The "waste":** Each consumer group gets ALL messages. If a Warning event arrives, the critical consumer group triggers a workflow that parses OTLP, finds 0 critical events, and exits. That's one lightweight pod (64Mi, 3s) — negligible cost.

## Consumer Group Independence

Kafka consumer groups are fully independent:
- **Critical falls behind?** Won't happen — rate-limited to 5/min, cloud VLLM is fast
- **Warnings back up?** That's fine — best effort, hosted VLLM works through the queue
- **Infra overloaded?** Rate-limited to 3/min, notification-only is instant

If you need to pause a tier, just delete its Sensor. The consumer group offset is preserved — when you re-deploy, it picks up where it left off.

## VLLM Integration Points

Each tier's workflow template has a configurable VLLM step. The endpoint is set via ConfigMap:

```yaml
# For critical tier (cloud VLLM)
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-critical-config
  namespace: argo-events
data:
  VLLM_ENDPOINT: "https://api.cloud-provider.com/v1/chat/completions"
  VLLM_MODEL: "gpt-4o"

# For warnings tier (hosted VLLM)
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-warnings-config
  namespace: argo-events
data:
  VLLM_ENDPOINT: "http://vllm-service.vllm.svc.cluster.local:8000/v1/chat/completions"
  VLLM_MODEL: "qwen3-14b"
```

## Event Hub Setup

```bash
# One topic, three consumer groups
az eventhubs eventhub consumer-group create --name consumer-critical \
  --eventhub-name k8s-events --namespace-name evh-YOUR-NS --resource-group rg-YOUR-RG

az eventhubs eventhub consumer-group create --name consumer-warnings \
  --eventhub-name k8s-events --namespace-name evh-YOUR-NS --resource-group rg-YOUR-RG

az eventhubs eventhub consumer-group create --name consumer-infra \
  --eventhub-name k8s-events --namespace-name evh-YOUR-NS --resource-group rg-YOUR-RG
```
