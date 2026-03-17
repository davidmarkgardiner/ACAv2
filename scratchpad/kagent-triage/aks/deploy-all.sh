#!/bin/bash
# Deploy all AKS kagent agents and sensors
# Usage: ./deploy-all.sh [kubectl-context]
CONTEXT="${1:-aks-event-triage-dev}"
for f in *-agent.yaml; do kubectl --context "$CONTEXT" apply -f "$f"; done
for f in *-sensor.yaml; do kubectl --context "$CONTEXT" apply -f "$f"; done
kubectl --context "$CONTEXT" get agents -n kagent
kubectl --context "$CONTEXT" get sensors -n argo-events
