# KubeVirt Proof of Concept

> **Status:** ✅ Complete — 29 Jan 2026
> **Cluster:** proxmox-k8s (`kubectl config use-context proxmox-k8s`)
> **Location:** Proxmox VE @ x168

## Overview

KubeVirt lets you run traditional VMs as Kubernetes workloads alongside containers. This PoC demonstrates a fully working setup on a 3-node cluster running on Proxmox VE.

```
┌───────────────────────────────────────────────────────────┐
│                  Proxmox VE 8.4.16                        │
│          i7-12700KF · 64GB RAM · 430GB Storage            │
│                                                           │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │  k8s-cp1     │  │ k8s-worker1  │  │ k8s-worker2  │     │
│  │ x168.x4  │  │ x168.x5  │  │ x168.x6  │     │
│  │ control-plane│  │  4c / 8GB    │  │  4c / 8GB    │     │
│  │  4c / 8GB    │  │              │  │              │     │
│  └─────────────┘  └──────┬───────┘  └──────┬───────┘     │
│                          │                  │             │
│              ┌───────────┴──────────────────┘             │
│              │  KubeVirt v1.7.0 + CDI v1.64.0             │
│              │                                            │
│         ┌────┴─────┐    ┌──────────┐                      │
│         │ubuntu-poc│    │nginx-test│  (pod)                │
│         │  VM      │───▶│  pod     │  hybrid networking    │
│         │ 2c/2GB   │    └──────────┘                      │
│         └──────────┘                                      │
└───────────────────────────────────────────────────────────┘
```

## Infrastructure

### Proxmox VMs

| VMID | Name | Role | vCPU | RAM | IP | Status |
|------|------|------|------|-----|-----|--------|
| 9000 | ubuntu-cloud-template | Template | 2 | 2GB | — | Template |
| 200 | k8s-cp1 | Control Plane | 4 | 8GB | x168.x4 | ✅ Running |
| 101 | k8s-worker1 | Worker | 4 | 8GB | x168.x5 | ✅ Running |
| 102 | k8s-worker2 | Worker | 4 | 8GB | x168.x6 | ✅ Running |

### Kubernetes Stack

| Component | Version | Notes |
|-----------|---------|-------|
| Kubernetes | v1.31.14 | kubeadm, 3 nodes |
| KubeVirt | v1.7.0 | VM management |
| CDI | v1.64.0 | Containerized Data Importer |
| Calico | v3.28.0 | CNI |
| local-path-provisioner | Rancher | Default StorageClass |

## KubeVirt VMs

### Ubuntu PoC VM

- **Name:** `ubuntu-poc` in namespace `kubevirt-poc`
- **Image:** Ubuntu Noble 24.04 (cloud image via CDI DataVolume)
- **Specs:** 2 vCPUs, 2GB RAM, 10GB persistent disk
- **User:** `david` (SSH key auth)
- **SSH:** `ssh -p 30022 david@x168.x6`

### Windows Template (not deployed)

A ready-to-use Windows Server template is available at:
`projects/kubevirt-poc/manifests/windows-vm-template.yaml`

Includes Hyper-V enlightenments, virtio drivers, tablet input, TPM.

## Quick Commands

### VM Lifecycle
```bash
# Start / Stop / Restart
virtctl --context proxmox-k8s start ubuntu-poc -n kubevirt-poc
virtctl --context proxmox-k8s stop ubuntu-poc -n kubevirt-poc
virtctl --context proxmox-k8s restart ubuntu-poc -n kubevirt-poc

# Console (serial)
virtctl --context proxmox-k8s console ubuntu-poc -n kubevirt-poc
# Exit: Ctrl+]

# VNC (graphical)
virtctl --context proxmox-k8s vnc ubuntu-poc -n kubevirt-poc
```

### Status
```bash
kubectl --context proxmox-k8s get vm,vmi -n kubevirt-poc
kubectl --context proxmox-k8s get all -n kubevirt-poc
```

### SSH
```bash
ssh -p 30022 david@x168.x5  # any worker node IP
ssh -p 30022 david@x168.x6
```

### Proxmox Node SSH
```bash
ssh david@x168.x4  # control plane
ssh david@x168.x5  # worker1
ssh david@x168.x6  # worker2
```

