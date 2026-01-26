#!/bin/bash
# Deploy Argo Events using Helm

set -e

echo "Installing Argo Events..."
helm upgrade --install argo-events argo/argo-events \
  --namespace argo-events \
  --create-namespace \
  --wait

echo ""
echo "Creating EventBus..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  jetstream:
    version: "2.9.8"
    replicas: 1
    settings: |
      max_memory_store: 256Mi
      max_file_store: 1Gi
EOF

echo ""
echo "Waiting for EventBus to be ready..."
kubectl wait --for=condition=ready eventbus/default -n argo-events --timeout=120s

echo ""
echo "Argo Events installed successfully!"
