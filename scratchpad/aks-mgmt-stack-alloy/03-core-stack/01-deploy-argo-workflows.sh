#!/bin/bash
# Deploy Argo Workflows using Helm

set -e

echo "Adding Argo Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo ""
echo "Installing Argo Workflows..."
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo \
  --create-namespace \
  --set server.serviceType=ClusterIP \
  --set workflow.serviceAccount.create=true \
  --set controller.metricsConfig.enabled=true \
  --set server.authMode=server \
  --wait

echo ""
echo "Argo Workflows installed successfully!"
echo ""
echo "To access the UI:"
echo "  kubectl port-forward -n argo svc/argo-workflows-server 2746:2746"
echo "  Open: http://localhost:2746"
