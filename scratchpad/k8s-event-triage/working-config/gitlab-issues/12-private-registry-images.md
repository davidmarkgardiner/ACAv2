<!--
Labels: infrastructure, security, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# Mirror all container images to private registry

## Context

Production clusters typically can't pull from Docker Hub (rate limits, security policy). All images used by the pipeline must be mirrored to the private ACR. See `PRIVATE-REGISTRY.md` and `IMAGES.md`.

## Images to Mirror

| Image | Used By |
|-------|---------|
| `badouralix/curl-jq:alpine` | v1 WorkflowTemplate parse-and-log |
| `python:3.12-slim` | v2 parse-event step |
| `curlimages/curl:8.6.0` | v2 llm-triage, create-gitea-issue, notify-mattermost |
| `ollama/ollama:0.6.2` | Ollama deployment |
| `alpine:3.18` | Manual test workflows |
| NATS images (from Helm values) | EventBus pods |
| Argo Events controller images | EventSource, Sensor |

## Tasks

- [ ] Identify private ACR URL
- [ ] Mirror all images with exact tags (never re-tag as `latest`)
- [ ] Update all manifests to reference private registry
- [ ] Update Helm values (`helm-values-argo-events.yaml`) for Argo Events images
- [ ] Verify EventBus sidecar images come from private registry (see GOTCHAS.md #12)
- [ ] Test: delete a pod and confirm it pulls from private registry on restart

## Acceptance Criteria

- [ ] All pods use private registry images
- [ ] `kubectl get pods -n argo-events -o jsonpath='{.items[*].spec.containers[*].image}'` shows no Docker Hub references
- [ ] `kubectl get pods -n ollama -o jsonpath='{.items[*].spec.containers[*].image}'` shows no Docker Hub references
