Ah, that changes everything. Platform team backing up tenant workloads where you can't guarantee their practices. Completely valid use case.

## Robust Multi-Tenant Backup Solution

```bash
#!/bin/bash
# AKS Platform Backup - Customer namespace manifests
# Designed for multi-tenant clusters where tenants don't use GitOps

set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/backup}"
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
MANIFEST_DIR="$BACKUP_DIR/manifests"
LOG_FILE="$BACKUP_DIR/backup.log"

# Platform namespaces to exclude (adjust to your setup)
EXCLUDED_NS="kube-system|kube-public|kube-node-lease|kube-dns|gatekeeper-system|dataprotection-microsoft|istio-system|argo|argocd|kyverno|cert-manager|ingress-nginx|monitoring"

# Resources to backup - ordered by restore dependency
CLUSTER_RESOURCES="storageclasses persistentvolumes clusterroles clusterrolebindings"
NS_RESOURCES="serviceaccounts secrets configmaps persistentvolumeclaims deployments statefulsets daemonsets replicasets services ingresses networkpolicies horizontalpodautoscalers poddisruptionbudgets jobs cronjobs"

mkdir -p "$MANIFEST_DIR/_cluster"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== AKS Backup Started: $(date) ==="
echo "Backup location: $BACKUP_DIR"

# Cluster-scoped resources
echo -e "\n--- Cluster-scoped resources ---"
for resource in $CLUSTER_RESOURCES; do
    count=$(kubectl get "$resource" --no-headers 2>/dev/null | wc -l || echo 0)
    if [[ $count -gt 0 ]]; then
        kubectl get "$resource" -o yaml | \
            yq 'del(.items[].metadata.resourceVersion, .items[].metadata.uid, 
                    .items[].metadata.creationTimestamp, .items[].metadata.generation,
                    .items[].metadata.managedFields, .items[].status)' \
            > "$MANIFEST_DIR/_cluster/${resource}.yaml"
        echo "  $resource: $count items"
    fi
done

# Customer namespaces
NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -Ev "$EXCLUDED_NS" || true)
NS_COUNT=$(echo "$NAMESPACES" | grep -c . || echo 0)
echo -e "\n--- Backing up $NS_COUNT customer namespaces ---"

for ns in $NAMESPACES; do
    ns_dir="$MANIFEST_DIR/$ns"
    mkdir -p "$ns_dir"
    
    # Backup namespace metadata (labels, annotations matter for tenancy)
    kubectl get ns "$ns" -o yaml | \
        yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, 
                .metadata.generation, .metadata.managedFields, .status)' \
        > "$ns_dir/_namespace.yaml"
    
    resource_count=0
    for resource in $NS_RESOURCES; do
        items=$(kubectl get "$resource" -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)
        if [[ $items -gt 0 ]]; then
            kubectl get "$resource" -n "$ns" -o yaml | \
                yq 'del(.items[].metadata.resourceVersion, .items[].metadata.uid,
                        .items[].metadata.creationTimestamp, .items[].metadata.generation,
                        .items[].metadata.managedFields, .items[].status,
                        .items[].spec.clusterIP, .items[].spec.clusterIPs)' \
                > "$ns_dir/${resource}.yaml"
            resource_count=$((resource_count + items))
        fi
    done
    echo "  $ns: $resource_count resources"
done

# Summary manifest for quick restore reference
echo -e "\n--- Generating backup manifest ---"
cat > "$BACKUP_DIR/manifest.json" <<EOF
{
    "timestamp": "$(date -Iseconds)",
    "cluster": "$(kubectl config current-context)",
    "namespaces": $NS_COUNT,
    "backup_path": "$BACKUP_DIR"
}
EOF

# Compress for storage
echo -e "\n--- Compressing backup ---"
tar -czf "$BACKUP_DIR.tar.gz" -C "$BACKUP_ROOT" "$(basename "$BACKUP_DIR")"
BACKUP_SIZE=$(du -h "$BACKUP_DIR.tar.gz" | cut -f1)
echo "Compressed backup: $BACKUP_DIR.tar.gz ($BACKUP_SIZE)"

# Cleanup uncompressed (optional - keep for debugging)
# rm -rf "$BACKUP_DIR"

echo -e "\n=== Backup Complete: $(date) ==="
```

## Restore Script with Chunking

