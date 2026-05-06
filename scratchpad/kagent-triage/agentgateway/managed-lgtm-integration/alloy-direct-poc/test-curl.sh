#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Smoke-test: pretend to be Alloy. POSTs a Loki-shaped JSON body to the
# alloy-poc EventSource and watches a workflow get created.
#
# Run from inside the cluster (kubectl run --rm) or from your laptop while
# port-forwarding:
#   kubectl -n argo-events port-forward svc/alloy-poc-eventsource-svc 12001:12001
#
# Usage:
#   ./test-curl.sh                       # uses default localhost:12001
#   URL=https://alerts.lab... ./test-curl.sh
#   TOKEN=abc123 ./test-curl.sh
# -----------------------------------------------------------------------------
set -euo pipefail

URL="${URL:-http://localhost:12001/alloy}"
TOKEN="${TOKEN:-$(kubectl -n argo-events get secret alloy-poc-webhook-token -o jsonpath='{.data.token}' | base64 -d)}"

NOW_NS=$(date +%s%N)

read -r -d '' BODY <<EOF || true
{
  "streams": [
    {
      "stream": {
        "source": "alloy-poc",
        "cluster": "proxmox-k8s",
        "severity": "info",
        "alertname": "AlloyPocSmokeTest"
      },
      "values": [
        ["${NOW_NS}", "hello from test-curl.sh — if you see this in workflow logs, the wire works"]
      ]
    }
  ]
}
EOF

echo ">>> POST ${URL}"
echo ">>> body:"
echo "${BODY}" | jq '.'

curl -sS -X POST "${URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${BODY}" \
  -w "\n>>> HTTP %{http_code} in %{time_total}s\n"

echo
echo ">>> latest alloy-poc workflows:"
kubectl -n argo-events get wf -l app.kubernetes.io/part-of=alloy-direct-poc \
  --sort-by=.metadata.creationTimestamp | tail -5
