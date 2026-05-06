#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Apply the Alloy-direct PoC in the right order.
# Idempotent — re-run safely.
# -----------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

NS="argo-events"

echo "==> ensure namespace ${NS} exists"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

echo "==> 1/4  bearer token Secret"
kubectl apply -f 00-secret.yaml

echo "==> 2/4  EventSource (webhook on :12001/alloy)"
kubectl apply -f 01-eventsource.yaml

echo "==> 3/4  Sensor (fans every POST into alloy-poc-echo workflow)"
kubectl apply -f 02-sensor.yaml

echo "==> 4/4  WorkflowTemplate (echo)"
kubectl apply -f 03-workflow-template.yaml

echo
echo "==> wait for EventSource pod ready"
kubectl -n "${NS}" rollout status deploy -l eventsource-name=alloy-poc --timeout=60s || \
  kubectl -n "${NS}" get pods -l eventsource-name=alloy-poc

echo
echo "Done. Smoke test with:"
echo "  kubectl -n ${NS} port-forward svc/alloy-poc-eventsource-svc 12001:12001 &"
echo "  ./test-curl.sh"
echo
echo "Watch:"
echo "  kubectl -n ${NS} logs -l eventsource-name=alloy-poc -f"
echo "  kubectl -n ${NS} get wf -l app.kubernetes.io/part-of=alloy-direct-poc -w"