## All VMs Running

| VM | Type | Access | Node |
|----|------|--------|------|
| ubuntu-poc | Ubuntu 24.04 (CDI) | `ssh -p 30022 david@x168.x5` | worker2 |
| fedora-vm | Fedora (containerDisk) | `ssh -p 30023 david@x168.x5` | worker1 |
| cirros-vm | CirrOS (containerDisk) | `virtctl console cirros-vm -n kubevirt-poc` | worker1 |
| postgres-vm | Ubuntu + PostgreSQL (CDI) | Adminer: `http://x168.x5:30080` | worker1 |
| migration-test | Ubuntu (Longhorn RWX) | Live migration proven ✅ | worker1 |

## Storage

| StorageClass | Provisioner | Default | Live Migration |
|-------------|-------------|---------|----------------|
| **longhorn** | driver.longhorn.io | ✅ Yes | ✅ RWX supported |
| local-path | rancher.io/local-path | No | ❌ RWO only |

**Longhorn UI:** `http://x168.x4:30081`

## What Was Proven

| Feature | Status | Notes |
|---------|--------|-------|
| VM creation from cloud image | ✅ | CDI DataVolume imports Ubuntu cloud img |
| Cloud-init | ✅ | SSH keys, packages, hostname |
| Start / Stop / Restart | ✅ | Via virtctl, works cleanly |
| Console access | ✅ | Serial + VNC |
| SSH via NodePort | ✅ | Ports 30022, 30023 |
| Hybrid VM↔Pod networking | ✅ | VM can curl nginx via cluster DNS |
| Persistent storage | ✅ | local-path + Longhorn |
| Nested virtualisation | ✅ | Host CPU passthrough from Proxmox |
| containerDisk instant boot | ✅ | Fedora + CirrOS boot in seconds |
| Multi-tier hybrid app | ✅ | PostgreSQL VM + Adminer pod |
| VM Snapshots | ✅ | Snapshot created, ReadyToUse: true |
| Distributed storage (Longhorn) | ✅ | v1.7.2, 23 pods, RWX volumes |
| **Live migration** | ✅ | worker2 → worker1 with Longhorn RWX |

## Limitations & Next Steps

### Current Limitations
- **No GPU passthrough** — i7-12700KF has no iGPU (KF model). Would need discrete GPU.
- **Single network** — Masquerade only. Multus would allow bridged/SR-IOV.
- **Windows VM** — Template ready but needs manual ISO download (~5GB eval)
- **VM Clones** — Need CSI VolumeSnapshot support (Longhorn has this, not yet tested)

### Production Roadmap
1. ~~**Shared storage**~~ → ✅ Longhorn deployed, live migration working
2. **Multus CNI** → Dedicated VM networks, bridged interfaces
3. **Monitoring** → KubeVirt exports Prometheus metrics natively
4. **GitOps** → Manage VM definitions via ArgoCD
5. **Backups** → Velero + CSI snapshots
6. **Instance types** → Standardised VM sizes (small/medium/large)

## Reference Links

- [KubeVirt Docs](https://kubevirt.io/user-guide/)
- [KubeVirt GitHub](https://github.com/kubevirt/kubevirt)
- [CDI User Guide](https://github.com/kubevirt/containerized-data-importer/blob/main/doc/datavolumes.md)
- [virtctl Reference](https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/)
- [KubeVirt Architecture](https://kubevirt.io/user-guide/architecture/)
- [Live Migration Guide](https://kubevirt.io/user-guide/compute/live_migration/)
- [Multus + KubeVirt](https://kubevirt.io/user-guide/virtual_machines/interfaces_and_networks/)
- [Windows VMs on KubeVirt](https://kubevirt.io/user-guide/virtual_machines/windows_virtio_drivers/)

## File Locations

| Path | Description |
|------|-------------|
| `~/clawd/projects/kubevirt-poc/README.md` | Full technical README |
| `~/clawd/projects/kubevirt-poc/manifests/` | All K8s manifests |
| `~/obsidian-vault/kubevirt/` | This vault page |

---

*Built by Red 🔴 — 29 Jan 2026*
