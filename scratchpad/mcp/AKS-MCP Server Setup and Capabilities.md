# AKS-MCP Server Setup and Capabilities

A comprehensive guide to setting up and using the AKS Model Context Protocol (MCP) server for AI-assisted Kubernetes operations.

## Overview

The AKS-MCP server acts as a bridge between AI assistants (Claude, GitHub Copilot, Cursor) and Azure Kubernetes Service clusters. It translates natural language requests into AKS operations and returns results in a format AI tools can understand.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   AI Assistant  │────▶│   AKS-MCP       │────▶│   Azure/AKS     │
│  (Claude, etc.) │◀────│   Server        │◀────│   Resources     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                              │
                              ▼
                        ┌─────────────────┐
                        │  Azure CLI      │
                        │  kubectl        │
                        │  helm/cilium    │
                        └─────────────────┘
```

## Installation Options

### Option 1: Docker MCP Toolkit (Recommended)

1. Open **Docker Desktop**
2. Click **MCP Toolkit** in the left sidebar
3. Go to **Catalog** tab → Search for **"aks"**
4. Click **"+"** to enable

#### Configuration (macOS)

| Setting | Value | Description |
|---------|-------|-------------|
| `azure_dir` | `/Users/<username>/.azure` | Azure CLI config directory (absolute path) |
| `kubeconfig` | `/Users/<username>/.kube/config` | Kubeconfig file path (absolute path) |
| `access_level` | `readonly` | One of: `readonly`, `readwrite`, `admin` |
| `allow_namespaces` | *(empty)* | Comma-separated list, empty = all |
| `additional_tools` | `helm,cilium` | Optional: `helm`, `cilium` |
| `container_user` | *(empty)* | Leave empty on macOS |

#### Configuration (Linux)

Same as macOS, but set `container_user` to your UID:

```bash
id -u  # Use this value for container_user
```

### Option 2: VS Code Extension

Requires AKS VS Code Extension v1.6.12+:

1. Install **Azure Kubernetes Service** extension
2. Command Palette → **"AKS: Setup AKS MCP Server"**
3. Extension auto-configures everything

### Option 3: Manual Binary

```bash
# Download binary (macOS ARM64)
curl -sL https://github.com/Azure/aks-mcp/releases/latest/download/aks-mcp-darwin-arm64 -o ~/aks-mcp
chmod +x ~/aks-mcp

# Create MCP config
mkdir -p .vscode
cat > .vscode/mcp.json << 'EOF'
{
  "servers": {
    "aks-mcp": {
      "type": "stdio",
      "command": "/Users/<username>/aks-mcp",
      "args": ["--transport", "stdio", "--access-level", "readonly"]
    }
  }
}
EOF
```

### Option 4: Docker Container (Manual)

```json
{
  "mcpServers": {
    "aks": {
      "type": "stdio",
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-v", "~/.azure:/home/mcp/.azure",
        "-v", "~/.kube:/home/mcp/.kube",
        "ghcr.io/azure/aks-mcp:latest",
        "--transport", "stdio"
      ]
    }
  }
}
```

## Prerequisites

```bash
# Ensure Azure CLI is installed and logged in
az login
az account set --subscription "<subscription-id>"

# Verify authentication
az account show --query "[name, id]" -o tsv

