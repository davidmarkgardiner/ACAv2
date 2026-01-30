# KubeVirt Setup Guide — Bare Metal Handover

> **Purpose:** Step-by-step guide to replicate the KubeVirt PoC on bare metal infrastructure.
> **Audience:** Platform engineering stakeholders deploying VM workloads on Kubernetes.
> **Tested on:** Ubuntu 24.04 LTS, Kubernetes v1.31.14, KubeVirt v1.7.0
> **Author:** David Gardiner — Dev/SecOps
> **Date:** January 2026

---

## Prerequisites

### Hardware Requirements

| Requirement | Minimum | Recommended | Notes |
|-------------|---------|-------------|-------|
| CPU | 8 cores | 16+ cores | Must support hardware virtualisation (VT-x/AMD-V) |
| RAM | 16GB | 64GB+ | VMs consume real memory — plan for VM + K8s overhead |
| Storage | 100GB SSD | 500GB+ NVMe | Distributed storage (Longhorn) replicates data across nodes |
| Nodes | 1 (single-node) | 3+ (HA) | Live migration requires 2+ worker nodes |
| Network | 1 GbE | 10 GbE | Storage replication and VM migration are network-heavy |

### CPU Virtualisation Support

**Critical:** The host CPUs **must** support hardware virtualisation and it **must** be enabled in BIOS.

```bash
# Check for VT-x (Intel) or AMD-V support
grep -cE 'vmx|svm' /proc/cpuinfo
# Output > 0 means supported

# If running inside VMs (nested virtualisation), enable on the hypervisor:
# Proxmox: CPU type = "host" on each VM
# VMware: Enable "Expose hardware assisted virtualization"
# KVM: modprobe kvm_intel nested=1
```

### Node OS Preparation

Run on **every node** before installing Kubernetes:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Required packages
sudo apt install -y \
  curl \
  apt-transport-https \
  ca-certificates \
  gnupg \
  lsb-release \
  socat \
  conntrack \
  open-iscsi \      # Required for Longhorn
  nfs-common \      # Required for Longhorn
  util-linux         # Required for Longhorn

# Enable and start iSCSI (Longhorn dependency)
sudo systemctl enable --now iscsid

# Disable swap (Kubernetes requirement)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Kernel network parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

---

## Step 1: Install Container Runtime (containerd)

Run on **every node**:

```bash
# Install containerd
sudo apt install -y containerd

# Configure containerd with systemd cgroup driver
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Version used:** containerd v1.7.28

---

## Step 2: Install Kubernetes (kubeadm)

### Install kubeadm, kubelet, kubectl

Run on **every node**:

```bash
# Add Kubernetes apt repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### Initialise Control Plane

Run on the **control plane node only**:

```bash
sudo kubeadm init \
  --pod-network-cidr=x.0.0/16 \
  --kubernetes-version=v1.31.14

# Set up kubeconfig
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Join Worker Nodes

Run the `kubeadm join` command from the init output on **each worker node**:

```bash
sudo kubeadm join <control-plane-ip>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

If the token expired:
```bash
# On control plane:
kubeadm token create --print-join-command
```

### Verify

```bash
kubectl get nodes
# All nodes should show STATUS: NotReady (until CNI is installed)
```

---

## Step 3: Install CNI (Calico)

Without a CNI plugin, pods can't communicate. We use Calico.

```bash
# Install Calico operator + CRDs
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

# Install Calico custom resource
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
```

Wait for all Calico pods to be running:

```bash
watch kubectl get pods -n calico-system
# Also check:
kubectl get nodes
# All nodes should now show STATUS: Ready
```

**Version used:** Calico v3.28.0

---

## Step 4: Install Storage — Local Path Provisioner

Provides basic local storage for non-production/PoC workloads:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

**Version used:** v0.0.30

> **Note:** local-path only supports ReadWriteOnce (RWO). For live migration you'll need Longhorn (Step 5).

---

## Step 5: Install Distributed Storage — Longhorn

Longhorn provides distributed block storage with ReadWriteMany (RWX) support, which is **required for live migration**.

### Pre-flight Check

```bash
# Run Longhorn's environment check
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/scripts/environment_check.sh | bash
```

Ensure `open-iscsi` and `nfs-common` are installed (done in Prerequisites).

### Install Longhorn

