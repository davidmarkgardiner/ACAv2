# Stonebranch Universal Agent Gateway (UAG) — Kubernetes POC

## Overview

POC deployment of Stonebranch Universal Agent 8.0 on Kubernetes. Deploys an OMS (message service) and UAG agents as standalone pods.

**Tested on**: proxmox-k8s (3 nodes, K8s v1.31.14, containerd)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (stonebranch namespace)                     │
│                                                                 │
│  ┌────────────────────────┐    ┌─────────────────────────────┐  │
│  │  OMS Server (1 pod)    │    │  UAG Agents (2 pods)        │  │
│  │                        │    │                             │  │
│  │  Port 7878: OMS (TLS)  │◄───│  Agent 1: UAG-PROXMOX-xxxx │  │
│  │  Port 7887: UBroker    │◄───│  Agent 2: UAG-PROXMOX-yyyy │  │
│  │                        │    │                             │  │
│  │  Service: ClusterIP    │    │  Connect via:               │  │
│  │  oms-server:7878       │    │  7878@oms-server.stonebranch│  │
│  └────────────────────────┘    │  .svc.cluster.local         │  │
│                                └─────────────────────────────┘  │
│                                                                 │
│  Optional: Universal Controller connects to OMS:7878            │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
cd stonebranch-poc

# Deploy (default context: proxmox-k8s)
./deploy.sh

# Deploy to a different cluster
./deploy.sh my-cluster-context

# Verify agents connected to OMS
kubectl --context proxmox-k8s -n stonebranch logs deploy/uag-agent -c uag \
  | grep "Transport connected"

# Expected output:
# Transport connected successfully for queue [UAG-PROXMOX-xxxxx]

# Teardown
./teardown.sh
```

## Image Details

| Field | Value |
|-------|-------|
| Image | `stonebranch/universal-agent:8.0.0.0-debian` |
| Source | https://hub.docker.com/r/stonebranch/universal-agent |
| Size | ~600MB (first pull takes ~25s) |
| Base | Debian |
| Arch | amd64 only |
| Docs | https://stonebranchdocs.atlassian.net/wiki/spaces/UA80/pages/2981462029/Container+Operations |

### Available Tags

| Tag | Notes |
|-----|-------|
| `latest` / `8.0.0.0` | Latest GA, RHEL-based |
| `8.0.0.0-debian` | Latest GA, Debian-based (used in this POC) |
| `7.9-latest` / `7.9.2.2` | Previous major |
| `7.8-latest` / `7.8.3.3` | Older stable |

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| **7878** | TCP (TLS) | OMS — Universal Message Service |
| **7887** | TCP | UBroker — Universal Broker |

## Files

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | Namespace `stonebranch` |
| `01-configmap.yaml` | Reference ConfigMap (see critical note below) |
| `02-oms-server.yaml` | OMS Deployment + Service with init container |
| `03-uag-agent.yaml` | UAG Agent Deployment + Service with init container |
| `04-networkpolicy.yaml` | Network policies (agent ↔ OMS only) |
| `05-external-oms-service.yaml` | Cross-cluster OMS connectivity templates (commented) |
| `06-istio-gateway.yaml` | Istio Gateway + VirtualService for OMS (AKS add-on) |
| `deploy.sh` | Deploy everything (OMS + agents, same cluster) |
| `deploy-central-oms.sh` | Deploy OMS only (management cluster) |
| `deploy-remote-agents.sh` | Deploy agents only (worker clusters, remote OMS) |
| `teardown.sh` | Clean removal (`./teardown.sh <context>`) |
| `TEST-RESULTS.md` | Capability test results |

## Critical: Environment Variables Do NOT Work

**The Stonebranch container ignores most environment variables.** The entrypoint does not patch config files from env vars. This is the #1 gotcha.

### What doesn't work

```yaml
# ❌ These env vars are IGNORED by the container
env:
- name: UAG_OMS_SERVERS
  value: "7878@oms-server"      # Agent still connects to localhost:7878
- name: OMS_AUTOSTART
  value: "yes"                   # OMS component stays auto_start=no
- name: UAG_NETNAME
  value: "MY-AGENT"              # Agent name stays OPSAUTOCONF
