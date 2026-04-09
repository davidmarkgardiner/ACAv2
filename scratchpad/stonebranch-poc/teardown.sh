#!/bin/bash
set -euo pipefail

CONTEXT="${1:-proxmox-k8s}"

echo "=== Tearing down Stonebranch UAG POC from context: ${CONTEXT} ==="
kubectl --context "${CONTEXT}" delete namespace stonebranch --ignore-not-found
echo "=== Done ==="