```bash
# Apply Longhorn manifests
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml

# Wait for all pods (23 pods across the cluster)
watch kubectl get pods -n longhorn-system
```

### Set as Default StorageClass

```bash
# Remove default from local-path
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Set Longhorn as default
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Verify

```bash
kubectl get sc
# longhorn (default)   driver.longhorn.io   Delete   Immediate   true
```

### Optional: Expose Longhorn UI

```bash
kubectl expose deployment longhorn-ui -n longhorn-system \
  --type=NodePort --port=8000 --target-port=8000 --name=longhorn-ui-np
# Or use an Ingress/LoadBalancer
```

**Version used:** Longhorn v1.7.2

---

## Step 6: Install KubeVirt

### Install the Operator

```bash
export KUBEVIRT_VERSION=v1.7.0

# Deploy the KubeVirt operator
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

# Deploy the KubeVirt custom resource
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml
```

### Enable Feature Gates

```bash
kubectl patch kubevirt kubevirt -n kubevirt --type merge -p '
{
  "spec": {
    "configuration": {
      "developerConfiguration": {
        "featureGates": ["Snapshot", "VMExport"]
      }
    }
  }
}'
```

Feature gates explained:
- **Snapshot** — Enable VM snapshots for backup/restore
- **VMExport** — Enable VM disk export

### Wait for KubeVirt to be Ready

```bash
kubectl wait --for=condition=Available kubevirt kubevirt -n kubevirt --timeout=300s

# Verify all components
kubectl get pods -n kubevirt
# Expected: virt-operator, virt-api, virt-controller, virt-handler (DaemonSet)
```

**Version used:** KubeVirt v1.7.0

---

## Step 7: Install CDI (Containerized Data Importer)

CDI imports VM disk images (cloud images, ISOs) into Kubernetes PVCs.

```bash
export CDI_VERSION=v1.64.0

# Deploy CDI operator
kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml

# Deploy CDI custom resource
kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml

# Wait for CDI
kubectl wait --for=condition=Available cdi cdi --timeout=300s

# Verify
kubectl get pods -n cdi
# Expected: cdi-operator, cdi-apiserver, cdi-deployment, cdi-uploadproxy
```

**Version used:** CDI v1.64.0

---

## Step 8: Install virtctl CLI

`virtctl` is the CLI for managing KubeVirt VMs (start/stop/console/VNC/SSH).

```bash
export KUBEVIRT_VERSION=v1.7.0

# Download for Linux amd64
curl -L -o /usr/local/bin/virtctl \
  https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64

chmod +x /usr/local/bin/virtctl

# Verify
virtctl version --client
```

---

## Validation Checklist

Run these checks to confirm the installation is complete:

```bash
echo "=== Nodes ==="
kubectl get nodes

echo "=== KubeVirt ==="
kubectl get kubevirt -n kubevirt

echo "=== CDI ==="
kubectl get cdi

echo "=== Storage Classes ==="
kubectl get sc

echo "=== All Pods ==="
kubectl get pods -A | grep -v Running | grep -v Completed
# Should return only the header (all pods Running/Completed)

echo "=== Virtualisation Check ==="
kubectl get nodes -o json | jq '.items[].status.allocatable["devices.kubevirt.io/kvm"]'
# Should return "1k" for each node (KVM device available)
```

### Expected Output Summary

| Check | Expected |
|-------|----------|
| Nodes | All `Ready` |
| KubeVirt | `Phase: Deployed` |
| CDI | `Phase: Deployed` |
| StorageClass | `longhorn (default)` |
| KVM devices | `1k` per node |
| All pods | Running/Completed |

---

## Quick Start: Create Your First VM

```bash
# Create namespace
kubectl create namespace kubevirt-poc

# Apply a VM manifest (Ubuntu cloud image example)
cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm
  namespace: kubevirt-poc
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 2
        devices:
          disks:
          - disk:
              bus: virtio
            name: rootdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          interfaces:
          - masquerade: {}
            name: default
        resources:
          requests:
            memory: 2Gi
      networks:
      - name: default
        pod: {}
      volumes:
      - dataVolume:
          name: test-vm-dv
        name: rootdisk
      - cloudInitNoCloud:
          userData: |
            #cloud-config
            users:
            - name: admin
              sudo: ALL=(ALL) NOPASSWD:ALL
              ssh_authorized_keys:
              - ssh-rsa YOUR_SSH_PUBLIC_KEY
        name: cloudinitdisk
  dataVolumeTemplates:
  - metadata:
      name: test-vm-dv
    spec:
      storage:
        accessModes:
        - ReadWriteMany
        resources:
          requests:
            storage: 10Gi
      source:
        http:
          url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
