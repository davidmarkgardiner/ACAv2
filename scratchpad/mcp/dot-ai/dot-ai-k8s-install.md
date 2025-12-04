This is exactly what you need. Here's the simplified setup:

## dot-ai on Kubernetes - Quick Setup

### Step 1: Set Your API Keys

```bash
export ANTHROPIC_API_KEY="sk-ant-api03-..."
export OPENAI_API_KEY="sk-proj-..."
```

### Step 2: Install the Controller (Optional - for Solution CR tracking)

```bash
# Get latest version from: https://github.com/vfarcic/dot-ai-controller/pkgs/container/dot-ai-controller%2Fcharts%2Fdot-ai-controller
export DOT_AI_CONTROLLER_VERSION="0.1.0"  # Check for latest

helm install dot-ai-controller \
  oci://ghcr.io/vfarcic/dot-ai-controller/charts/dot-ai-controller:$DOT_AI_CONTROLLER_VERSION \
  --namespace dot-ai \
  --create-namespace \
  --wait
```

### Step 3: Install the MCP Server

```bash
# Get latest version from: https://github.com/vfarcic/dot-ai/pkgs/container/dot-ai%2Fcharts%2Fdot-ai
export DOT_AI_VERSION="0.1.0"  # Check for latest

helm install dot-ai-mcp oci://ghcr.io/vfarcic/dot-ai/charts/dot-ai:$DOT_AI_VERSION \
  --set secrets.anthropic.apiKey="$ANTHROPIC_API_KEY" \
  --set secrets.openai.apiKey="$OPENAI_API_KEY" \
  --set ingress.enabled=true \
  --set ingress.host="dot-ai.your-cluster.example.com" \
  --set controller.enabled=true \
  --namespace dot-ai \
  --wait
```

### Step 4: Configure Your MCP Client

Create `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "dot-ai": {
      "type": "http",
      "url": "http://dot-ai.your-cluster.example.com"
    }
  }
}
```

### Step 5: Test It

In Claude Code or your MCP client:
```
Show dot-ai status
```

---

## What You Get

| Feature | Description |
|---------|-------------|
| **HTTP Transport** | Remote access via SSE for any MCP client |
| **Qdrant Vector DB** | Included for patterns/policies/capabilities |
| **RBAC** | ServiceAccount with cluster access |
| **Ingress** | External access for team sharing |
| **Solution CRs** | Track deployment lifecycle (with controller) |

---

## For Your AKS Setup

Given your Istio mesh, you'd adjust the ingress:

```bash
helm install dot-ai-mcp oci://ghcr.io/vfarcic/dot-ai/charts/dot-ai:$DOT_AI_VERSION \
  --set secrets.anthropic.apiKey="$ANTHROPIC_API_KEY" \
  --set secrets.openai.apiKey="$OPENAI_API_KEY" \
  --set ingress.enabled=true \
  --set ingress.host="dot-ai.internal.xxx.com" \
  --set ingress.annotations."kubernetes\.io/ingress\.class"=istio \
  --set controller.enabled=true \
  --namespace dot-ai \
  --wait
```

Or create a VirtualService instead of Ingress if you prefer native Istio routing.

---

Want me to update the auto-healer README to reference this official Helm deployment, or create a values.yaml tailored to your AKS/Istio setup?

---

To connect VS Code to your Kubernetes-deployed dot-ai MCP server:

## Option 1: Project-Level Config (Recommended)

Create `.vscode/mcp.json` in your project root:

```json
{
  "servers": {
    "dot-ai": {
      "type": "http",
      "url": "http://dot-ai.your-cluster.example.com"
    }
  }
}
```

## Option 2: User-Level Config (All Projects)

Add to your VS Code User Settings JSON (`Cmd+,` → Open Settings JSON):

```json
{
  "github.copilot.chat.mcp.servers": {
    "dot-ai": {
      "type": "http",
      "url": "http://dot-ai.your-cluster.example.com"
    }
  }
}
```

---

## If Using Port-Forward (Local Dev)

If you haven't set up ingress yet, port-forward first:

```bash
kubectl port-forward svc/dot-ai-mcp -n dot-ai 3000:3000
```

Then your config becomes:

```json
{
  "servers": {
    "dot-ai": {
      "type": "http",
      "url": "http://localhost:3000"
    }
  }
}
```

---

## Verify Connection

1. Restart VS Code (or reload window: `Cmd+Shift+P` → "Developer: Reload Window")
2. Open Command Palette → **"MCP: List Servers"**
3. You should see **dot-ai** listed
4. Open GitHub Copilot Chat → Switch to **Agent mode**
5. Click **Tools** to confirm dot-ai tools are available

## Test It

Ask Copilot:

```
Show dot-ai status
```

or

```
What pods are failing in my cluster?
```

---

## Combining with AKS-MCP

You can run **both** MCP servers simultaneously - they complement each other:

```json
{
  "servers": {
    "aks-mcp": {
      "type": "stdio",
      "command": "/path/to/aks-mcp",
      "args": ["--transport", "stdio", "--access-level", "readonly"]
    },
    "dot-ai": {
      "type": "http",
      "url": "http://dot-ai.your-cluster.example.com"
    }
  }
}
```

| Server | Best For |
|--------|----------|
| **AKS-MCP** | Azure-specific operations, metrics, control plane logs, Fleet management |
| **dot-ai** | AI-powered remediation, deployment recommendations, organisational patterns |

---

Does your cluster have ingress set up, or do you want to test with port-forward first?