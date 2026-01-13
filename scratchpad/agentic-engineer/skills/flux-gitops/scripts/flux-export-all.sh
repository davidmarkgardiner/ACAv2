#!/bin/bash
# Export All Flux Resources Script
# Usage: ./flux-export-all.sh [output-dir]

set -euo pipefail

OUTPUT_DIR="${1:-./flux-export}"

echo "============================================"
echo "Flux Resource Export"
echo "Output: $OUTPUT_DIR"
echo "============================================"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"/{sources,kustomizations,helmreleases,notifications,image-automation}

# Export GitRepositories
echo "Exporting GitRepositories..."
flux export source git --all > "$OUTPUT_DIR/sources/gitrepositories.yaml" 2>/dev/null || echo "No GitRepositories found"

# Export HelmRepositories
echo "Exporting HelmRepositories..."
flux export source helm --all > "$OUTPUT_DIR/sources/helmrepositories.yaml" 2>/dev/null || echo "No HelmRepositories found"

# Export OCIRepositories
echo "Exporting OCIRepositories..."
flux export source oci --all > "$OUTPUT_DIR/sources/ocirepositories.yaml" 2>/dev/null || echo "No OCIRepositories found"

# Export Kustomizations
echo "Exporting Kustomizations..."
flux export kustomization --all > "$OUTPUT_DIR/kustomizations/kustomizations.yaml" 2>/dev/null || echo "No Kustomizations found"

# Export HelmReleases
echo "Exporting HelmReleases..."
flux export helmrelease --all > "$OUTPUT_DIR/helmreleases/helmreleases.yaml" 2>/dev/null || echo "No HelmReleases found"

# Export Alerts
echo "Exporting Alerts..."
flux export alert --all > "$OUTPUT_DIR/notifications/alerts.yaml" 2>/dev/null || echo "No Alerts found"

# Export Providers
echo "Exporting Providers..."
flux export alert-provider --all > "$OUTPUT_DIR/notifications/providers.yaml" 2>/dev/null || echo "No Providers found"

# Export Receivers
echo "Exporting Receivers..."
flux export receiver --all > "$OUTPUT_DIR/notifications/receivers.yaml" 2>/dev/null || echo "No Receivers found"

# Export ImageRepositories
echo "Exporting ImageRepositories..."
flux export image repository --all > "$OUTPUT_DIR/image-automation/imagerepositories.yaml" 2>/dev/null || echo "No ImageRepositories found"

# Export ImagePolicies
echo "Exporting ImagePolicies..."
flux export image policy --all > "$OUTPUT_DIR/image-automation/imagepolicies.yaml" 2>/dev/null || echo "No ImagePolicies found"

# Export ImageUpdateAutomations
echo "Exporting ImageUpdateAutomations..."
flux export image update --all > "$OUTPUT_DIR/image-automation/imageupdateautomations.yaml" 2>/dev/null || echo "No ImageUpdateAutomations found"

# Create summary
echo ""
echo "## Export Summary"
echo "----------------------------------------"
find "$OUTPUT_DIR" -name "*.yaml" -type f | while read -r file; do
    RESOURCES=$(grep -c "^---" "$file" 2>/dev/null || echo "0")
    if [[ "$RESOURCES" -gt 0 ]] || [[ -s "$file" ]]; then
        echo "$(basename "$file"): $RESOURCES resources"
    fi
done
echo ""

# Create kustomization.yaml for easy re-application
cat > "$OUTPUT_DIR/kustomization.yaml" << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sources/
  - kustomizations/
  - helmreleases/
  - notifications/
  - image-automation/
EOF

echo "Created $OUTPUT_DIR/kustomization.yaml for easy re-application"
echo ""

echo "============================================"
echo "Export complete: $OUTPUT_DIR"
echo "============================================"