# Ensure kubeconfig exists
ls -la ~/.kube/config
```

## Available Tools

### Cluster Management (`az_aks_operations`)

| Operation | Access Level | Description |
|-----------|--------------|-------------|
| `show` | readonly | Show cluster details |
| `list` | readonly | List clusters in subscription |
| `get-versions` | readonly | Get available K8s versions |
| `check-network` | readonly | Outbound connectivity check |
| `nodepool-list` | readonly | List node pools |
| `nodepool-show` | readonly | Show node pool details |
| `create` | readwrite | Create cluster |
| `delete` | readwrite | Delete cluster |
| `scale` | readwrite | Scale node count |
| `start/stop` | readwrite | Start/stop cluster |
| `upgrade` | readwrite | Upgrade K8s version |
| `get-credentials` | admin | Get kubectl credentials |

### Network Resources (`az_network_resources`)

- `vnet` - Virtual Network info
- `subnet` - Subnet info
- `nsg` - Network Security Groups
- `route_table` - Route Tables
- `load_balancer` - Load Balancers
- `private_endpoint` - Private Endpoints
- `all` - All network resources

### Monitoring & Diagnostics (`az_monitoring`)

| Operation | Description |
|-----------|-------------|
| `metrics` | Query Azure Monitor metrics (CPU, memory, network) |
| `resource_health` | Get resource health events |
| `app_insights` | Execute KQL queries against App Insights |
| `diagnostics` | Check diagnostic settings |
| `control_plane_logs` | Query control plane logs |

**Control Plane Log Categories:**
- `kube-apiserver`
- `kube-audit` / `kube-audit-admin`
- `kube-controller-manager`
- `kube-scheduler`
- `cluster-autoscaler`
- `cloud-controller-manager`
- `guard` (auth issues)
- `csi-azuredisk-controller`
- `csi-azurefile-controller`

### Kubernetes Tools (`kubectl_*`)

| Tool | Operations |
|------|------------|
| `kubectl_resources` | get, describe (readonly) / create, delete, apply, patch (readwrite) |
| `kubectl_diagnostics` | logs, events, top, exec, cp |
| `kubectl_cluster` | cluster-info, api-resources, api-versions, explain |
| `kubectl_config` | auth, config contexts |

### Fleet Management (`az_fleet`)

For multi-cluster scenarios:
- Fleet: list, show, create, update, delete, get-credentials
- Members: list, show, create, update, delete
- Update Runs: list, show, create, start, stop, delete
- ClusterResourcePlacement: list, show, create, delete

### Real-time Observability (`inspektor_gadget_observability`)

eBPF-based live tracing:

| Gadget | Description |
|--------|-------------|
| `observe_dns` | Monitor DNS requests/responses |
| `observe_tcp` | Monitor TCP connections |
| `observe_file_open` | Monitor file operations |
| `observe_process_execution` | Monitor process execution |
| `observe_signal` | Monitor signal delivery |
| `observe_system_calls` | Monitor syscalls |
| `top_file` | Top files by I/O |
| `top_tcp` | Top TCP connections |
| `tcpdump` | Packet capture |

### Diagnostic Detectors

Categories:
- Best Practices
- Cluster and Control Plane Availability and Performance
- Connectivity Issues
- Create/Upgrade/Delete and Scale
- Deprecations
- Identity and Security
- Node Health
- Storage

## Access Levels

| Level | Capabilities |
|-------|--------------|
| `readonly` | View cluster info, logs, events, metrics - no changes |
| `readwrite` | Above + scale, restart, apply, cordon, drain |
| `admin` | Above + get cluster credentials |

## Authentication

AKS-MCP uses Azure CLI authentication in this order:

1. **Service Principal** - `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`
2. **Workload Identity** - `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`
3. **User-assigned Managed Identity** - `AZURE_CLIENT_ID` only
4. **System-assigned Managed Identity** - `AZURE_MANAGED_IDENTITY=system`
5. **Existing Login** - Falls back to existing `az login` session

## Example Prompts

### Cluster Information
```
List all my AKS clusters in subscription <sub-id>
Show me the health of cluster <name> in resource group <rg>
What Kubernetes versions are available for upgrade?
```

### Troubleshooting
```
Why is my node in NotReady state?
Check the control plane logs for the last hour
Show me events in namespace <namespace>
Get logs from pod <pod-name> in namespace <ns>
```

### Network Analysis
```
Show me the VNet and NSG configuration for my cluster
Is DNS traffic being blocked?
What are the route tables for this cluster?
```

### Diagnostics
```
Run the connectivity diagnostics on my cluster
Check for any Azure Advisor recommendations
What's the CPU and memory usage over the last 6 hours?
```

### Real-time Debugging
```
Deploy Inspektor Gadget and watch DNS traffic
Monitor TCP connections in namespace <ns>
Trace file operations for pod <pod>
```

## Telemetry

Telemetry is enabled by default. To opt out:

```bash
export AKS_MCP_COLLECT_TELEMETRY=false
```

## Limitations

- **Request/Response Only** - No persistent watching or background monitoring
- **No Autonomous Actions** - Only acts when explicitly asked
- **No Alerting** - Cannot trigger on events automatically
- **Time-bound Queries** - Control plane logs limited to last 30 days

## Resources

- [GitHub Repository](https://github.com/Azure/aks-mcp)
- [AKS Engineering Blog Announcement](https://blog.aks.azure.com/2025/08/06/aks-mcp-server)
- [Docker Hub MCP Catalog](https://hub.docker.com/mcp/server/aks/overview)
- [Azure MCP Server Docs](https://learn.microsoft.com/en-us/azure/developer/azure-mcp-server/tools/azure-kubernetes)