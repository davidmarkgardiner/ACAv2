#!/bin/bash
# Install Argo Events on Management Cluster

set -euo pipefail

echo "Installing Argo Events..."

# Create namespace if not exists
kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -

# Install Argo Events
kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml

# Install validating webhook (optional but recommended)
kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install-validating-webhook.yaml

# Wait for controller to be ready
echo "Waiting for Argo Events controller..."
kubectl wait --for=condition=available --timeout=120s deployment/controller-manager -n argo-events

echo "Argo Events installed successfully!"

# Install Argo Workflows (for running triage workflows)
echo "Installing Argo Workflows..."
kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.5.5/install.yaml

echo "Waiting for Argo Workflows controller..."
kubectl wait --for=condition=available --timeout=120s deployment/workflow-controller -n argo

echo "Argo Workflows installed successfully!"
