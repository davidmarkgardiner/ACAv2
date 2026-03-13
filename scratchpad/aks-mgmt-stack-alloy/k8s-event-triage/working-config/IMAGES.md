# Container Images Used

All images verified working on AKS (aks-event-triage-dev) on 2026-03-12.

| Component | Image | Source | Notes |
|-----------|-------|--------|-------|
| Argo Events Controller | `quay.io/argoproj/argo-events:v1.9.10` | Quay.io | Pin version! Never use `stable` tag |
| EventSource | `quay.io/argoproj/argo-events:v1.9.10` | Quay.io | Kafka consumer, auto-created by controller |
| Sensor | `quay.io/argoproj/argo-events:v1.9.10` | Quay.io | Event router, auto-created by controller |
| EventBus — NATS | `nats:2.10.10` | Docker Hub | JetStream main container |
| EventBus — Config Reloader | `natsio/nats-server-config-reloader:0.14.0` | Docker Hub | JetStream sidecar (source of image pull failures!) |
| EventBus — Metrics Exporter | `natsio/prometheus-nats-exporter:0.14.0` | Docker Hub | JetStream sidecar |
| EventBus — NATS Streaming | `nats-streaming:0.25.6` | Docker Hub | Only if using native NATS (not JetStream) |
| Alloy | `grafana/alloy:v1.12.2` | Docker Hub | K8s event collector, OTLP/Kafka exporter |
| Workflow step | `badouralix/curl-jq:alpine` | Docker Hub | jq + curl for event parsing |
| Argo Workflows Controller | (Helm managed) | Quay.io | v3.6.4 used in this deployment |
| Argo Workflows Server | (Helm managed) | Quay.io | v3.6.4 used in this deployment |

## Private Registry

**Setting image overrides on the EventBus CR does NOT work reliably.** The controller reads images from a ConfigMap, not the CR. Sidecar images (config-reloader, metrics-exporter) will still pull from Docker Hub even if you override the main NATS image.

**Fix:** Override images at the Helm chart level. See:
- `PRIVATE-REGISTRY.md` — full guide with ACR import commands
- `helm-values-argo-events.yaml` — Helm values file with all image overrides

## Notes

- **DO NOT use `quay.io/argoproj/argo-events:stable`** — this is a floating tag that resolves to whatever the latest release is. Pin to `v1.9.10`.
- **`badouralix/curl-jq:alpine`** is a lightweight image with both `curl` and `jq` — ideal for simple workflow steps that need JSON processing + HTTP calls.
- For production LLM triage, use `python:3.12-slim` (has urllib for HTTP calls).