```bash
#!/bin/bash
# AKS Platform Restore - Handles large backups with dependency ordering

set -euo pipefail

BACKUP_ARCHIVE="$1"
TARGET_NS="${2:-}"  # Optional: restore single namespace
DRY_RUN="${3:---dry-run=server}"  # Pass "apply" for real restore

if [[ -z "$BACKUP_ARCHIVE" ]]; then
    echo "Usage: $0 <backup.tar.gz> [namespace] [apply]"
    echo "  namespace: optional - restore single namespace only"
    echo "  apply: optional - actually apply (default is dry-run)"
    exit 1
fi

[[ "$DRY_RUN" == "apply" ]] && DRY_RUN="" || DRY_RUN="--dry-run=server"
[[ -n "$DRY_RUN" ]] && echo "=== DRY RUN MODE - No changes will be made ==="

# Extract backup
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT
tar -xzf "$BACKUP_ARCHIVE" -C "$WORK_DIR"
MANIFEST_DIR=$(find "$WORK_DIR" -type d -name manifests | head -1)

if [[ -z "$MANIFEST_DIR" ]]; then
    echo "ERROR: No manifests directory found in backup"
    exit 1
fi

# Restore order matters
CLUSTER_ORDER="storageclasses persistentvolumes clusterroles clusterrolebindings"
NS_ORDER="serviceaccounts secrets configmaps persistentvolumeclaims deployments statefulsets daemonsets services ingresses networkpolicies horizontalpodautoscalers poddisruptionbudgets jobs cronjobs"

# Cluster resources first (skip if restoring single namespace)
if [[ -z "$TARGET_NS" ]] && [[ -d "$MANIFEST_DIR/_cluster" ]]; then
    echo -e "\n--- Restoring cluster-scoped resources ---"
    for resource in $CLUSTER_ORDER; do
        file="$MANIFEST_DIR/_cluster/${resource}.yaml"
        if [[ -f "$file" ]] && [[ -s "$file" ]]; then
            echo "  Applying: $resource"
            kubectl apply $DRY_RUN -f "$file" 2>&1 | grep -v "unchanged" || true
        fi
    done
fi

# Namespace resources
echo -e "\n--- Restoring namespace resources ---"
for ns_dir in "$MANIFEST_DIR"/*/; do
    ns=$(basename "$ns_dir")
    [[ "$ns" == "_cluster" ]] && continue
    [[ -n "$TARGET_NS" ]] && [[ "$ns" != "$TARGET_NS" ]] && continue
    
    echo -e "\nNamespace: $ns"
    
    # Create/update namespace first
    if [[ -f "$ns_dir/_namespace.yaml" ]]; then
        kubectl apply $DRY_RUN -f "$ns_dir/_namespace.yaml" 2>&1 | grep -v "unchanged" || true
    else
        kubectl create namespace "$ns" $DRY_RUN 2>/dev/null || true
    fi
    
    # Apply resources in dependency order
    for resource in $NS_ORDER; do
        file="$ns_dir/${resource}.yaml"
        if [[ -f "$file" ]] && [[ -s "$file" ]]; then
            # Split large files and apply in chunks
            item_count=$(yq '.items | length' "$file" 2>/dev/null || echo 0)
            
            if [[ $item_count -gt 50 ]]; then
                echo "  $resource: $item_count items (chunked)"
                # Process in batches of 50
                for ((i=0; i<item_count; i+=50)); do
                    yq ".items[$i:$((i+50))]" "$file" | \
                        kubectl apply $DRY_RUN -n "$ns" -f - 2>&1 | grep -cv "unchanged" || true
                done
            else
                echo "  $resource: $item_count items"
                kubectl apply $DRY_RUN -n "$ns" -f "$file" 2>&1 | grep -v "unchanged" || true
            fi
        fi
    done
done

echo -e "\n=== Restore Complete ==="
[[ -n "$DRY_RUN" ]] && echo "This was a dry run. Use 'apply' as third argument for real restore."
```

## Deploy as CronJob in Cluster

```yaml
# backup-cronjob.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: platform-backup
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backup-sa
  namespace: platform-backup
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-backup-reader
rules:
- apiGroups: ["", "apps", "batch", "networking.k8s.io", "policy", "autoscaling", "rbac.authorization.k8s.io", "storage.k8s.io"]
  resources: ["*"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-backup-reader
subjects:
- kind: ServiceAccount
  name: backup-sa
  namespace: platform-backup
roleRef:
  kind: ClusterRole
  name: platform-backup-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backup-storage
  namespace: platform-backup
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: managed-csi
  resources:
    requests:
      storage: 10Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: namespace-backup
  namespace: platform-backup
spec:
  schedule: "0 2 * * *"  # 2am daily
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-sa
          containers:
          - name: backup
            image: bitnami/kubectl:latest
            command:
            - /bin/bash
            - /scripts/backup.sh
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
            - name: scripts
              mountPath: /scripts
            env:
            - name: BACKUP_ROOT
              value: /backup
          restartPolicy: OnFailure
          volumes:
          - name: backup-storage
            persistentVolumeClaim:
              claimName: backup-storage
          - name: scripts
            configMap:
              name: backup-scripts
              defaultMode: 0755
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: backup-scripts
  namespace: platform-backup
data:
  backup.sh: |
    #!/bin/bash
    # Paste the backup script content here
    # Or mount from a separate ConfigMap
```

## Push to Azure Blob Storage

Add this to the backup script to ship backups off-cluster:

```bash
# Requires: azcopy or az cli in container image
# Add after compression step

STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-platformbackups}"
CONTAINER="${AZURE_CONTAINER:-aks-backups}"
CLUSTER_NAME=$(kubectl config current-context | tr '/' '-')

# Using managed identity (workload identity)
az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$CLUSTER_NAME/$(basename "$BACKUP_DIR.tar.gz")" \
    --file "$BACKUP_DIR.tar.gz" \
    --auth-mode login

# Cleanup local after upload
rm -rf "$BACKUP_DIR" "$BACKUP_DIR.tar.gz"

# Retention - delete backups older than 30 days
az storage blob delete-batch \
    --account-name "$STORAGE_ACCOUNT" \
    --source "$CONTAINER" \
    --pattern "$CLUSTER_NAME/*" \
    --if-unmodified-since "$(date -d '30 days ago' -Iseconds)"
```

This gives you a lightweight backup solution for customer namespaces that doesn't require them to adopt GitOps. Obviously it's **manifest-only** - no PV data - but for most stateless customer workloads that's sufficient.

Want me to package this up properly with the Azure Blob integration for your platform?