EOF

# Check status
kubectl get vm,vmi -n kubevirt-poc

# Access console
virtctl console test-vm -n kubevirt-poc
```

---

## Component Summary

| Layer | Component | Version | Install Method | Purpose |
|-------|-----------|---------|---------------|---------|
| OS | Ubuntu LTS | 24.04 | Base install | Host operating system |
| Container Runtime | containerd | 1.7.28 | apt | Container runtime for K8s |
| Orchestration | Kubernetes | v1.31 | kubeadm | Container + VM orchestration |
| Networking | Calico | v3.28.0 | Manifest | Pod CNI + network policy |
| Storage (basic) | local-path-provisioner | v0.0.30 | Manifest | Local RWO storage |
| Storage (distributed) | Longhorn | v1.7.2 | Manifest | Distributed RWX storage (live migration) |
| Virtualisation | KubeVirt | v1.7.0 | Operator | VM lifecycle on K8s |
| Disk Import | CDI | v1.64.0 | Operator | VM image import to PVCs |
| CLI | virtctl | v1.7.0 | Binary | VM management CLI |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Bare Metal Servers                       │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ Control Plane│  │  Worker 1    │  │  Worker 2    │  ...  │
│  │             │  │              │  │              │       │
│  │ kubeadm     │  │ kubelet      │  │ kubelet      │       │
│  │ etcd        │  │ containerd   │  │ containerd   │       │
│  │ API server  │  │ KVM          │  │ KVM          │       │
│  └──────┬──────┘  └──────┬───────┘  └──────┬───────┘       │
│         │                │                  │               │
│         └────────────────┼──────────────────┘               │
│                          │                                  │
│  ┌───────────────────────┴───────────────────────────┐      │
│  │              Kubernetes Platform                   │      │
│  │                                                   │      │
│  │  Calico CNI ─── Pod Networking                    │      │
│  │  Longhorn ───── Distributed Block Storage (RWX)   │      │
│  │  KubeVirt ───── VM Lifecycle Management           │      │
│  │  CDI ────────── VM Image Import                   │      │
│  │                                                   │      │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐           │      │
│  │  │ VM      │  │ VM      │  │ Pod     │  Hybrid   │      │
│  │  │ (Linux) │  │ (Win)   │  │ (nginx) │  workloads│      │
│  │  └─────────┘  └─────────┘  └─────────┘           │      │
│  └───────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `devices.kubevirt.io/kvm` not available | VT-x/AMD-V disabled | Enable in BIOS |
| VM stuck in `Scheduling` | No KVM device on nodes | Check nested virt / BIOS settings |
| DataVolume stuck in `ImportInProgress` | Slow network or DNS issues | Check CDI importer pod logs |
| Live migration fails | RWO storage | Switch to Longhorn with RWX AccessMode |
| Pods in `CrashLoopBackOff` | Missing kernel modules | Run `modprobe overlay br_netfilter` |
| Longhorn volumes not attaching | Missing `open-iscsi` | `apt install open-iscsi && systemctl enable --now iscsid` |

---

## Next Steps (Production Considerations)

- [ ] **HA control plane** — 3 control plane nodes with external etcd or stacked etcd
- [ ] **Load balancer** — MetalLB or kube-vip for service LoadBalancer type
- [ ] **Ingress** — NGINX Ingress Controller or Traefik
- [ ] **Monitoring** — kube-prometheus-stack (Prometheus + Grafana)
- [ ] **Logging** — Loki + Promtail
- [ ] **GitOps** — ArgoCD or Flux for declarative VM management
- [ ] **Backups** — Velero + CSI snapshots
- [ ] **Network policies** — Calico policies to isolate VM traffic
- [ ] **RBAC** — Role-based access for VM operators vs platform admins
- [ ] **Multus CNI** — Multiple network interfaces per VM (bridged, SR-IOV)

---

*Built from homelab PoC — David Gardiner, January 2026*