```

### What works: Init containers that patch config files

```yaml
# ✅ Use init containers to sed-patch the actual config files
initContainers:
- name: patch-config
  image: stonebranch/universal-agent:8.0.0.0-debian
  command: ["sh", "-c"]
  args:
  - |
    cp -a /etc/universal/* /config/
    sed -i 's|^oms_servers.*|oms_servers 7878@oms-server.stonebranch.svc.cluster.local|' /config/uags.conf
    sed -i 's/^auto_start.*no/auto_start            yes/' /config/comp/oms
  volumeMounts:
  - name: universal-config
    mountPath: /config
containers:
- name: uag
  image: stonebranch/universal-agent:8.0.0.0-debian
  volumeMounts:
  - name: universal-config
    mountPath: /etc/universal    # Overlays the patched config
volumes:
- name: universal-config
  emptyDir: {}
```

### Config files that matter

| File | What to patch | Default | Notes |
|------|--------------|---------|-------|
| `/etc/universal/uags.conf` | `oms_servers` | `7878@localhost` | Set to OMS service FQDN |
| `/etc/universal/uags.conf` | `netname` | `OPSAUTOCONF` | Unique agent name |
| `/etc/universal/comp/oms` | `auto_start` | `no` | Set to `yes` on OMS pod |
| `/etc/universal/ubroker.conf` | `service_port` | `7887` | UBroker listen port |
| `/etc/universal/omss.conf` | `service_port` | `7878` | OMS listen port |

## Customization

### Change OMS address (for remote OMS)

Edit `03-uag-agent.yaml`, init container args:
```bash
sed -i 's|^oms_servers.*|oms_servers 7878@your-oms-host.example.com|' /config/uags.conf
```

### Change agent naming convention

Edit `03-uag-agent.yaml`, init container args:
```bash
# Current: UAG-PROXMOX-<last 5 chars of hostname>
sed -i "s|^netname.*|netname UAG-MYTEAM-$(hostname | tail -c 6)|" /config/uags.conf
```

### Scale agents

```bash
kubectl --context proxmox-k8s -n stonebranch scale deployment/uag-agent --replicas=5
```

### Enable TLS for UBroker (production)

Add to the init container for both OMS and agent:
```bash
echo "require_ssl yes" >> /config/ubroker.conf
```

## Split Deployment: Central OMS + Remote Agents

For production, run OMS on a management cluster and agents on worker clusters.

```
┌──────────────────────────────┐     ┌──────────────────────────────┐
│  Management Cluster          │     │  Worker Cluster 1            │
│                              │     │                              │
│  OMS Server (port 7878 TLS)  │◄────│  UAG Agent ×N                │
│  Exposed via:                │     │  oms_servers: 7878@10.0.1.50 │
│    Internal LB: 10.0.1.50   │     └──────────────────────────────┘
│    or NodePort: :30878       │
│    or Istio Gateway          │     ┌──────────────────────────────┐
│                              │◄────│  Worker Cluster 2            │
│                              │     │  UAG Agent ×N                │
└──────────────────────────────┘     └──────────────────────────────┘
```

### Deploy central OMS

```bash
# ClusterIP only (same-cluster agents)
./deploy-central-oms.sh proxmox-k8s

# NodePort for cross-cluster dev/testing
./deploy-central-oms.sh aks-mgmt nodeport

# Internal LoadBalancer for production
./deploy-central-oms.sh aks-mgmt loadbalancer
```

### Deploy remote agents

```bash
# Basic: 2 agents connecting to OMS at 10.0.1.100
./deploy-remote-agents.sh aks-worker1 10.0.1.100

# Custom: 3 agents with prefix, connecting to DNS name
./deploy-remote-agents.sh aks-worker1 oms.mgmt.internal 3 WORKER1

# Another cluster
./deploy-remote-agents.sh aks-worker2 oms.mgmt.internal 2 WORKER2
```

### Expose methods

| Method | Script arg | Use when | Command |
|--------|-----------|----------|---------|
| ClusterIP | `clusterip` | Same-cluster agents | `./deploy-central-oms.sh ctx` |
| NodePort | `nodeport` | Dev/testing cross-cluster | `./deploy-central-oms.sh ctx nodeport` |
| Internal LB | `loadbalancer` | Production (Azure/AWS/GCP) | `./deploy-central-oms.sh ctx loadbalancer` |
| Istio Gateway | manual | AKS with Istio add-on | See Istio section below |

### Istio Gateway (AKS Istio Add-on)

If your AKS cluster uses the Istio add-on, expose OMS via a TCP Gateway. OMS uses raw TCP with TLS (not HTTP), so you need `protocol: TCP` or `protocol: TLS` with passthrough:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: oms-gateway
  namespace: stonebranch
spec:
  selector:
    istio: aks-istio-ingressgateway-external   # AKS Istio add-on label
    # or: istio: aks-istio-ingressgateway-internal  (for internal only)
  servers:
  - port:
      number: 7878
      name: tcp-oms
      protocol: TLS
    tls:
      mode: PASSTHROUGH    # OMS handles its own TLS 1.2
    hosts:
    - "oms.your-domain.com"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: oms-vs
  namespace: stonebranch
spec:
  hosts:
  - "oms.your-domain.com"
  gateways:
  - oms-gateway
  tls:
  - match:
    - port: 7878
      sniHosts:
      - "oms.your-domain.com"
    route:
    - destination:
        host: oms-server.stonebranch.svc.cluster.local
        port:
          number: 7878
```

**Important**: The AKS Istio add-on ingress gateway needs the port opened. By default only 80/443 are open. You may need to configure the gateway's `Service` to add port 7878, or use port 443 with SNI routing.

Alternative (simpler): skip Istio for OMS and use a plain `LoadBalancer` Service — Istio adds complexity for raw TCP that doesn't benefit from HTTP-level features.

## Cross-Cluster OMS (Low-Level Patterns)

See `05-external-oms-service.yaml` for Kubernetes-native templates (no scripts):

| Pattern | Use when | Pros | Cons |
|---------|----------|------|------|
| **ExternalName** | OMS has DNS name | Simple | Needs cross-cluster DNS |
| **Headless + Endpoints** | VNet peered clusters | Works with IPs | Manual IP management |
| **NodePort** | Testing / dev | Easy | Exposes ports on nodes |

### Critical networking requirements

- OMS uses **persistent TCP connections** — set LB/proxy idle timeouts > agent heartbeat interval
- AKS Application Gateway (AGIC) does **NOT support TLS passthrough** — use NGINX, HAProxy, or Istio
- Istio Gateway works with `protocol: TLS` + `mode: PASSTHROUGH`
- Agent → OMS connection uses TLS 1.2 by default (self-signed certs)

## Known Behaviors (Not Bugs)

### UBroker negotiation errors (`ASYReceiveNegotiationEH`)

```
UNV3352E Network error on client session 192.168.6.5:37156: ASYReceiveNegotiationEH
```

**This is expected** when running without a Universal Controller. The UBroker on each pod attempts broker-to-broker discovery connections. Without a UC managing the mesh, these fail harmlessly. The agent → OMS data path (port 7878) works fine.

### Agent shows `OPSAUTOCONF` in some logs

The UAG component name vs. the netname can differ. If you see `OPSAUTOCONF` in early startup logs, that's the default before the patched config is fully loaded. The agent ultimately registers with the correct name (check `Agent ID:` line in logs).

## Troubleshooting

### OMS pod not ready (readiness probe failing on 7878)

**Cause**: OMS component `auto_start` is `no` in `/etc/universal/comp/oms`.  
**Fix**: Verify the init container patches it. Check:
```bash
kubectl --context proxmox-k8s -n stonebranch logs deploy/oms-server -c enable-oms-autostart
# Should show: auto_start            yes
```

### Agent connects to localhost instead of OMS service

**Cause**: Default `uags.conf` has `oms_servers 7878@localhost`.  
**Fix**: Verify init container patches it:
```bash
kubectl --context proxmox-k8s -n stonebranch logs deploy/uag-agent -c patch-agent-config
# Should show: oms_servers 7878@oms-server.stonebranch.svc.cluster.local
```

### Image pull slow or fails

Image is ~600MB. First pull takes ~25s on a decent connection. If it times out:
```bash
# Pre-pull on all nodes
kubectl --context proxmox-k8s get nodes -o name | while read node; do
  kubectl --context proxmox-k8s debug $node -it --image=stonebranch/universal-agent:8.0.0.0-debian -- echo "pulled"
done
```

## Available CLI Tools

Located in `/opt/universal/bin/` inside the container:

| Tool | Purpose |
|------|---------|
| `uctl` | Universal Control — manage broker components |
| `ucmd` | Universal Command — remote command execution |
| `udm` | Universal Data Mover — file transfers |
| `uquery` | Query agent/broker status |
| `ucert` | Certificate management |

Example:
```bash
kubectl --context proxmox-k8s -n stonebranch exec deploy/uag-agent -c uag -- \
  /opt/universal/bin/uquery -host localhost
```

## Deployment Sequence

```
deploy.sh
├── [1] Create namespace
├── [2] Apply ConfigMap (reference)
├── [3] Deploy OMS server
│   ├── Init: copy /etc/universal → emptyDir, sed auto_start=yes
│   └── Main: OMS starts, listens on 7878 (TLS) + 7887
├── [4] Deploy UAG agents
│   ├── Init: copy /etc/universal → emptyDir, sed oms_servers + netname
│   └── Main: Agent connects to OMS via TLS 1.2
└── [5] Apply network policies
```
