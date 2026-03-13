<!--
Labels: feature, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# Deploy Ollama with qwen2.5:7b for LLM triage step

## Context

The v2 WorkflowTemplate includes an LLM triage step that calls Ollama for event classification. Ollama must be running with the model pulled **before** enabling the v2 template. See `PRODUCTION-PLAN.md` Phase 1.

## Tasks

- [ ] Create `ollama` namespace
- [ ] Create PVC `ollama-models` (50Gi, managed-csi)
- [ ] Deploy Ollama (pinned to `ollama/ollama:0.6.2`, CPU-only)
- [ ] Run model pull job for `qwen2.5:7b`
- [ ] Verify: `kubectl exec -n ollama deployment/ollama -- ollama list` shows the model
- [ ] Test inference: `curl http://ollama-svc.ollama.svc.cluster.local:11434/api/generate` from a test pod

## Resource Requirements

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 2 cores | 4 cores |
| Memory | 8Gi | 12Gi |
| Storage | 50Gi PVC | — |

## Future: GPU Upgrade Path

When GPU node pool is available, add `nvidia.com/gpu: 1` to limits and add node selector/tolerations. This reduces inference latency from ~3-5s to <1s.

## Acceptance Criteria

- [ ] Ollama pod running and healthy (liveness + readiness probes passing)
- [ ] `qwen2.5:7b` model available and serving
- [ ] Inference responds in < 10s for a sample K8s event prompt
