# Container Images Used

All images verified working on AKS (aks-event-triage-dev) on 2026-03-12.

| Component | Image | Size | Notes |
|-----------|-------|------|-------|
| Alloy | `grafana/alloy:v1.12.2` | ~150MB | K8s event collector, OTLP/Kafka exporter |
| Argo Events Controller | `quay.io/argoproj/argo-events:v1.9.10` | ~100MB | Pin version! Never use `stable` tag |
| EventSource | `quay.io/argoproj/argo-events:v1.9.10` | (same) | Kafka consumer, auto-created by controller |
| Sensor | `quay.io/argoproj/argo-events:v1.9.10` | (same) | Event router, auto-created by controller |
| EventBus (JetStream) | `nats:2.10.10` | ~20MB | Managed by Argo Events controller |
| Workflow step | `badouralix/curl-jq:alpine` | ~15MB | jq + curl for event parsing |
| Argo Workflows Controller | (Helm managed) | | v3.6.4 used in this deployment |
| Argo Workflows Server | (Helm managed) | | v3.6.4 used in this deployment |

## Notes

- **DO NOT use `quay.io/argoproj/argo-events:stable`** — this is a floating tag that resolves to whatever the latest release is. Pin to `v1.9.10`.
- **DO NOT use `ollama/ollama:0.6`** — that tag doesn't exist. Use `:latest` if you add LLM triage.
- **`badouralix/curl-jq:alpine`** is a lightweight image with both `curl` and `jq` — ideal for simple workflow steps that need JSON processing + HTTP calls.
- For production LLM triage, use `python:3.12-slim` (has urllib for HTTP calls).
