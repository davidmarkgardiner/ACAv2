# K8sGPT + LiteLLM Setup for WSL

AI-powered Kubernetes troubleshooting using k8sgpt with LiteLLM as the unified AI gateway.

## Overview

This setup allows you to use **k8sgpt** for Kubernetes cluster analysis with **LiteLLM** as the AI backend proxy. LiteLLM provides a unified interface to 100+ LLM providers (OpenAI, Azure, Anthropic, Bedrock, local models, etc.) - meaning you can switch models without reconfiguring k8sgpt.

```
┌─────────────┐     ┌─────────────┐     ┌──────────────────┐
│   k8sgpt    │────▶│   LiteLLM   │────▶│  OpenAI/Azure/   │
│   (CLI)     │     │   (Proxy)   │     │  Anthropic/etc.  │
└─────────────┘     └─────────────┘     └──────────────────┘
```

## Prerequisites

- **WSL2** with Ubuntu 22.04+ (or native Linux)
- **kubectl** installed and configured with cluster access
- **LiteLLM** running (see [LiteLLM Setup](#litellm-setup) below)

## Quick Start

### 1. Run the Installation Script

```bash
# Download and run
curl -fsSL https://raw.githubusercontent.com/your-repo/install-k8sgpt.sh | bash

# Or clone and run locally
chmod +x install-k8sgpt.sh
./install-k8sgpt.sh
```

### 2. With Custom Options

```bash
# Install via .deb package (default, recommended for WSL)
./install-k8sgpt.sh \
  --version 0.4.26 \
  --litellm-url http://localhost:4000/v1 \
  --model claude-sonnet

# Install via Homebrew
./install-k8sgpt.sh --method brew
```

### 3. Manual Installation

**Option A: DEB Package (Recommended for WSL/Ubuntu)**

```bash
# Download and install
curl -LO https://github.com/k8sgpt-ai/k8sgpt/releases/download/v0.4.26/k8sgpt_amd64.deb
sudo dpkg -i k8sgpt_amd64.deb

# Verify
k8sgpt version
```

**Option B: Homebrew**

> ⚠️ On WSL/Linux, you must install `build-essential` first to avoid gcc errors.
> See: https://docs.k8sgpt.ai/getting-started/installation/#failing-installation-on-wsl-or-linux-missing-gcc

```bash
# WSL/Linux only: Install build-essential first
sudo apt-get update
sudo apt-get install build-essential

# Install via brew
brew tap k8sgpt-ai/k8sgpt
brew install k8sgpt

# Verify
k8sgpt version

# Upgrade later
brew upgrade k8sgpt
```

### 4. Configure LiteLLM Backend

```bash
# Configure LiteLLM backend
k8sgpt auth add --backend openai \
  --model gpt-4o \
  --baseurl http://localhost:4000/v1 \
  --password your-api-key  # or "not-required" for local

# Verify
k8sgpt auth list
```

## LiteLLM Setup

### Option A: Docker (Recommended)

```bash
# Quick start with environment variables
docker run -d \
  --name litellm \
  -p 4000:4000 \
  -e OPENAI_API_KEY=${OPENAI_API_KEY} \
  -e ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY} \
  -e AZURE_API_KEY=${AZURE_API_KEY} \
  ghcr.io/berriai/litellm:main-latest \
  --config /app/config.yaml
```

### Option B: Python/pip

```bash
pip install 'litellm[proxy]'
litellm --config litellm_config.yaml --port 4000
```

### Sample LiteLLM Configuration

Create `litellm_config.yaml`:

```yaml
model_list:
  # Azure OpenAI
  - model_name: gpt-4o
    litellm_params:
      model: azure/gpt-4o
      api_base: https://your-resource.openai.azure.com/
      api_key: os.environ/AZURE_OPENAI_API_KEY
      api_version: "2024-02-15-preview"

  # Anthropic Claude
  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-3-5-sonnet-20241022
      api_key: os.environ/ANTHROPIC_API_KEY

  # OpenAI Direct
  - model_name: gpt-4-turbo
    litellm_params:
      model: openai/gpt-4-turbo
      api_key: os.environ/OPENAI_API_KEY

  # Local Ollama
  - model_name: llama3
    litellm_params:
      model: ollama/llama3
      api_base: http://localhost:11434

  # AWS Bedrock
  - model_name: bedrock-claude
    litellm_params:
      model: bedrock/anthropic.claude-3-sonnet-20240229-v1:0
      aws_region_name: eu-west-1

litellm_settings:
  drop_params: true
  set_verbose: false

general_settings:
  master_key: sk-your-master-key  # Optional: protect your proxy
```

## Usage Examples

### Basic Analysis

```bash
# Scan entire cluster (no AI - just finds issues)
k8sgpt analyze

# Scan with AI explanations
k8sgpt analyze --explain

# Target specific namespace
k8sgpt analyze --namespace production --explain

# Filter by resource type
k8sgpt analyze --filter=Pod,Deployment,Service --explain

# Anonymous mode (masks sensitive data before sending to AI)
k8sgpt analyze --explain --anonymize
```

### Available Filters

```bash
# List all available analyzers
k8sgpt filters list

# Common filters:
# - Pod
# - Deployment  
# - Service
# - Ingress
# - StatefulSet
# - PersistentVolumeClaim
# - Node
# - CronJob
# - NetworkPolicy
```

### Working with Multiple Models

```bash
# Check current backend
k8sgpt auth list

# Switch to a different model
k8sgpt auth remove openai
k8sgpt auth add --backend openai \
  --model claude-sonnet \
  --baseurl http://localhost:4000/v1

# Use a specific backend for one-off analysis
k8sgpt analyze --explain --backend openai
```

### Integrations

```bash
# List available integrations
k8sgpt integration list

# Enable Trivy integration (vulnerability scanning)
k8sgpt integration activate trivy

# Enable Kyverno integration (policy violations)
k8sgpt integration activate kyverno

# Analyze with integrations
k8sgpt analyze --explain --filter=VulnerabilityReport
```

### Caching

```bash
# Analysis results are cached by default
# Clear cache
k8sgpt cache remove

# Disable cache for fresh analysis
k8sgpt analyze --explain --no-cache
```

## MCP Server Integration

K8sGPT can run as an MCP (Model Context Protocol) server for integration with Claude Desktop or other MCP clients:

```bash
# Start MCP server
k8sgpt serve --mcp --mcp-http --mcp-port 8089

# Full serve mode with gRPC and MCP
k8sgpt serve --mcp --mcp-http --port 8080 --metrics-port 8081 --mcp-port 8089
```

### Claude Desktop Configuration

Add to your Claude Desktop config (`~/.config/claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "k8sgpt": {
      "command": "k8sgpt",
      "args": ["serve", "--mcp", "--mcp-http", "--mcp-port", "8089"]
    }
  }
}
```

## Kubernetes Operator Mode

For continuous monitoring, deploy k8sgpt as a Kubernetes operator:

```bash
# Add Helm repo
helm repo add k8sgpt https://charts.k8sgpt.ai/
helm repo update

# Install operator
helm install k8sgpt k8sgpt/k8sgpt-operator \
  -n k8sgpt-operator-system \
  --create-namespace

# Create secret for AI backend
kubectl create secret generic k8sgpt-secret \
  --from-literal=api-key=your-litellm-key \
  -n k8sgpt-operator-system

# Apply K8sGPT custom resource
kubectl apply -f - <<EOF
apiVersion: core.k8sgpt.ai/v1alpha1
kind: K8sGPT
metadata:
  name: k8sgpt
  namespace: k8sgpt-operator-system
spec:
  ai:
    enabled: true
    model: gpt-4o
    backend: openai
    baseUrl: http://litellm-service:4000/v1
    secret:
      name: k8sgpt-secret
      key: api-key
  noCache: false
EOF

# View results
kubectl get results -n k8sgpt-operator-system
```

## Configuration File

K8sGPT stores configuration in `~/.config/k8sgpt/k8sgpt.yaml`:

```yaml
ai:
  providers:
    - name: openai
      model: gpt-4o
      password: your-api-key
      baseurl: http://localhost:4000/v1
      maxtokens: 2048
      topp: 0.5
      temperature: 0.7
  defaultprovider: openai
```

## Troubleshooting

### k8sgpt can't connect to cluster

```bash
# Check kubectl context
kubectl config current-context
kubectl get nodes

# Verify kubeconfig
echo $KUBECONFIG
```

### LiteLLM connection issues

```bash
# Test LiteLLM endpoint
curl http://localhost:4000/v1/models

# Check if LiteLLM is running
docker ps | grep litellm

# View LiteLLM logs
docker logs litellm
```

### No issues found but cluster has problems

```bash
# List active filters
k8sgpt filters list

# Enable all filters
k8sgpt filters add --all

# Run with verbose output
k8sgpt analyze --explain -v
```

### Reconfigure backend

```bash
# Remove and re-add
k8sgpt auth remove openai
k8sgpt auth add --backend openai \
  --model gpt-4o \
  --baseurl http://localhost:4000/v1
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `K8SGPT_VERSION` | Version to install | `0.4.26` |
| `LITELLM_URL` | LiteLLM proxy URL | `http://localhost:4000/v1` |
| `LITELLM_MODEL` | Default model name | `gpt-4o` |
| `KUBECONFIG` | Path to kubeconfig | `~/.kube/config` |

## Security Considerations

- Use `--anonymize` flag to mask pod names, labels, and other sensitive data before sending to external AI providers
- For production, consider running LiteLLM and k8sgpt within your cluster
- LiteLLM supports virtual keys for access control and rate limiting
- k8sgpt stores API keys in plaintext in `~/.config/k8sgpt/k8sgpt.yaml`

## Useful Links

- [k8sgpt Documentation](https://docs.k8sgpt.ai/)
- [k8sgpt GitHub](https://github.com/k8sgpt-ai/k8sgpt)
- [LiteLLM Documentation](https://docs.litellm.ai/)
- [LiteLLM GitHub](https://github.com/BerriAI/litellm)
- [k8sgpt Operator](https://github.com/k8sgpt-ai/k8sgpt-operator)

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2025-01-06 | Initial release |

---

*Built for enterprise Kubernetes environments. Questions? Raise an issue or PR.*